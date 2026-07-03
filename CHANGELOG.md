# Changelog

## 0.1.0

- Initial Swift SDK for Whisperr ingestion.
- Adds `WhisperrClient` with ordered queueing, UserDefaults persistence,
  batched event delivery, identity updates, `reset()` on logout,
  retry/auth/drop behavior, and stable `$message_id` idempotency.
- Adds spec-driven wire and behavior conformance tests against `whisperr-spec`.
