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
    /// Nil only when a test harness models a runtime that cannot supply it.
    var osVersion: String?
    var platform: String
    /// The bundle id, sent as a push token's `client_app_id`.
    var clientAppID: String?
    /// The push token `platform` of this device (nil where the spec has no
    /// value for it).
    var pushPlatform: WhisperrPushPlatform?
    /// The APNs environment, sent as `push_env` with an APNs token.
    var apnsEnvironment: WhisperrPushEnvironment?

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
            platform: platform,
            clientAppID: nonEmpty(bundle.bundleIdentifier),
            pushPlatform: WhisperrPushPlatform.current,
            apnsEnvironment: WhisperrPushEnvironment.current
        )
    }

    /// The keys every client event carries in `context` (whisperr-spec
    /// SPEC.md → Versions on every event): `app_version`, `app_build`,
    /// `platform`, `sdk_name`, `sdk_version`. A value the platform cannot
    /// provide is omitted. Never `locale`: the server reads `context.locale`
    /// as the message language of the event.
    var eventContext: [String: JSONValue] {
        var out: [String: JSONValue] = [
            "platform": .string(platform),
            "sdk_name": .string(kWhisperrSdkName),
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

    /// The flat properties shared by all automatic events. A value the
    /// platform cannot provide is omitted, never guessed.
    var properties: [String: JSONValue] {
        var out: [String: JSONValue] = [
            "os_name": .string(osName),
            "platform": .string(platform),
            "sdk_name": .string(kWhisperrSdkName),
            "sdk_version": .string(kWhisperrSdkVersion)
        ]
        if let osVersion {
            out["os_version"] = .string(osVersion)
        }
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

/// Whether the app has been active in this process, for `push_opened`
/// `cold_start`. Read synchronously when a notification response arrives,
/// because the tap and `didBecomeActive` race on a cold launch.
final class WhisperrProcessActivity: @unchecked Sendable {
    static let shared = WhisperrProcessActivity()

    private let lock = NSLock()
    private var tracking = false
    private var hasBeenActive = false

    /// Called when the SDK attaches to the app lifecycle.
    func startTracking(isActive: Bool) {
        lock.lock()
        defer { lock.unlock() }
        tracking = true
        if isActive {
            hasBeenActive = true
        }
    }

    func markActive() {
        lock.lock()
        defer { lock.unlock() }
        hasBeenActive = true
    }

    /// True when an open now starts the app's UI for the first time in this
    /// process. Before the SDK attaches to the lifecycle on a UIKit platform,
    /// the app is still launching, so the answer is true. Nil where there is
    /// no UIKit lifecycle (macOS, watchOS).
    var coldStart: Bool? {
        #if canImport(UIKit) && !os(watchOS)
        lock.lock()
        defer { lock.unlock() }
        return tracking ? !hasBeenActive : true
        #else
        return nil
        #endif
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
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            WhisperrProcessActivity.shared.markActive()
        })
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
