# Whisperr Swift SDK

Official Swift SDK for Whisperr mobile and Apple-platform apps. It identifies
users and tracks churn-signal events with an ordered queue, retry handling, and
stable event idempotency.

## Install

Add the package in Xcode or Swift Package Manager:

```swift
.package(url: "https://github.com/WhisperrAI/whisperr-swift.git", from: "0.1.0")
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

The default queue persistence uses `UserDefaults`. For tests or ephemeral
runtimes, pass `InMemoryWhisperrPersistence()`.

## Development

The test suite consumes the shared `whisperr-spec` fixtures:

```bash
WHISPERR_SPEC_PATH=../whisperr-spec/conformance/wire.json swift test
```

Whisperr - predict churn, automate interventions, recover revenue.
