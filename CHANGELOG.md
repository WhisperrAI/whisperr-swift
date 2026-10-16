# Changelog

## 0.6.0 (unreleased)

- **`emailOptedIn` on `identify()`.** Your user's email consent, sent as
  `opted_in` on the `email` shortcut. Whether it opts the address in depends
  on the app's answer to "Does your signup get permission to email users?" in
  Whisperr.
- **Behavior change:** the `email` shortcut no longer sends `opted_in: true`
  on its own. Without `emailOptedIn` it sends no `opted_in`. Versions before
  0.6.0 send `opted_in: true` on every email shortcut. Push and phone are
  unchanged.
- An email channel with `opted_in: true` also sends `consent_source: "user"`.
  The server needs it to grant consent in "Per user" mode, which tells this
  apart from the `true` that older versions sent by default.

## 0.5.1

- **Rejected requests warn without debug.** When the server rejects a request
  with a non-retryable `4xx` (not `401`, `403` or `429`), the SDK drops it, as
  before, and now prints a warning the first time each status code occurs,
  even with `debug` off. With `debug` on it prints one for every drop. The
  message names only the status code. Every drop still reaches `onError`.
  `429` and `5xx` keep retrying.

## 0.5.0

This is a minor release (0.5.0). It follows whisperr-spec contract v2. It
needs the Whisperr backend that accepts `client_app_id`, `provider_project`
and anonymous identifies; an older server answers `400`.

- **Restore identify at start.** When the SDK has a stored user (and the user
  did not opt out), it queues one identify at start: `external_user_id`,
  `anonymous_id`, and the `timezone`, `locale` and `app_language` traits. No
  channels. It waits 5 seconds (or until the first flush) and is skipped when
  the app identifies a user first, or when the server got the same trait
  values for this user less than 24 hours ago. It goes through the persisted
  queue. Apps must still call `identify()` on session restore: the SDK cannot
  know a user who signed in before the SDK install.
- **`setAppLanguage(_:)`.** Sets the language the user picked in the app
  (BCP 47; `_` becomes `-`; an invalid tag is ignored). Persisted, kept
  across `reset()`. A new value is sent at once (partial identify, or an
  anonymous identify before login). Every identify carries it as
  `traits.app_language`; a caller value wins. `nil` clears it. Also on the
  `Whisperr` facade.
- **Anonymous push tokens.** `setPushToken` before `identify()` sends the
  token at once in an anonymous identify (`anonymous_id` + push channel). The
  dedupe pair is now (subject, token), where the subject is the user or the
  anonymous id. `identify()` still attaches the token.
- **`reset()` moves the token.** With a registered token, `reset()` opts it
  out under the old user, rotates `anonymous_id`, and opts it in under the new
  handle. While the permission is `denied`, the token stays held.
- **Push token fields.** Every push entry carries `platform` (the device's,
  unless you pass one) and `client_app_id` (the bundle id). A `kind: apns`
  token always carries `push_env`. New `providerProject:` parameter on
  `setPushToken(_:kind:platform:environment:providerProject:)`;
  `setPushToken(fcmToken:firebaseProjectID:)`; new
  `setPushToken(oneSignalSubscriptionID:oneSignalAppID:)`. No Firebase
  dependency. `identify(pushToken:)` carries `platform` and `client_app_id`.
- **Re-registration.** The same token is sent again when the last send is 7
  days old or more. State from 0.4.x has no send time, so the next
  `setPushToken` sends once.
- **`push_opened`** carries `action_id` (`default` for a tap, else the action
  button id) and `cold_start` (when the SDK can tell).
- **`push_received`** (new reserved event): `handleWillPresent(_:)` and
  `trackPushReceived(_:)` send it for a Whisperr push received in the
  foreground, once per message id, with `whisperr_message_id`,
  `foreground: true` and `source: "foreground"`. Not sent from the
  Notification Service Extension.
- **`requestPushAuthorization(provisional:)`** asks for permission (alert,
  badge, sound, optionally provisional) and reports the result as
  `push_permission_changed`.
- **Versions on every event.** Every event carries `app_version`,
  `app_build`, `platform`, `sdk_name` and `sdk_version` in `context`. A
  caller key wins. `kWhisperrSdkName` is public.
- **Fix: a flush could skip the drain.** A flush that started while an
  earlier drain had just ended could return without sending what was queued
  since. `close()` could then leave ops in the queue until the next launch.
- **Conformance.** The spec runners execute the `v2.json` sections
  `restoreIdentify`, `appLanguage`, `anonymousPush`, `pushRegistration` and
  `versionContext`, and `automatic.json` `pushEventsV2` (except the
  Notification Service Extension case). They skip the legacy cases these
  sections supersede.

- **Permission changes the push token.** A `denied` report (from
  `pushPermissionChanged(_:)` or the foreground read) sends one identify that
  opts this device's push token out, and the SDK holds the token. A token set
  while `denied` is held, not sent. An `authorized` or `provisional` report
  opts the held token back in. The SDK stores the last reported status; it
  survives a restart and `reset()`. Before, Swift sent only the event and left
  the token opted in. This matches React Native and Flutter (whisperr-spec
  SPEC.md "Push permission and the token").
- **Opt-out reaches the server.** `optOut()` sends one identify that opts this
  device's push token out (`opted_in: false`) when a token was registered. It
  goes under the user the token was registered for. The SDK delivers and
  retries it like any queued request, also after a restart. Then it sends
  nothing until `optIn()`. A request that was in flight during `optOut()` and
  then fails is not retried. Opt-out forgets the last-sent token, so after
  `optIn()` the next `setPushToken` registers it again. Queued push opt-outs
  (a rotation, a denied permission, an earlier opt-out) are kept, not
  discarded. A second
  `optOut()` while opted out is a no-op.
- **Older opted-out installs.** A device that opted out on 0.4.x and still has
  a registered token sends the same opt-out once at start.
- **Conformance.** The spec runners execute the `push_permission_changed`
  cases in `automatic.json`, and the opt-out and permission cases in
  `push.json`.

## 0.4.0

This is a minor release (0.4.0). It makes push work end to end on iOS.

- **APNs token with its type.** `setPushToken(_ deviceToken: Data)` sends the
  token as lowercase hex with `kind: "apns"`, `platform` and `push_env`. The
  SDK finds the APNs environment from the embedded provisioning profile, then
  the simulator, then the `DEBUG` build flag. An `environment:` parameter
  overrides it. `setPushToken(deviceToken:)` from 0.3 still works.
- **FCM token with its type.** `setPushToken(fcmToken:)` sends `kind: "fcm"`.
  `setPushToken(_:kind:platform:environment:)` takes any token type. A bare
  string sends no type, as in 0.3, and the server infers it.
- **Dedupe on token fields.** The SDK sends the token again when a field
  changes (for example the environment), and never opts out the same token.
  An install upgraded from 0.3 sends its `kind` and `push_env` one time.
- **Permission.** `pushPermissionChanged(_:)` and `refreshPushPermission()`
  send `push_permission_changed` (`status`, `previous_status`) when the status
  changes. The SDK also reads the status on each move to the foreground.
  `WhisperrOptions(automaticPushPermission: false)` stops the read.
- **Opens and deep links.** `handleNotificationResponse(_:)` sends
  `push_opened` and returns the deep link (`whisperr_deep_link`, or the older
  `deep_link`). A dismissal sends nothing. `handleNotification(_:)` is the
  `Sendable` form.
- **Static push helpers.** `Whisperr.setPushToken`, `Whisperr.pushPermissionChanged`,
  `Whisperr.refreshPushPermission`, `Whisperr.handleNotificationResponse`,
  `Whisperr.handleLaunchOptions` and `Whisperr.consumePendingDeepLink` are
  synchronous and never throw. A call before `initialize` finishes waits for
  it. `Whisperr.deepLinkNotification` tells the UI that a link is waiting
  (cold start).
- **Rich push.** New product `WhisperrNotificationServiceExtension`:
  subclass `WhisperrNotificationService` in a Notification Service Extension
  to attach the image in `whisperr_image_url`. It has a timeout, a size limit,
  and a safe fallback. `WhisperrRichPush.attachImage` works in an extension
  you already have.
- **Common properties.** `screen_viewed` and `push_opened` now carry the same
  app and OS properties as the lifecycle events, as whisperr-spec
  `automatic.json` requires. The test suite now runs `automatic.json` and the
  `push.json` kind cases.

## 0.3.0

This is a minor release. Automatic events are on by default, so apps that
depend on `0.2.x` do not get them until they move to `0.3.0`.

- **Automatic events.** On UIKit platforms the SDK sends `app_installed`,
  `app_updated`, `app_opened` and `app_backgrounded` by itself. It also sends
  the queue when the app goes to the background. An upgrade from 0.2.x never
  sends `app_installed`.
- **Off switch.** `WhisperrOptions(automaticEvents: false)` stops automatic
  events.
- **Anonymous visitors.** `track()` before `identify()` no longer throws. The
  event goes out under a saved `anonymous_id`. The next `identify()` links
  those events to the user. `reset()` makes a new id.
- **Screens.** `screen(_:properties:)` sends `screen_viewed`.
- **Push opens.** `trackPushOpened(userInfo:)` sends `push_opened` one time for
  each Whisperr message. It reads FCM and OneSignal payloads.
- **Opt-out.** `optOut()`, `optIn()` and `isOptedOut`. The choice is saved on
  the device. When a user opts out, the SDK sends nothing and clears its queue.
- **Retry-After.** On `429` and `503` the SDK waits as long as the server asks
  (60 s at most). Retries also get random jitter.
- **Privacy manifest.** The package ships `PrivacyInfo.xcprivacy`. The SDK does
  no tracking. The manifest declares the user ID, the anonymous device ID and
  product interaction.

### Breaking change

- `WhisperrSendResult` has a new case, `.retryAfter(TimeInterval)`. Code that
  switches over this enum, for example a custom `WhisperrTransport` that wraps
  another one, must handle the new case or it will not compile.

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
