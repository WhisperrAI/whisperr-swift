# Whisperr Swift SDK

Official Swift SDK for Whisperr mobile and Apple-platform apps. It identifies
users and tracks churn-signal events with an ordered queue, retry handling, and
stable event idempotency.

## Install

Add the package in Xcode or Swift Package Manager:

```swift
.package(url: "https://github.com/WhisperrAI/whisperr-swift.git", from: "0.2.0")
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
- `429`, `5xx`, timeouts, and network failures retry with bounded backoff; if
  retries exhaust, the queue is retained for the next flush.
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
identified user, and the last-sent push token pair so all three survive app
restarts. For tests or ephemeral runtimes, pass `InMemoryWhisperrPersistence()`.

## Development

The test suite consumes the shared `whisperr-spec` fixtures:

```bash
WHISPERR_SPEC_PATH=../whisperr-spec/conformance/wire.json swift test
```

Whisperr - predict churn, automate interventions, recover revenue.
