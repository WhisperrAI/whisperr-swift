# Changelog

## 0.2.0

- `setPushToken(_:)`: first-class push-token capture. Re-identifies the `push`
  channel for the current user, buffers tokens set before `identify()`,
  no-ops on repeated tokens, and opts the previous token out on rotation —
  matching the other Whisperr SDKs and verified against the new
  `whisperr-spec` `conformance/push.json` fixtures.
- `setPushToken(deviceToken:)`: APNs convenience that hex-encodes the `Data`
  token from `didRegisterForRemoteNotificationsWithDeviceToken` and forwards
  it.
- `reset()` now also clears buffered/remembered push tokens.
- New error case `WhisperrClientError.emptyPushToken`.

## 0.1.0

- Initial Swift SDK for Whisperr ingestion.
- Adds `WhisperrClient` with ordered queueing, UserDefaults persistence,
  batched event delivery, identity updates, `reset()` on logout,
  retry/auth/drop behavior, and stable `$message_id` idempotency.
- Adds spec-driven wire and behavior conformance tests against `whisperr-spec`.
