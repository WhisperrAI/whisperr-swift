import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// App and OS facts that every automatic event carries as flat properties:
/// `app_version`, `app_build`, `os_name`, `os_version`, `platform`,
/// `sdk_name`, `sdk_version`. (`locale` and `timezone` come from
/// `DeviceTraits`.) Values are the canonical ones shared by all SDKs:
/// `platform` is the OS family (never the framework) and `os_name` is
/// lowercase.
struct AppEnvironment: Sendable, Equatable {
    var appVersion: String?
    var appBuild: String?
    var osName: String
    var osVersion: String
    var platform: String

    static func current(bundle: Bundle = .main) -> AppEnvironment {
        let info = bundle.infoDictionary ?? [:]
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var osVersion = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 {
            osVersion += ".\(version.patchVersion)"
        }
        return AppEnvironment(
            appVersion: nonEmpty(info["CFBundleShortVersionString"] as? String),
            appBuild: nonEmpty(info["CFBundleVersion"] as? String),
            osName: osName,
            osVersion: osVersion,
            platform: platform
        )
    }

    /// The flat properties shared by all automatic events. A value the
    /// platform cannot provide is omitted, never guessed.
    var properties: [String: JSONValue] {
        var out: [String: JSONValue] = [
            "os_name": .string(osName),
            "os_version": .string(osVersion),
            "platform": .string(platform),
            "sdk_name": "whisperr-swift",
            "sdk_version": .string(kWhisperrSdkVersion)
        ]
        if let appVersion {
            out["app_version"] = .string(appVersion)
        }
        if let appBuild {
            out["app_build"] = .string(appBuild)
        }
        return out
    }

    private static var osName: String {
        #if targetEnvironment(macCatalyst)
        return "macos"
        #elseif os(iOS)
        return "ios" // iPhone and iPad are not told apart
        #elseif os(tvOS)
        return "tvos"
        #elseif os(watchOS)
        return "watchos"
        #elseif os(visionOS)
        return "visionos"
        #elseif os(macOS)
        return "macos"
        #else
        return "unknown"
        #endif
    }

    private static var platform: String {
        #if os(iOS)
        return "ios" // includes iPadOS and Mac Catalyst
        #elseif os(tvOS)
        return "tvos"
        #elseif os(watchOS)
        return "watchos"
        #elseif os(visionOS)
        return "visionos"
        #elseif os(macOS)
        return "macos"
        #else
        return "unknown"
        #endif
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

/// The Whisperr fields of a push notification payload.
///
/// The Whisperr backend puts `whisperr_message_id` (and, when the message has
/// one, `deep_link`) in the push data. FCM delivers data keys at the top level
/// of `userInfo`; OneSignal nests them under `custom.a`. Both are read.
///
/// Build this synchronously from `userInfo` inside your notification delegate
/// when your app uses Swift 6 strict concurrency, then pass the value (it is
/// `Sendable`) to `WhisperrClient.trackPushOpened(_:)`.
public struct WhisperrPushPayload: Sendable, Equatable {
    public let messageID: String
    public let deepLink: String?

    public init(messageID: String, deepLink: String? = nil) {
        self.messageID = messageID
        self.deepLink = deepLink
    }

    /// Returns nil when the notification was not sent by Whisperr (no
    /// `whisperr_message_id`).
    public init?(userInfo: [AnyHashable: Any]) {
        let sources = Self.dataDictionaries(in: userInfo)
        guard let messageID = sources.lazy.compactMap({ Self.string($0["whisperr_message_id"]) }).first else {
            return nil
        }
        self.messageID = messageID
        self.deepLink = sources.lazy.compactMap { Self.string($0["deep_link"]) }.first
    }

    private static func dataDictionaries(in userInfo: [AnyHashable: Any]) -> [[AnyHashable: Any]] {
        var out: [[AnyHashable: Any]] = [userInfo]
        if let data = userInfo["data"] as? [AnyHashable: Any] {
            out.append(data)
        }
        if let custom = userInfo["custom"] as? [AnyHashable: Any],
           let additional = custom["a"] as? [AnyHashable: Any] {
            out.append(additional)
        }
        return out
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

#if canImport(UIKit) && !os(watchOS)

/// `UIApplication.shared` is unavailable in app extensions. Look it up at run
/// time so the SDK also compiles into an extension target; there it is nil and
/// the SDK sends no lifecycle events.
enum WhisperrApplication {
    @MainActor
    static var shared: UIApplication? {
        if Bundle.main.bundlePath.hasSuffix(".appex") {
            return nil
        }
        return UIApplication.value(forKeyPath: "sharedApplication") as? UIApplication
    }
}

@MainActor
private final class BackgroundTaskBox {
    var identifier: UIBackgroundTaskIdentifier = .invalid
}

/// Forwards UIKit lifecycle notifications to the client. It holds the client
/// weakly, so the client owns it without a retain cycle.
final class WhisperrLifecycleObserver: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []

    init(client: WhisperrClient) {
        let center = NotificationCenter.default
        tokens.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak client] _ in
            guard let client else { return }
            Task { await client.handleWillEnterForeground() }
        })
        tokens.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak client] _ in
            guard let client else { return }
            Task { @MainActor in
                // Ask iOS for time to deliver the queue before the app is
                // suspended. The flush stops waiting when the time runs out;
                // what is left stays persisted for the next launch.
                let app = WhisperrApplication.shared
                let box = BackgroundTaskBox()
                box.identifier = app?.beginBackgroundTask(withName: "net.whisperr.flush") {
                    if box.identifier != .invalid {
                        app?.endBackgroundTask(box.identifier)
                        box.identifier = .invalid
                    }
                } ?? .invalid
                await client.handleDidEnterBackground()
                if box.identifier != .invalid {
                    app?.endBackgroundTask(box.identifier)
                    box.identifier = .invalid
                }
            }
        })
    }

    deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

#endif
