# Whisperr Swift SDK

Official Swift SDK for Whisperr mobile and Apple-platform apps. It identifies
users and tracks churn-signal events with an ordered queue, retry handling, and
stable event idempotency.

## Install

Add the package in Xcode or Swift Package Manager:

```swift
.package(url: "https://github.com/WhisperrAI/whisperr-swift.git", from: "0.4.0")
```

## Quick Start

```swift
import Whisperr

let whisperr = WhisperrClient(apiKey: "wpk_...")
try await whisperr.identify(
    "user_123",
    traits: ["plan": "pro"],
    email: "ada@example.com"
)

try await whisperr.track(
    "checkout_completed",
    properties: ["amount": 42, "currency": "USD"]
)

await whisperr.flush()
```

`track()` uses the user from the most recent `identify()` call. You can also
pass `userID:` explicitly for events emitted outside a signed-in session.
On logout, call `reset()` to flush pending work and clear the current user;
call `close()` when tearing the client down for good.

## Before login (anonymous visitors)

`track()` works before `identify()`. The SDK creates a random `anonymous_id`
(a UUID, stored with the queue) and sends the event under it right away. The
next `identify()` carries the same `anonymous_id`, so the server moves those
events to the user. Events still in the queue go out under the user.
`reset()` rotates the handle, so the next person on the device starts as a new
anonymous visitor.

## Automatic events

On iOS, iPadOS, tvOS, visionOS and Mac Catalyst the SDK sends these events
with no extra code:

| Event | Properties | When |
| --- | --- | --- |
| `app_installed` | — | first launch with the SDK |
| `app_updated` | `previous_version`, `previous_build` | first launch after the app version or build changes |
| `app_opened` | `cold_start` | the app comes to the foreground (`true` the first time in the process) |
| `app_backgrounded` | `foreground_ms` | the app goes to the background |
| `push_permission_changed` | `status`, `previous_status` | the app comes to the foreground and the notification permission changed (see [Permission](#2-permission)) |

Each one, and also `screen_viewed` and `push_opened`, carries `app_version`,
`app_build`, `os_name` (lowercase, `"ios"` on iPhone and iPad), `os_version`,
`platform` (the OS family, `"ios"`), `sdk_name` (`"whisperr-swift"`),
`sdk_version`, `locale` and `timezone` (IANA name).

Install and update detection compare the app version with the one stored at
the last launch, so they need persistence (on by default). After an upgrade
from an older SDK version (earlier Whisperr state, no stored version), the SDK
stores the version silently and sends neither event; `app_updated` fires on the
next version change.

Turn the events off with `WhisperrOptions(automaticEvents: false)`. When the
app goes to the background, the SDK always flushes the queue inside a
background task, so the last events of a session reach the server before iOS
suspends the app. App extensions and macOS send no lifecycle events.

## Screens

```swift
try await whisperr.screen("Paywall")   // sends screen_viewed { screen_name: "Paywall" }
```

## Identify

```swift
try await whisperr.identify(
    "user_123",
    traits: ["name": "Ada", "plan": "pro"],
    email: "ada@example.com",
    phone: "+15551234567"
)

try await whisperr.identify(
    "user_123",
    channels: [
        .email("ada@example.com", verified: true),
        .sms("+15551234567", optedIn: false)
    ]
)
```

`identify()` also sends `traits.timezone` (`TimeZone.current.identifier`, an IANA name) and `traits.locale` (`Locale.current`, normalized to BCP 47) by default so quiet hours and message language match the user; values you pass in `traits` always win, and nothing is sent for a value the platform can't provide.

Shortcut `email`, `phone`, and `pushToken` values expand to opted-in channels.
Use explicit `WhisperrChannel` values when you need consent or verification
control.

## Push notifications

The SDK does not bundle a push library. It does four jobs:

1. It sends the device token to Whisperr, with the token type.
2. It reports the notification permission.
3. It reports opens and gives you the deep link.
4. An optional extension product adds the image to a rich push.

### 1. Token

APNs (no Firebase): pass the `Data` token from the delegate callback.

```swift
func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
) {
    Whisperr.setPushToken(deviceToken)
}
```

The SDK sends the token as lowercase hex with `kind: "apns"`,
`platform: "ios"` and `push_env`. APNs has two environments, and a token
works in one only. The SDK finds the environment by itself:

- It reads `aps-environment` from the app's embedded provisioning profile.
  `development` gives `sandbox`. `production` gives `production`.
- With no profile, the simulator gives `sandbox`.
- Else the build decides: `DEBUG` gives `sandbox`, a release build gives
  `production`. App Store and TestFlight builds have no profile and use
  `production`.

To set the environment yourself, pass it:
`Whisperr.setPushToken(deviceToken, environment: .production)`.

Firebase Cloud Messaging: pass the FCM registration token. The SDK sends
`kind: "fcm"`.

```swift
func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
    if let fcmToken {
        Whisperr.setPushToken(fcmToken: fcmToken)
    }
}
```

Other tokens (Expo, OneSignal): use
`client.setPushToken(token, kind: .expo)` or `kind: .oneSignalSubscription`.
Without `kind`, the server finds the type from the token.

Token rules:

- Call it on every launch. The SDK sends the token only when the token, or
  one of its fields, changed. This also holds after an app restart.
- **After login**, the SDK sends the token at once.
- **Before login**, the SDK keeps the token and sends it with the next
  `identify()`.
- **Token rotation**: the SDK opts out the token it sent before and opts in
  the new one. Tokens from the user's other devices stay as they are.
- After `reset()` (logout), the SDK forgets the token. Call `setPushToken`
  again when the next user logs in.

### 2. Permission

The SDK sends `push_permission_changed` with `status` (`authorized`,
`provisional`, `denied` or `not_determined`) and `previous_status`. It sends
the event only when the status changed since the last one it sent from this
device. A user who turns off notifications is a churn signal, and Whisperr
then picks another channel.

By default the SDK reads the status each time the app comes to the
foreground. It uses `getNotificationSettings`, which never shows a prompt.
After your own prompt, report the answer at once:

```swift
UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in
    Whisperr.refreshPushPermission()
}
```

You can also report a status yourself: `Whisperr.pushPermissionChanged(.denied)`.
Turn the foreground read off with
`WhisperrOptions(automaticPushPermission: false)`. `automaticEvents: false`
turns it off too.

### 3. Opens and deep links

Call `handleNotificationResponse` when the user taps a notification. For a
Whisperr notification it sends `push_opened` with `whisperr_message_id`. It
returns the deep link from `whisperr_deep_link` (the older `deep_link` key
works too). It sends one event for each message, also when the same tap
arrives twice. It returns `nil`, and sends nothing, for notifications from
other senders and for a dismissal.

Make sure that the link is one your app expects before you open it.

**Cold start.** When a tap starts the app, the delegate can run before your
UI exists. The SDK keeps the link until you take it with
`Whisperr.consumePendingDeepLink()`, and posts
`Whisperr.deepLinkNotification` when a link arrives. Use one of the two
ways, not both: route the return value, or take the pending link.

Set the `UNUserNotificationCenter` delegate before
`application(_:didFinishLaunchingWithOptions:)` returns. If you do not, pass
the launch options to `Whisperr.handleLaunchOptions(launchOptions)`.

#### SwiftUI app

The SwiftUI `App` life cycle needs iOS 14 or later.

```swift
import SwiftUI
import UserNotifications
import Whisperr

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Task { await Whisperr.initialize(apiKey: "wpk_...") }
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Whisperr.setPushToken(deviceToken)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Whisperr.handleNotificationResponse(response) // the UI takes the link
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound]) // show pushes while the app is open, too
    }
}

@main
struct MyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear(perform: openPendingDeepLink) // cold start
                .onReceive(NotificationCenter.default.publisher(for: Whisperr.deepLinkNotification)) { _ in
                    openPendingDeepLink() // app already running
                }
        }
    }

    private func openPendingDeepLink() {
        guard let url = Whisperr.consumePendingDeepLink() else { return }
        // Route to the screen for `url` (your router or NavigationPath).
        print("open", url)
    }
}
```

#### UIKit app

```swift
import UIKit
import UserNotifications
import Whisperr

@main
final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        Task { await Whisperr.initialize(apiKey: "wpk_...") }
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in
            Whisperr.refreshPushPermission()
        }
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Whisperr.setPushToken(deviceToken)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let url = Whisperr.handleNotificationResponse(response) {
            open(url) // your router; check the URL first
        }
        completionHandler()
    }

    private func open(_ url: URL) {
        // Push the screen for `url`.
    }
}
```

With your own `WhisperrClient` instance, the same calls are
`try await client.setPushToken(deviceToken)`,
`client.handleNotificationResponse(response)`,
`await client.pushPermissionChanged(.authorized)` and
`await client.refreshPushPermission()`. The `Whisperr.…` helpers are
synchronous, never throw, and wait for `initialize` when you call them early.

With Swift 6 strict concurrency, build the `Sendable` payload in the delegate:
`WhisperrPushPayload(response: response)`, then pass it to
`await client.handleNotification(payload)`. `trackPushOpened(userInfo:)` from
0.3 still works.

### 4. Rich push (images)

Add a Notification Service Extension target to your app. Link the
`WhisperrNotificationServiceExtension` product to that target only. Then make
its principal class a subclass:

```swift
import WhisperrNotificationServiceExtension

final class NotificationService: WhisperrNotificationService {}
```

The push needs `"mutable-content": 1` in `aps` and an `https` image URL in
`whisperr_image_url` (`image_url` and FCM `fcm_options.image` work too). The
extension downloads the image (20 seconds at most, 10 MB at most, JPEG, PNG
or GIF) and attaches it. If the download fails or is too slow, the
notification shows without the image. It is never lost.

Already have an extension (for example from another push provider)? Call the
helper from your own `didReceive`:

```swift
WhisperrRichPush.attachImage(to: mutableContent) { content in
    contentHandler(content)
}
```

The extension product does not depend on `Whisperr`, sends no data, and
ships its own privacy manifest.

## Track

```swift
try await whisperr.track("payment_failed", properties: [
    "amount_cents": 4900,
    "reason": "card_declined"
])
```

Event names must be lowercase `snake_case`. Invalid names are dropped before
they enter the queue and are surfaced through `onError`.

## Delivery

- Events send to `POST /v1/events/batch`.
- Identity updates send to `POST /v1/identify`.
- Requests use `Authorization: Bearer <wpk_...>`.
- Each event carries a stable `$message_id` in `context` for backend dedup.
- `401`/`403` retain the queue and surface `auth`.
- `429`, `5xx`, timeouts, and network failures retry with bounded backoff
  (with jitter); if retries exhaust, the queue is retained for the next flush.
- A `Retry-After` header on `429` / `503` (seconds or an HTTP date) sets the
  wait before the next attempt, capped at 60 seconds.
- Other `4xx` responses drop the offending operation and surface `dropped`.

## Options

```swift
let whisperr = WhisperrClient(
    apiKey: "wpk_...",
    options: WhisperrOptions(
        flushInterval: 15,
        flushAt: 20,
        maxBatchSize: 500,
        maxQueueSize: 1_000,
        maxRetries: 6,
        debug: false,
        onError: { error in
            print("whisperr:", error.type.rawValue, error.message)
        }
    )
)
```

The default persistence uses `UserDefaults` and stores the pending queue, the
identified user, the last-sent push token pair and its fields (kind, platform,
APNs environment), the anonymous id, the opt-out choice, the last app version
seen, the push message ids already reported as opened, and the last
notification permission sent, so they survive app restarts. For tests or ephemeral runtimes, pass
`InMemoryWhisperrPersistence()`.

## Opt-out

```swift
await whisperr.optOut()   // nothing is queued or sent; the queue is discarded
await whisperr.optIn()    // collection resumes
let optedOut = await whisperr.isOptedOut
```

The choice is persisted and survives `reset()`. When this device registered a
push token, `optOut()` first sends one identify
that opts this device's token out, so Whisperr stops sending push here. Email,
SMS, and the user's other devices keep their state, and data the server already
has is not deleted. After `optIn()`, the next `setPushToken` registers the token
again.

## Privacy manifest

The package ships `PrivacyInfo.xcprivacy`. Xcode merges it into your app's
privacy report. It declares:

- No tracking (`NSPrivacyTracking` is `false`, no tracking domains).
- Collected data, linked to the user, not used for tracking: User ID
  (`external_user_id`), Device ID (the random `anonymous_id`), and Product
  Interaction (events, screens, app opens). Purposes: Analytics, Product
  Personalization, and Developer's Advertising or Marketing (retention
  messages).
- Required-reason API: `UserDefaults`, reason `CA92.1` (the SDK reads and
  writes its own queue and settings, only inside your app).

If you pass `email` or `phone` to `identify()`, or a push token to
`identify()` or `setPushToken`, declare those data types in your app's own
manifest. Reading the provisioning profile (APNs environment) and the
notification settings uses no required-reason API.

The `WhisperrNotificationServiceExtension` product ships a separate manifest:
no tracking, no collected data, no required-reason API. It only downloads the
image URL that the push carries.

## Development

The test suite consumes the shared `whisperr-spec` fixtures:

```bash
WHISPERR_SPEC_PATH=../whisperr-spec/conformance/wire.json swift test
```

Whisperr - predict churn, automate interventions, recover revenue.
