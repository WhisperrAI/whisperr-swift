import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Process-wide convenience facade for app integrations.
///
/// You can also construct `WhisperrClient` directly when you want explicit
/// dependency injection or more than one client.
///
/// The push helpers on this type (`setPushToken`, `pushPermissionChanged`,
/// `handleNotificationResponse`, …) are synchronous and never throw, so you
/// can call them straight from UIKit delegate methods. They run on the shared
/// client. A call made before `initialize` finishes waits for it.
public enum Whisperr {
    private static let storage = WhisperrStorage()
    private static let deepLinks = WhisperrDeepLinkStore()

    public static func initialize(
        apiKey: String,
        baseURL: URL = kWhisperrDefaultBaseURL,
        options: WhisperrOptions = WhisperrOptions()
    ) async {
        if let existing = await storage.get() {
            await existing.close()
        }
        let client = WhisperrClient(apiKey: apiKey, baseURL: baseURL, options: options)
        await client.start()
        await storage.set(client)
    }

    public static var shared: WhisperrClient? {
        get async {
            await storage.get()
        }
    }

    // MARK: - Push tokens

    /// Sends the APNs device token from
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`:
    /// lowercase hex, `kind: apns`, the platform, and the APNs environment
    /// (detected; see `WhisperrPushEnvironment.current`). Pass `environment`
    /// to override the detection. Sends nothing when the token and its fields
    /// did not change.
    public static func setPushToken(_ deviceToken: Data, environment: WhisperrPushEnvironment? = nil) {
        perform { try? await $0.setPushToken(deviceToken, environment: environment) }
    }

    /// Sends a Firebase Cloud Messaging registration token (`kind: fcm`).
    /// Pass `firebaseProjectID` (`FirebaseApp.app()?.options.projectID`).
    public static func setPushToken(fcmToken: String, firebaseProjectID: String? = nil) {
        perform { try? await $0.setPushToken(fcmToken: fcmToken, firebaseProjectID: firebaseProjectID) }
    }

    /// Sends a OneSignal subscription id (`kind: onesignal_sub`). Pass
    /// `oneSignalAppID`.
    public static func setPushToken(oneSignalSubscriptionID: String, oneSignalAppID: String? = nil) {
        perform {
            try? await $0.setPushToken(oneSignalSubscriptionID: oneSignalSubscriptionID, oneSignalAppID: oneSignalAppID)
        }
    }

    // MARK: - App language

    /// Sets the language the user picked in your app (BCP 47, for example
    /// `de` or `pt-BR`). See `WhisperrClient.setAppLanguage(_:)`.
    public static func setAppLanguage(_ tag: String?) {
        perform { await $0.setAppLanguage(tag) }
    }

    // MARK: - Permission

    /// Reports the notification permission. Sends `push_permission_changed`
    /// only when it differs from the last status sent from this device.
    public static func pushPermissionChanged(_ status: WhisperrPushPermissionStatus) {
        perform { await $0.pushPermissionChanged(status) }
    }

    /// Asks the user for notification permission and reports the result.
    /// With `provisional: true` iOS grants quiet delivery without a prompt.
    /// Returns nil before `initialize` finishes or where the SDK cannot ask.
    @discardableResult
    public static func requestPushAuthorization(provisional: Bool = false) async -> WhisperrPushPermissionStatus? {
        await storage.get()?.requestPushAuthorization(provisional: provisional)
    }

    /// Reads the notification permission (no prompt) and reports it. Call it
    /// after `requestAuthorization` completes. The SDK also does this on each
    /// move to the foreground unless `automaticPushPermission` is off.
    public static func refreshPushPermission() {
        perform { await $0.refreshPushPermission() }
    }

    // MARK: - Opens and deep links

    /// Posted on the thread that handled a Whisperr notification with a deep
    /// link. Read the link with `consumePendingDeepLink()`.
    public static let deepLinkNotification = Notification.Name("net.whisperr.deepLink")

    #if canImport(UserNotifications) && !os(tvOS)
    /// Call it from `userNotificationCenter(_:didReceive:withCompletionHandler:)`.
    ///
    /// For a Whisperr notification it sends `push_opened` (once per message
    /// id, in the background) and returns the deep link. It also keeps the link
    /// for `consumePendingDeepLink()` and posts `deepLinkNotification`, for
    /// apps whose UI is not ready yet (a cold start). It returns nil, and sends
    /// nothing, for other notifications and for a dismissal.
    @discardableResult
    public static func handleNotificationResponse(_ response: UNNotificationResponse) -> URL? {
        handle(WhisperrPushPayload(response: response))
    }
    #endif

    #if canImport(UserNotifications) && !os(tvOS)
    /// Call it from `userNotificationCenter(_:willPresent:withCompletionHandler:)`.
    /// For a Whisperr notification it sends `push_received` (once per message
    /// id, in the background) and returns true. You still call the
    /// completion handler with the presentation options you want.
    @discardableResult
    public static func handleWillPresent(_ notification: UNNotification) -> Bool {
        guard let payload = WhisperrPushPayload(notification: notification) else {
            return false
        }
        perform { _ = try? await $0.trackPushReceived(payload) }
        return true
    }
    #endif

    /// `userInfo` form of `handleNotificationResponse(_:)`.
    @discardableResult
    public static func handleNotification(userInfo: [AnyHashable: Any]) -> URL? {
        handle(WhisperrPushPayload(userInfo: userInfo))
    }

    #if canImport(UIKit) && os(iOS)
    /// Cold-start helper for apps that do not set a
    /// `UNUserNotificationCenter` delegate before launch finishes. Pass the
    /// `launchOptions` of `application(_:didFinishLaunchingWithOptions:)`.
    /// A tap that also reaches the delegate is tracked only once.
    @discardableResult
    public static func handleLaunchOptions(_ launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> URL? {
        guard let userInfo = launchOptions?[.remoteNotification] as? [AnyHashable: Any] else {
            return nil
        }
        return handleNotification(userInfo: userInfo)
    }
    #endif

    /// Reports a launch from a deep link or universal link, so that
    /// `app_opened` carries its `launch_source`. Call it from
    /// `application(_:open:options:)`, `scene(_:openURLContexts:)` or
    /// SwiftUI `.onOpenURL`.
    public static func handleOpenURL(_ url: URL) {
        perform { await $0.recordLaunchURL(url) }
    }

    /// Reports a launch from a universal link. Call it from
    /// `application(_:continue:restorationHandler:)`, `scene(_:continue:)` or
    /// SwiftUI `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)`.
    #if canImport(ObjectiveC)
    public static func handleUserActivity(_ activity: NSUserActivity) {
        guard activity.activityType == NSUserActivityTypeBrowsingWeb, let url = activity.webpageURL else {
            return
        }
        handleOpenURL(url)
    }
    #endif

    /// Reports an error your app handled as `app_error` (type name only,
    /// never the message). See `WhisperrClient.trackError(_:screen:kind:)`.
    public static func trackError(_ error: Error, screen: String? = nil, kind: WhisperrErrorKind = .handled) {
        let name = WhisperrSignals.errorName(error)
        perform { await $0.recordError(name: name, frames: [], kind: kind.rawValue, fatal: false, screen: screen) }
    }

    /// Returns the deep link of the last Whisperr notification the user
    /// opened, and forgets it, so each link is handled once. Call it when your
    /// UI is ready (for example in `.onAppear` and when
    /// `deepLinkNotification` arrives). Returns nil when no link is waiting.
    public static func consumePendingDeepLink() -> URL? {
        deepLinks.take()
    }

    private static func handle(_ payload: WhisperrPushPayload?) -> URL? {
        guard let payload else {
            return nil
        }
        perform { _ = try? await $0.trackPushOpened(payload) }
        guard let url = payload.deepLinkURL else {
            return nil
        }
        deepLinks.put(url)
        NotificationCenter.default.post(name: deepLinkNotification, object: nil, userInfo: ["url": url])
        return url
    }

    /// Runs `operation` on the shared client, now or once `initialize`
    /// finishes.
    private static func perform(_ operation: @escaping @Sendable (WhisperrClient) async -> Void) {
        Task { await storage.run(operation) }
    }
}

private actor WhisperrStorage {
    /// Calls made before `initialize` finishes. Bounded: a call beyond the
    /// limit is dropped (the app forgot to initialize).
    private static let maxPending = 32
    private var client: WhisperrClient?
    private var pending: [@Sendable (WhisperrClient) async -> Void] = []

    func set(_ client: WhisperrClient) async {
        self.client = client
        let waiting = pending
        pending.removeAll()
        for operation in waiting {
            await operation(client)
        }
    }

    func get() -> WhisperrClient? {
        client
    }

    func run(_ operation: @escaping @Sendable (WhisperrClient) async -> Void) async {
        guard let client else {
            if pending.count < Self.maxPending {
                pending.append(operation)
            }
            return
        }
        await operation(client)
    }
}

/// The deep link waiting for the app's UI. Synchronous access from any thread.
final class WhisperrDeepLinkStore: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?

    func put(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        self.url = url
    }

    func take() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        let out = url
        url = nil
        return out
    }
}
