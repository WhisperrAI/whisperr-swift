# Whisperr Swift SDK

Official Swift SDK for Whisperr mobile and Apple-platform apps. It identifies
users and tracks churn-signal events with an ordered queue, retry handling, and
stable event idempotency.

## Install

Add the package in Xcode or Swift Package Manager:

```swift
.package(url: "https://github.com/WhisperrAI/whisperr-swift.git", from: "0.3.0")
```

## Quick Start

```swift
import Whisperr

let whisperr = WhisperrClient(apiKey: "wrk_...")
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

Each one also carries `app_version`, `app_build`, `os_name` (lowercase, `"ios"`
on iPhone and iPad), `os_version`, `platform` (the OS family, `"ios"`),
`sdk_name` (`"whisperr-swift"`), `sdk_version`, `locale` and `timezone` (IANA
name).

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

The SDK never bundles a push library — hand it the APNs device token (or an
FCM registration token string) and Whisperr keeps the `push` channel current:

```swift
func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
) {
    Task {
        // Hex-encodes the token and forwards it to setPushToken(_:).
        try await whisperr.setPushToken(deviceToken: deviceToken)
    }
}
```

- Called **after login**, `setPushToken` re-identifies the push channel
  immediately.
- Called **before login**, the token is buffered and attached to the next
  `identify()`.
- **Token rotation** is handled: the previously sent token is opted out and
  the new one opted in, so stale tokens don't accumulate — and tokens from the
  user's other devices are never touched. The last-sent pair is persisted, so
  a rotation that happens after an app relaunch still retires the old token.
- Setting the **same token twice** is a no-op — including across app
  restarts — so it's safe to call on every launch or token refresh.
- After `reset()` (logout), call `setPushToken` again once the next user logs
  in.

### Push opens

Report when the user taps a Whisperr push, so the engine learns which messages
work. The SDK reads `whisperr_message_id` (and `deep_link`) from the payload
and sends `push_opened`. A message id is reported once, even if the tap
arrives twice. Notifications not sent by Whisperr are ignored.

```swift
func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
) {
    // Swift 6 strict concurrency: build the Sendable payload first.
    let payload = WhisperrPushPayload(userInfo: response.notification.request.content.userInfo)
    Task {
        if let payload {
            try? await whisperr.trackPushOpened(payload)
        }
        completionHandler()
    }
}
```

`trackPushOpened(userInfo:)` does the same in one call.

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
- Requests use `Authorization: Bearer <wrk_...>`.
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
    apiKey: "wrk_...",
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
identified user, the last-sent push token pair, the anonymous id, the opt-out
choice, the last app version seen, and the push message ids already reported
as opened, so they survive app restarts. For tests or ephemeral runtimes, pass
`InMemoryWhisperrPersistence()`.

## Opt-out

```swift
await whisperr.optOut()   // nothing is queued or sent; the queue is discarded
await whisperr.optIn()    // collection resumes
let optedOut = await whisperr.isOptedOut
```

The choice is persisted and survives `reset()`. Opt-out is local to the device:
it does not delete data the server already has.

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

If you pass `email`, `phone` or a push token to `identify()`, declare those
data types in your app's own manifest.

## Development

The test suite consumes the shared `whisperr-spec` fixtures:

```bash
WHISPERR_SPEC_PATH=../whisperr-spec/conformance/wire.json swift test
```

Whisperr - predict churn, automate interventions, recover revenue.
