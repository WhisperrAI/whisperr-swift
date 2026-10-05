import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

// MARK: - Token description

/// The type of a push token (whisperr-spec SPEC.md → Token kind). The server
/// routes each token to the provider the app set for its kind.
public enum WhisperrPushKind: String, Codable, Sendable, CaseIterable {
    /// A raw APNs device token, sent as lowercase hex.
    case apns
    /// A Firebase Cloud Messaging registration token.
    case fcm
    /// An Expo push token (`ExponentPushToken[…]`).
    case expo
    /// A OneSignal subscription id.
    case oneSignalSubscription = "onesignal_sub"
}

/// The APNs environment of a token. A development-signed build gets
/// `sandbox` tokens; App Store, TestFlight and Ad Hoc builds get `production`
/// tokens. APNs rejects a token sent to the wrong environment.
public enum WhisperrPushEnvironment: String, Codable, Sendable, CaseIterable {
    case sandbox
    case production

    /// The environment of the running build, detected once per process:
    ///
    /// 1. the `aps-environment` entitlement in the embedded provisioning
    ///    profile (`development` → sandbox, `production` → production);
    /// 2. without a profile: the simulator is sandbox;
    /// 3. otherwise the build configuration: `DEBUG` → sandbox, else
    ///    production. (App Store builds carry no profile and are not DEBUG.)
    ///
    /// Pass an explicit environment to `setPushToken(_:environment:)` when
    /// your build setup needs a different answer.
    public static var current: WhisperrPushEnvironment {
        PushEnvironmentResolver.current
    }
}

/// The OS family a push token belongs to. Values match the spec's
/// `platform` list.
public enum WhisperrPushPlatform: String, Codable, Sendable, CaseIterable {
    case ios
    case android
    case web
    case macos
    case windows
    case linux

    /// The platform of the running process, or nil where the spec has no
    /// value for it (tvOS, watchOS, visionOS). Mac Catalyst reports `ios`.
    public static var current: WhisperrPushPlatform? {
        #if targetEnvironment(macCatalyst)
        return .ios
        #elseif os(iOS)
        return .ios
        #elseif os(macOS)
        return .macos
        #else
        return nil
        #endif
    }
}

/// Finds the APNs environment of the running build. Pure parts are internal
/// so tests can drive them.
enum PushEnvironmentResolver {
    static let current: WhisperrPushEnvironment = resolve(
        profile: loadEmbeddedProfile(),
        isSimulator: isSimulator,
        isDebugBuild: isDebugBuild
    )

    static func resolve(profile: Data?, isSimulator: Bool, isDebugBuild: Bool) -> WhisperrPushEnvironment {
        if let profile, let environment = apsEnvironment(inProfile: profile) {
            return environment
        }
        if isSimulator || isDebugBuild {
            return .sandbox
        }
        return .production
    }

    /// Reads `aps-environment` (iOS) or `com.apple.developer.aps-environment`
    /// (macOS, Mac Catalyst) from a provisioning profile. The profile is a
    /// signed CMS envelope around an XML property list; the plist is cut out
    /// of the envelope, which needs no Security framework call.
    static func apsEnvironment(inProfile data: Data) -> WhisperrPushEnvironment? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else {
            return nil
        }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil),
              let root = plist as? [String: Any],
              let entitlements = root["Entitlements"] as? [String: Any] else {
            return nil
        }
        let value = (entitlements["aps-environment"] ?? entitlements["com.apple.developer.aps-environment"]) as? String
        switch value {
        case "development":
            return .sandbox
        case "production":
            return .production
        default:
            return nil
        }
    }

    private static func loadEmbeddedProfile(bundle: Bundle = .main) -> Data? {
        if let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url) {
            return data
        }
        // macOS and Mac Catalyst apps keep the profile in Contents/.
        let macProfile = bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("embedded.provisionprofile")
        return try? Data(contentsOf: macProfile)
    }

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}

extension Data {
    /// The lowercase hex form of an APNs device token.
    var whisperrHexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Permission

/// The notification permission the user gave the app.
public enum WhisperrPushPermissionStatus: String, Codable, Sendable, CaseIterable {
    case authorized
    case provisional
    case denied
    case notDetermined = "not_determined"
}

#if canImport(UserNotifications)
extension WhisperrPushPermissionStatus {
    /// Maps an `UNAuthorizationStatus`. App Clip ephemeral permission reports
    /// as `authorized`. A status this SDK does not know returns nil.
    public init?(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined:
            self = .notDetermined
        case .denied:
            self = .denied
        case .authorized:
            self = .authorized
        case .provisional:
            self = .provisional
        default:
            // 4 is .ephemeral (iOS 14+, App Clips): a time-limited grant.
            guard status.rawValue == 4 else {
                return nil
            }
            self = .authorized
        }
    }
}
#endif

enum WhisperrPushPermission {
    /// Reads the current permission without prompting the user. Returns nil
    /// where it cannot be read: without UserNotifications, or outside an app
    /// or app extension bundle (a command-line tool or test runner), where
    /// `UNUserNotificationCenter.current()` traps.
    static func current() async -> WhisperrPushPermissionStatus? {
        #if canImport(UserNotifications)
        let path = Bundle.main.bundlePath
        guard Bundle.main.bundleIdentifier != nil, path.hasSuffix(".app") || path.hasSuffix(".appex") else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: WhisperrPushPermissionStatus(settings.authorizationStatus))
            }
        }
        #else
        return nil
        #endif
    }
}

// MARK: - Payload

/// The Whisperr fields of a push notification payload.
///
/// The Whisperr backend puts `whisperr_message_id` in the push data, and the
/// deep link in `whisperr_deep_link` (the older `deep_link` key is read too).
/// APNs and FCM deliver data keys at the top level of `userInfo`; some
/// senders nest them under `data`; OneSignal nests them under `custom.a`. All
/// are read.
///
/// Build this synchronously from `userInfo` inside your notification delegate
/// when your app uses Swift 6 strict concurrency, then pass the value (it is
/// `Sendable`) to `WhisperrClient.trackPushOpened(_:)`.
public struct WhisperrPushPayload: Sendable, Equatable {
    /// Data keys the deep link may use, in order of preference.
    static let deepLinkKeys = ["whisperr_deep_link", "deep_link"]

    public let messageID: String
    /// The deep link string exactly as the payload carries it.
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
        self.deepLink = Self.deepLinkKeys.lazy.compactMap { key in
            sources.lazy.compactMap { Self.string($0[key]) }.first
        }.first
    }

    /// The deep link as a URL, or nil when the payload has none or it is not
    /// an absolute URL (it must have a scheme, for example `myapp://` or
    /// `https://`). Check the URL before you route to it.
    public var deepLinkURL: URL? {
        guard let deepLink, let url = URL(string: deepLink), let scheme = url.scheme, !scheme.isEmpty else {
            return nil
        }
        return url
    }

    static func dataDictionaries(in userInfo: [AnyHashable: Any]) -> [[AnyHashable: Any]] {
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

#if canImport(UserNotifications) && !os(tvOS)
extension WhisperrPushPayload {
    /// Returns nil when the response is not a Whisperr notification, or when
    /// the user dismissed it (`UNNotificationDismissActionIdentifier`):
    /// a dismissal is not an open.
    public init?(response: UNNotificationResponse) {
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else {
            return nil
        }
        self.init(userInfo: response.notification.request.content.userInfo)
    }
}
#endif
