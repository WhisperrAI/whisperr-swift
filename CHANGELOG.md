# Changelog

## Unreleased

- **Automatic events** on UIKit platforms, on by default
  (`WhisperrOptions.automaticEvents`): `app_installed`, `app_updated`
  (`previous_version`, `previous_build`), `app_opened` (`cold_start`) and
  `app_backgrounded` (`foreground_ms`). Each carries `app_version`,
  `app_build`, `os_name`, `os_version`, `platform`, `locale` and `timezone`.
  An app that used an older SDK version is not reported as a new install.
- **Flush on background**: the queue is flushed inside a UIKit background task
  when the app goes to the background.
- **Anonymous visitors** (whisperr-spec `conformance/anonymous.json`):
  `track()` before `identify()` no longer throws `missingUserID`. The event is
  sent under a persisted `anonymous_id`; the next `identify()` carries it so
  the server promotes those events; `reset()` rotates it.
- `screen(_:properties:)` sends `screen_viewed` with `screen_name`.
- `trackPushOpened(userInfo:)` / `trackPushOpened(_: WhisperrPushPayload)`
  send `push_opened` with `whisperr_message_id` (and `deep_link`), once per
  message id. Reads FCM top-level data and OneSignal `custom.a`.
- `optOut()` / `optIn()` / `isOptedOut`: global, persisted opt-out.
- `Retry-After` on `429` / `503` is honored (capped at 60 s). Exponential
  backoff gains up to 30 % jitter. `WhisperrSendResult` gains
  `.retryAfter(TimeInterval)` for custom transports.
- Apple privacy manifest `PrivacyInfo.xcprivacy` ships as a package resource.
- The `email:` shortcut still sends no `verified` key (pinned by a test), so
  the SDK never marks an address unverified on its own.

## 0.2.2

- `identify()` now fills the reserved traits `timezone` (IANA name, from
  `TimeZone.current`) and `locale` (BCP 47, from `Locale.current`) by default,
  so the engine evaluates quiet hours in the user's zone instead of UTC and
  picks the message language. Caller-supplied values always win; a value the
  platform cannot provide is omitted. `setPushToken()`'s partial identify stays
  traits-free. `WhisperrClient.init` gains an injectable `deviceTraits`
  resolver (defaulted) for tests.

## 0.2.1

- Fix: the in-flight restore is now awaited by every entrant. `start()` set a
  `started` flag *before* `await restore()`, so a `setPushToken` racing the
  launch (e.g. from the APNs registration callback) sailed past the flag,
  observed `currentUserID == nil`, and silently buffered a token that was never
  sent for an already-identified returning user; an `identify()` racing restore
  could also be clobbered when the persisted state loaded. Entrants now await
  the same restore task, and restore no longer overwrites state mutated after
  `start()` began.
- Fix: `setPushToken("")` / whitespace-only tokens are silently ignored instead
  of throwing `WhisperrClientError.emptyPushToken` — `getToken()` can return an
  empty string before the device registers, and the method is documented as
  safe to call on every launch. Aligns Swift with the React Native and Flutter
  SDKs. (The `emptyPushToken` case is retained for source compatibility but is
  no longer thrown.)
- Fix: the dedup pair is a mark of what was **delivered**. A registration whose
  request is dropped (non-retryable `4xx`) or evicted on queue overflow now
  clears the pair, so the token re-registers next time instead of being wedged
  opted-out forever by a single rejection.
- `identify(pushToken:)` (or an explicit push channel on identify) now rotates
  like `setPushToken`: a differing token opts the previous one out in the same
  body instead of stranding it opted-in.
- Verified against the hardened `whisperr-spec` `conformance/push.json` (reset,
  empty-token, `identify(pushToken:)`, and restart-then-reidentify cases), plus
  new unit tests for the restore race and the drop-clears-mark behavior.

## 0.2.0

- `setPushToken(_:)`: first-class push-token capture. Re-identifies the `push`
  channel for the current user, buffers tokens set before `identify()`,
  no-ops on repeated tokens, and opts the previous token out on rotation —
  matching the other Whisperr SDKs and verified against the new
  `whisperr-spec` `conformance/push.json` fixtures.
- The identified user and the last-sent (user, push token) pair are now
  persisted alongside the queue, so same-token dedupe and rotation opt-out
  survive app restarts (per the spec's `restart` conformance cases). State
  persisted by 0.1.x is still restored.
- `setPushToken(deviceToken:)`: APNs convenience that hex-encodes the `Data`
  token from `didRegisterForRemoteNotificationsWithDeviceToken` and forwards
  it.
- `reset()` now also clears buffered/remembered push tokens, including the
  persisted identity and last-sent pair.
- New error case `WhisperrClientError.emptyPushToken`.

## 0.1.0

- Initial Swift SDK for Whisperr ingestion.
- Adds `WhisperrClient` with ordered queueing, UserDefaults persistence,
  batched event delivery, identity updates, `reset()` on logout,
  retry/auth/drop behavior, and stable `$message_id` idempotency.
- Adds spec-driven wire and behavior conformance tests against `whisperr-spec`.
