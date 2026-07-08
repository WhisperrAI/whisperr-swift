# Changelog

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
