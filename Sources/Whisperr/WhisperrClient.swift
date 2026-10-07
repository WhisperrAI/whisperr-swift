import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

public let kWhisperrSdkVersion = "0.4.0"
public let kWhisperrDefaultBaseURL = URL(string: "https://api.whisperr.net")!

private let eventTypePattern = try! NSRegularExpression(
    pattern: "^[a-z0-9]+(?:_[a-z0-9]+)*$"
)

public actor WhisperrClient {
    private let options: WhisperrOptions
    private let transport: WhisperrTransport
    private let persistence: WhisperrPersistence?
    private let clock: @Sendable () -> Date
    private let idGenerator: @Sendable () -> String
    private let sleeper: @Sendable (TimeInterval) async -> Void
    /// Resolves the reserved identify trait defaults (see `DeviceTraits`);
    /// injectable so tests can pin or silence them.
    private let deviceTraits: @Sendable () -> [String: JSONValue]

    private var queue: [QueuedOperation] = []
    private var currentUserID: String?
    /// Push entry captured before identify(); attached to the next identify.
    private var pendingPush: WhisperrChannel?
    /// Last push token delivered and for which user — dedups refresh storms and
    /// lets a rotation opt the previous token out. Persisted (with the identity)
    /// so both survive an app restart.
    private var lastPushToken: String?
    private var lastPushUserID: String?
    /// The token fields (kind, platform, environment) delivered with
    /// `lastPushToken`. A same-token call that sets a new field sends again,
    /// so an install upgraded from 0.3.x reports its APNs environment once.
    private var lastPushMetadata = PushMetadata()
    /// The last notification permission sent as push_permission_changed.
    /// Persisted; reset() clears it.
    private var lastPushPermission: String?
    private let pushPermissionProvider: @Sendable () async -> WhisperrPushPermissionStatus?
    /// The device's anonymous handle (whisperr-spec SPEC.md → Anonymous
    /// visitors). Created on first use by a track before identify, carried by
    /// the next identify (which promotes it), rotated by reset(). Persisted.
    private var anonymousID: String?
    /// Global opt-out: while true nothing is queued or sent. Persisted, and
    /// kept across reset().
    private var optedOut = false
    /// The last app version and build seen at launch, for app_installed /
    /// app_updated. Persisted.
    private var seenAppVersion: String?
    private var seenAppBuild: String?
    /// True when the device holds any earlier Whisperr state (queue, user id,
    /// push-token dedupe pair, anonymous id — all in the one persisted key that
    /// 0.1.x / 0.2.x also wrote), even state that no longer decodes. Earlier
    /// state with no stored version means an SDK upgrade, not a new install:
    /// the version is stored silently and nothing is sent.
    private var restoredPriorState = false
    /// Push message ids whose push_opened is being queued right now, so a
    /// concurrent duplicate tap cannot pass the dedupe check.
    private var pushOpensInFlight: Set<String> = []
    /// Push message ids already reported as opened (most recent last). Persisted.
    private var openedPushMessageIDs: [String] = []
    /// Start of the current foreground period, for app_backgrounded.foreground_ms.
    private var foregroundSince: Date?
    /// The first app_opened of this process is the cold start.
    private var hasOpenedInProcess = false
    private let appEnvironment: @Sendable () -> AppEnvironment
    private let anonymousIDGenerator: @Sendable () -> String
    private let installsLifecycleObserver: Bool
    private var lifecycleObserver: AnyObject?
    private var closed = false
    /// The one-time restore, shared so every entrant (start / flush /
    /// identify / setPushToken via ensureUsable) awaits the SAME in-flight
    /// restore instead of racing past a `started` flag before state is loaded.
    private var restoreTask: Task<Void, Never>?
    private var flushLoop: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?

    public init(
        apiKey: String,
        baseURL: URL = kWhisperrDefaultBaseURL,
        options: WhisperrOptions = WhisperrOptions(),
        persistence: WhisperrPersistence? = nil,
        transport: WhisperrTransport? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        idGenerator: @escaping @Sendable () -> String = { UUID().uuidString },
        sleeper: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            guard seconds > 0 else {
                return
            }
            let nanoseconds = UInt64(seconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        deviceTraits: (@Sendable () -> [String: JSONValue])? = nil
    ) {
        self.init(
            apiKey: apiKey,
            baseURL: baseURL,
            options: options,
            persistence: persistence,
            transport: transport,
            clock: clock,
            idGenerator: idGenerator,
            sleeper: sleeper,
            deviceTraits: deviceTraits,
            appEnvironment: nil,
            anonymousIDGenerator: nil,
            installsLifecycleObserver: true,
            pushPermissionProvider: nil
        )
    }

    /// Full initializer. `appEnvironment`, `anonymousIDGenerator`,
    /// `installsLifecycleObserver` and `pushPermissionProvider` exist for
    /// tests only.
    init(
        apiKey: String,
        baseURL: URL,
        options: WhisperrOptions,
        persistence: WhisperrPersistence?,
        transport: WhisperrTransport?,
        clock: @escaping @Sendable () -> Date,
        idGenerator: @escaping @Sendable () -> String,
        sleeper: @escaping @Sendable (TimeInterval) async -> Void,
        deviceTraits: (@Sendable () -> [String: JSONValue])?,
        appEnvironment: (@Sendable () -> AppEnvironment)?,
        anonymousIDGenerator: (@Sendable () -> String)?,
        installsLifecycleObserver: Bool,
        pushPermissionProvider: (@Sendable () async -> WhisperrPushPermissionStatus?)? = nil
    ) {
        self.options = options
        self.persistence = options.enablePersistence
            ? (persistence ?? UserDefaultsWhisperrPersistence())
            : persistence
        self.transport = transport ?? URLSessionWhisperrTransport(
            baseURL: baseURL,
            apiKey: apiKey,
            sdkVersion: kWhisperrSdkVersion,
            timeout: options.requestTimeout
        )
        self.clock = clock
        self.idGenerator = idGenerator
        self.sleeper = sleeper
        // Internal by design: the resolver is not public API, only its output is.
        self.deviceTraits = deviceTraits ?? { DeviceTraits.current() }
        self.appEnvironment = appEnvironment ?? { AppEnvironment.current() }
        // The spec pins a UUID v4 for the anonymous handle.
        self.anonymousIDGenerator = anonymousIDGenerator ?? { UUID().uuidString.lowercased() }
        self.installsLifecycleObserver = installsLifecycleObserver
        self.pushPermissionProvider = pushPermissionProvider ?? { await WhisperrPushPermission.current() }
    }

    deinit {
        flushLoop?.cancel()
    }

    public var ready: Bool {
        !closed
    }

    public var pendingCount: Int {
        queue.count
    }

    public func start() async {
        // All entrants await the SAME restore. A second caller arriving while
        // restore is in flight (e.g. the APNs setPushToken callback racing the
        // launch's start()) blocks here until state is loaded, instead of
        // sailing past a `started` flag and reading currentUserID == nil.
        if let restoreTask {
            await restoreTask.value
            return
        }
        let task = Task { await self.restore() }
        restoreTask = task
        await task.value
        // Start the periodic flusher once, after restore has completed.
        if flushLoop == nil, options.flushInterval > 0 {
            let interval = options.flushInterval
            flushLoop = Task { [weak self, sleeper] in
                while !Task.isCancelled {
                    await sleeper(interval)
                    guard let self else { return }
                    await self.flush()
                }
            }
        }
        await attachLifecycle()
    }

    public func close() async {
        guard !closed else {
            return
        }
        await flush()
        closed = true
        flushLoop?.cancel()
        flushLoop = nil
        lifecycleObserver = nil
    }

    // MARK: - Opt-out

    /// True while the user is opted out. Persisted across launches and kept
    /// across `reset()`.
    public var isOptedOut: Bool {
        optedOut
    }

    /// Stops all collection: nothing is queued or sent until `optIn()`. Work
    /// already queued is discarded. The choice is persisted.
    ///
    /// When this device registered a push token, the SDK first sends one
    /// identify that opts that token out, under the user it was registered
    /// for, so the server stops sending push to this device. Other channels
    /// and the user's other devices are not changed, and data already sent is
    /// not deleted. After `optIn()`, the next `setPushToken` registers the
    /// token again.
    public func optOut() async {
        await start()
        guard !optedOut else {
            return
        }
        optedOut = true
        let pushOptOut = takePushOptOut()
        queue = queue.compactMap(\.pushRetirements) + (pushOptOut.map { [$0] } ?? [])
        pendingPush = nil
        await persist()
        if pushOptOut != nil {
            Task { await self.flush() }
        }
    }

    /// The identify that opts this device's last-sent push token out, under
    /// the user it was sent for. Forgets the pair, so the token registers
    /// again after `optIn()`.
    private func takePushOptOut() -> QueuedOperation? {
        defer {
            lastPushToken = nil
            lastPushUserID = nil
            lastPushMetadata = PushMetadata()
        }
        guard let userID = lastPushUserID, let token = lastPushToken else {
            return nil
        }
        return QueuedOperation(
            id: idGenerator(),
            kind: .identify,
            body: [
                "external_user_id": .string(userID),
                "channels": .array([.object(WhisperrChannel.push(token, optedIn: false).body)])
            ]
        )
    }

    /// Resumes collection after `optOut()`.
    public func optIn() async {
        await start()
        optedOut = false
        await persist()
    }

    // MARK: - App lifecycle

    /// Installs the UIKit lifecycle observer (flush on background, automatic
    /// events) and records the launch. No-op on platforms without
    /// `UIApplication` and inside app extensions.
    private func attachLifecycle() async {
        #if canImport(UIKit) && !os(watchOS)
        guard installsLifecycleObserver, lifecycleObserver == nil, !closed else {
            return
        }
        let inForeground: Bool? = await MainActor.run {
            guard let app = WhisperrApplication.shared else {
                return nil
            }
            return app.applicationState != .background
        }
        guard let inForeground, lifecycleObserver == nil else {
            return
        }
        lifecycleObserver = WhisperrLifecycleObserver(client: self)
        await handleAppLaunch(inForeground: inForeground)
        #endif
    }

    /// Called once per process at launch: sends app_installed / app_updated
    /// and, when the app launches into the foreground, the cold-start
    /// app_opened.
    func handleAppLaunch(inForeground: Bool) async {
        guard !closed else {
            return
        }
        await start() // persisted state (seen version, user, opt-out) first
        await recordAppVersion()
        if inForeground {
            await appOpened()
            await refreshPushPermissionIfAutomatic()
        }
    }

    func handleWillEnterForeground() async {
        guard !closed else {
            return
        }
        await start() // persisted state (seen version, user, opt-out) first
        await appOpened()
        await refreshPushPermissionIfAutomatic()
    }

    /// Sends app_backgrounded (with the length of the foreground period) and
    /// flushes, so the last events of a session leave the device before iOS
    /// suspends the app.
    func handleDidEnterBackground() async {
        guard !closed else {
            return
        }
        await start() // persisted state (seen version, user, opt-out) first
        let since = foregroundSince
        foregroundSince = nil
        if options.automaticEvents {
            var properties: [String: JSONValue] = [:]
            if let since {
                let elapsed = max(0, clock().timeIntervalSince(since))
                properties["foreground_ms"] = .number((elapsed * 1_000).rounded())
            }
            await trackAutomatic("app_backgrounded", properties)
        }
        await flush()
    }

    private func appOpened() async {
        foregroundSince = clock()
        let coldStart = !hasOpenedInProcess
        hasOpenedInProcess = true
        guard options.automaticEvents else {
            return
        }
        await trackAutomatic("app_opened", ["cold_start": .bool(coldStart)])
    }

    /// Compares the running app version with the one stored at the last
    /// launch. Without persistence an install cannot be told from a relaunch,
    /// so nothing is sent.
    private func recordAppVersion() async {
        guard persistence != nil else {
            return
        }
        let environment = appEnvironment()
        let version = environment.appVersion
        let build = environment.appBuild
        guard version != nil || build != nil else {
            return
        }
        guard seenAppVersion != version || seenAppBuild != build else {
            return
        }
        let firstSeen = seenAppVersion == nil && seenAppBuild == nil
        let previousVersion = seenAppVersion
        let previousBuild = seenAppBuild
        seenAppVersion = version
        seenAppBuild = build
        if options.automaticEvents {
            if firstSeen {
                // Earlier state from an older SDK version means the app ran
                // before: store the version silently (no app_installed, no
                // app_updated). app_updated fires on the next version change.
                if !restoredPriorState {
                    await trackAutomatic("app_installed", [:])
                }
            } else {
                var properties: [String: JSONValue] = [:]
                if let previousVersion {
                    properties["previous_version"] = .string(previousVersion)
                }
                if let previousBuild {
                    properties["previous_build"] = .string(previousBuild)
                }
                await trackAutomatic("app_updated", properties)
            }
        }
        await persist()
    }

    /// The flat properties every reserved event carries: app_version,
    /// app_build, os_name, os_version, platform, sdk_name, sdk_version,
    /// locale, timezone (or timezone_offset_minutes when no IANA name is
    /// known).
    private func automaticProperties() -> [String: JSONValue] {
        var out = appEnvironment().properties
        let traits = deviceTraits()
        if let locale = traits["locale"] {
            out["locale"] = locale
        }
        if let timezone = traits["timezone"] {
            out["timezone"] = timezone
        } else if let offset = traits["timezone_offset_minutes"] {
            out["timezone_offset_minutes"] = offset
        }
        return out
    }

    /// The common properties with `properties` on top (event values win).
    private func withAutomaticProperties(_ properties: [String: JSONValue]) -> [String: JSONValue] {
        var merged = automaticProperties()
        for (key, value) in properties {
            merged[key] = value
        }
        return merged
    }

    private func trackAutomatic(_ eventType: String, _ properties: [String: JSONValue]) async {
        try? await track(eventType, properties: withAutomaticProperties(properties))
    }

    /// Identifies the current user and persists traits/contact channels.
    ///
    /// The reserved traits `timezone` (IANA name, `TimeZone.current`) and
    /// `locale` (BCP 47, from `Locale.current`) are filled in by default so the
    /// engine evaluates quiet hours in the user's zone and picks the message
    /// language; any value you pass in `traits` wins, and a value the platform
    /// cannot provide is simply omitted.
    ///
    /// When this device already sent events before identify, the body carries
    /// its `anonymous_id`, so the server promotes those events into this user.
    /// Events still in the queue are moved to this user before they are sent.
    /// While the user is opted out, only the local user id is updated.
    public func identify(
        _ externalUserID: String,
        traits: [String: JSONValue] = [:],
        email: String? = nil,
        phone: String? = nil,
        pushToken: String? = nil,
        preferredChannel: WhisperrChannelType? = nil,
        channels: [WhisperrChannel] = []
    ) async throws {
        try await ensureUsable()
        let id = externalUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw WhisperrClientError.emptyExternalUserID
        }
        currentUserID = id
        guard !optedOut else {
            await persist()
            return
        }

        var body: [String: JSONValue] = ["external_user_id": .string(id)]
        if let anonymousID {
            body["anonymous_id"] = .string(anonymousID)
            backfillAnonymousEvents(userID: id)
        }
        let mergedTraits = withDeviceTraits(traits)
        if !mergedTraits.isEmpty {
            body["traits"] = .object(mergedTraits)
        }
        if let preferredChannel {
            body["preferred_channel"] = .string(preferredChannel.rawValue)
        }

        var resolvedChannels = buildChannels(
            email: email,
            phone: phone,
            pushToken: pushToken,
            explicit: channels
        )
        // A token buffered by setPushToken() rides along unless the caller
        // supplied its own push channel — or it matches the (restored)
        // last-sent pair for this user with no new token fields, in which
        // case there is nothing new to send.
        if let pending = pendingPush,
           !resolvedChannels.contains(where: { $0.type == .push }),
           !(lastPushUserID == id && lastPushToken == pending.address
               && !pending.addsPushMetadata(to: lastPushMetadata)) {
            resolvedChannels.append(pending)
        }
        // Rotation: if this identify registers a push token that differs from
        // the last one we sent for this user, opt the old one out in the same
        // body — exactly like setPushToken — so a token passed via pushToken:
        // (or an explicit push channel) isn't stranded opted-in.
        if let newPush = resolvedChannels.last(where: { $0.type == .push && $0.optedIn != false }),
           let last = (lastPushUserID == id) ? lastPushToken : nil,
           last != newPush.address,
           !resolvedChannels.contains(where: { $0.type == .push && $0.address == last }) {
            resolvedChannels.insert(.push(last, optedIn: false), at: 0)
        }
        rememberPushChannel(userID: id, channels: resolvedChannels)
        pendingPush = nil
        if !resolvedChannels.isEmpty {
            body["channels"] = .array(resolvedChannels.map { .object($0.body) })
        }

        await enqueue(QueuedOperation(
            id: idGenerator(),
            kind: .identify,
            body: body
        ))
    }

    /// Captures a device push token given as a string: an FCM registration
    /// token, an Expo push token, a OneSignal subscription id, or an APNs
    /// token already in hex. For a raw APNs token use
    /// `setPushToken(_ deviceToken: Data)`; for FCM, `setPushToken(fcmToken:)`.
    ///
    /// `kind`, `platform` and `environment` describe the token and are sent
    /// only when set; the server infers a missing kind from the token.
    ///
    /// With a known user this re-identifies the push channel immediately: a
    /// rotated token opts the previously sent one out, and setting the same
    /// token again is a no-op (safe to call on every launch or token refresh)
    /// unless it sets a token field to a new value. Called before `identify`,
    /// the token is buffered in memory and attached to the next identify.
    public func setPushToken(
        _ token: String,
        kind: WhisperrPushKind? = nil,
        platform: WhisperrPushPlatform? = nil,
        environment: WhisperrPushEnvironment? = nil
    ) async throws {
        try await ensureUsable()
        guard !optedOut else {
            return
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty / whitespace token is silently ignored: getToken() can return
        // an empty string before the device has registered, and this is safe to
        // call on every launch, so it must be a no-op (not an error). Matches the
        // React Native and Flutter SDKs.
        guard !trimmed.isEmpty else {
            return
        }
        let entry = WhisperrChannel.push(
            trimmed,
            optedIn: true,
            kind: kind,
            platform: platform,
            pushEnvironment: environment
        )
        guard let userID = currentUserID else {
            pendingPush = entry // attached to the next identify()
            return
        }
        let last = lastPushUserID == userID ? lastPushToken : nil
        if last == trimmed, !entry.addsPushMetadata(to: lastPushMetadata) {
            return // refresh storm — token and its fields unchanged
        }
        var channels: [WhisperrChannel] = []
        // Rotation: retire the token this client previously registered. The
        // server matches the opt-out by address, so it carries no token fields.
        if let last, last != trimmed {
            channels.append(.push(last, optedIn: false))
        }
        channels.append(entry)
        let body: [String: JSONValue] = [
            "external_user_id": .string(userID),
            "channels": .array(channels.map { .object($0.body) })
        ]
        rememberPushChannel(userID: userID, channels: channels)
        pendingPush = nil
        await enqueue(QueuedOperation(
            id: idGenerator(),
            kind: .identify,
            body: body
        ))
    }

    /// Captures the APNs device token from
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    /// It sends the token as lowercase hex with `kind: apns`, the platform,
    /// and the APNs environment. The environment comes from
    /// `WhisperrPushEnvironment.current` (the provisioning profile, then the
    /// build) unless you pass one.
    public func setPushToken(
        _ deviceToken: Data,
        environment: WhisperrPushEnvironment? = nil
    ) async throws {
        try await setPushToken(
            deviceToken.whisperrHexString,
            kind: .apns,
            platform: WhisperrPushPlatform.current,
            environment: environment ?? WhisperrPushEnvironment.current
        )
    }

    /// Same as `setPushToken(_ deviceToken: Data)`. Kept for 0.3.x callers.
    public func setPushToken(deviceToken: Data) async throws {
        try await setPushToken(deviceToken, environment: nil)
    }

    /// Captures a Firebase Cloud Messaging registration token (from
    /// `Messaging.messaging().token` or `messaging(_:didReceiveRegistrationToken:)`).
    /// It sends `kind: fcm` and the platform.
    public func setPushToken(fcmToken: String) async throws {
        try await setPushToken(fcmToken, kind: .fcm, platform: WhisperrPushPlatform.current)
    }

    /// Tracks a product event for the current user, or for `userID` when supplied.
    ///
    /// Before any `identify()` the event is sent right away under the device's
    /// `anonymous_id`; the next `identify()` promotes it into the user. While
    /// the user is opted out, this is a no-op.
    public func track(
        _ eventType: String,
        properties: [String: JSONValue] = [:],
        context: [String: JSONValue] = [:],
        userID: String? = nil
    ) async throws {
        try await ensureUsable()
        guard !optedOut else {
            return
        }
        let resolvedUserID = (userID ?? currentUserID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let type = eventType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !type.isEmpty else {
            throw WhisperrClientError.emptyEventType
        }
        guard isSnakeCase(type) else {
            emit(.init(
                type: .dropped,
                message: "invalid event_type \"\(type)\" - expected snake_case"
            ))
            log("invalid event_type \"\(type)\" - event was not queued")
            return
        }

        let messageID = idGenerator()
        var mergedContext = context
        mergedContext["$message_id"] = .string(messageID)

        var body: [String: JSONValue] = [
            "event_type": .string(type),
            "occurred_at": .string(formatTimestamp(clock())),
            "properties": .object(properties),
            "context": .object(mergedContext)
        ]
        if let resolvedUserID, !resolvedUserID.isEmpty {
            body["external_user_id"] = .string(resolvedUserID)
        } else {
            body["anonymous_id"] = .string(currentAnonymousID())
        }

        await enqueue(QueuedOperation(
            id: messageID,
            kind: .track,
            body: body
        ))
    }

    /// Sends a `screen_viewed` event with `screen_name`. Call it when a screen
    /// appears (for example from SwiftUI `.onAppear` or `viewDidAppear`).
    /// An empty name is ignored.
    public func screen(_ name: String, properties: [String: JSONValue] = [:]) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        var merged = properties
        merged["screen_name"] = .string(trimmed)
        try await track("screen_viewed", properties: withAutomaticProperties(merged))
    }

    /// Reports that the user opened a Whisperr push notification: sends
    /// `push_opened` with `whisperr_message_id` (and `deep_link` when the
    /// payload has one). Call it from
    /// `userNotificationCenter(_:didReceive:withCompletionHandler:)`.
    ///
    /// Returns false, and sends nothing, when the notification is not from
    /// Whisperr, when this message id was already reported (the same tap can
    /// arrive twice, for example at a cold launch), or while opted out.
    @discardableResult
    public func trackPushOpened(userInfo: [AnyHashable: Any]) async throws -> Bool {
        guard let payload = WhisperrPushPayload(userInfo: userInfo) else {
            return false
        }
        return try await trackPushOpened(payload)
    }

    /// `Sendable` form of `trackPushOpened(userInfo:)`. Use it with Swift 6
    /// strict concurrency: build the payload from `userInfo` in your delegate,
    /// then pass it here.
    @discardableResult
    public func trackPushOpened(_ payload: WhisperrPushPayload) async throws -> Bool {
        try await ensureUsable()
        guard !optedOut,
              !openedPushMessageIDs.contains(payload.messageID),
              !pushOpensInFlight.contains(payload.messageID) else {
            return false
        }
        var properties: [String: JSONValue] = [
            "whisperr_message_id": .string(payload.messageID)
        ]
        if let deepLink = payload.deepLink {
            properties["deep_link"] = .string(deepLink)
        }
        pushOpensInFlight.insert(payload.messageID)
        defer { pushOpensInFlight.remove(payload.messageID) }
        // Mark the id as sent only after the event is in the persisted queue.
        // If track throws (client closed), the id stays unmarked.
        try await track("push_opened", properties: withAutomaticProperties(properties))
        openedPushMessageIDs.append(payload.messageID)
        if openedPushMessageIDs.count > Self.maxRememberedPushOpens {
            openedPushMessageIDs.removeFirst(openedPushMessageIDs.count - Self.maxRememberedPushOpens)
        }
        await persist()
        return true
    }

    /// How many opened push message ids are kept for dedupe.
    static let maxRememberedPushOpens = 100

    /// For tests: how many opened push message ids are stored.
    var rememberedPushOpenCount: Int {
        openedPushMessageIDs.count
    }

    /// Tracks `push_opened` for a Whisperr notification (once per message id)
    /// and returns its deep link, or nil when the notification is not from
    /// Whisperr or has no valid link. It never throws: a closed client only
    /// skips the event.
    @discardableResult
    public func handleNotification(_ payload: WhisperrPushPayload) async -> URL? {
        _ = try? await trackPushOpened(payload)
        return payload.deepLinkURL
    }

    /// `userInfo` form of `handleNotification(_:)`.
    @discardableResult
    public func handleNotification(userInfo: [AnyHashable: Any]) async -> URL? {
        guard let payload = WhisperrPushPayload(userInfo: userInfo) else {
            return nil
        }
        return await handleNotification(payload)
    }

    #if canImport(UserNotifications) && !os(tvOS)
    /// Call it from `userNotificationCenter(_:didReceive:withCompletionHandler:)`.
    /// It returns the deep link at once, and sends `push_opened` in the
    /// background (once per message id). It returns nil, and sends nothing,
    /// for a notification not sent by Whisperr and for a dismissal.
    @discardableResult
    public nonisolated func handleNotificationResponse(_ response: UNNotificationResponse) -> URL? {
        guard let payload = WhisperrPushPayload(response: response) else {
            return nil
        }
        Task { _ = try? await self.trackPushOpened(payload) }
        return payload.deepLinkURL
    }
    #endif

    // MARK: - Push permission

    /// Reports the notification permission. It sends `push_permission_changed`
    /// with `status` (and `previous_status`) when the status differs from the
    /// last one sent from this device, and returns true when it sent.
    ///
    /// Call it after `requestAuthorization`, or leave it to the SDK: with
    /// `automaticPushPermission` (on by default) the SDK reads the permission
    /// on each move to the foreground.
    @discardableResult
    public func pushPermissionChanged(_ status: WhisperrPushPermissionStatus) async -> Bool {
        guard !closed else {
            return false
        }
        await start()
        guard !optedOut, lastPushPermission != status.rawValue else {
            return false
        }
        let previous = lastPushPermission
        // Claim the new status before the first await, so a concurrent call
        // with the same status cannot send it twice.
        lastPushPermission = status.rawValue
        var properties: [String: JSONValue] = ["status": .string(status.rawValue)]
        if let previous {
            properties["previous_status"] = .string(previous)
        }
        do {
            // The enqueue persists the claimed status with the event.
            try await track("push_permission_changed", properties: withAutomaticProperties(properties))
            return true
        } catch {
            if lastPushPermission == status.rawValue {
                lastPushPermission = previous
            }
            return false
        }
    }

    /// Reads the notification permission without prompting
    /// (`UNUserNotificationCenter.getNotificationSettings`) and reports it
    /// through `pushPermissionChanged(_:)`. Returns the status read, or nil
    /// where it cannot be read.
    @discardableResult
    public func refreshPushPermission() async -> WhisperrPushPermissionStatus? {
        guard !closed, let status = await pushPermissionProvider() else {
            return nil
        }
        await pushPermissionChanged(status)
        return status
    }

    private func refreshPushPermissionIfAutomatic() async {
        guard options.automaticEvents, options.automaticPushPermission else {
            return
        }
        await refreshPushPermission()
    }

    /// Clears the current user (e.g. on logout) after flushing pending work,
    /// including the persisted identity and last-sent push token pair. The
    /// anonymous handle rotates, so the next person on this device is a new
    /// anonymous visitor.
    public func reset() async {
        await flush()
        currentUserID = nil
        pendingPush = nil
        lastPushToken = nil
        lastPushUserID = nil
        lastPushMetadata = PushMetadata()
        // The next user on this device gets a fresh permission report.
        lastPushPermission = nil
        anonymousID = nil // a new handle is created on the next anonymous event
        await persist()
    }

    /// The device's anonymous handle, created on first use.
    private func currentAnonymousID() -> String {
        if let anonymousID {
            return anonymousID
        }
        let created = anonymousIDGenerator()
        anonymousID = created
        return created
    }

    /// Queued pre-identify events go out under the user who just identified.
    /// Events already sent are promoted by the identify's `anonymous_id`.
    private func backfillAnonymousEvents(userID: String) {
        for index in queue.indices where queue[index].kind == .track {
            guard queue[index].body["external_user_id"] == nil,
                  queue[index].body["anonymous_id"] != nil else {
                continue
            }
            queue[index].body.removeValue(forKey: "anonymous_id")
            queue[index].body["external_user_id"] = .string(userID)
        }
    }

    /// Drains the current queue until it is empty or delivery must pause.
    /// Concurrent callers await the in-flight drain pass instead of starting
    /// another one.
    public func flush() async {
        guard !closed else {
            return
        }
        await start()
        if let flushTask {
            await flushTask.value
            return
        }
        let task = Task { await drain() }
        flushTask = task
        await task.value
        flushTask = nil
    }

    private func drain() async {
        while !queue.isEmpty {
            let batch = takeNextBatch()
            let takenWhileOptedOut = optedOut
            let outcome = await deliver(batch)
            // optOut() ran while this batch was in flight and it failed: keep
            // only its push opt-outs, as optOut() does for the queue.
            if optedOut, !takenWhileOptedOut, outcome.retainsBatch {
                queue.insert(contentsOf: batch.compactMap(\.pushRetirements), at: 0)
                await persist()
                continue
            }

            switch outcome {
            case .ok:
                await persist()
            case .drop(let status):
                emit(.init(
                    type: .dropped,
                    message: "dropped \(batch.count) operation(s) - rejected by server",
                    status: status
                ))
                await forgetPushMark(batch) // registration rejected — let it re-send
                await persist()
            case .auth(let status):
                queue.insert(contentsOf: batch, at: 0)
                emit(.init(type: .auth, message: "delivery paused - API key rejected", status: status))
                await persist()
                return
            case .retryExhausted(let status):
                queue.insert(contentsOf: batch, at: 0)
                emit(.init(
                    type: .retryExhausted,
                    message: "delivery failed after retries; will retry on next flush",
                    status: status
                ))
                await persist()
                return
            }
        }
    }

    private func ensureUsable() async throws {
        if closed {
            throw WhisperrClientError.closed
        }
        await start()
    }

    private func enqueue(_ op: QueuedOperation) async {
        queue.append(op)
        if queue.count > options.maxQueueSize {
            let overflow = queue.count - options.maxQueueSize
            let evicted = Array(queue.prefix(overflow))
            queue.removeFirst(overflow)
            await forgetPushMark(evicted) // an evicted registration never shipped
            emit(.init(
                type: .dropped,
                message: "queue exceeded \(options.maxQueueSize); dropped \(overflow) oldest operation(s)"
            ))
        }
        await persist()
        if queue.count >= options.flushAt {
            Task { await self.flush() }
        }
    }

    private func takeNextBatch() -> [QueuedOperation] {
        if queue[0].kind == .identify {
            return [queue.removeFirst()]
        }

        var count = 0
        while count < queue.count,
              count < options.maxBatchSize,
              queue[count].kind == .track {
            count += 1
        }

        let batch = Array(queue.prefix(count))
        queue.removeFirst(count)
        return batch
    }

    private func deliver(_ batch: [QueuedOperation]) async -> DeliveryOutcome {
        let path: String
        let body: JSONValue
        if batch[0].kind == .identify {
            path = "/v1/identify"
            body = .object(batch[0].body)
        } else {
            path = "/v1/events/batch"
            body = .object(["events": .array(batch.map { .object($0.body) })])
        }

        var retries = 0
        while true {
            switch await transport.send(path: path, body: body) {
            case .ok:
                return .ok
            case .drop(let status):
                return .drop(status)
            case .auth(let status):
                return .auth(status)
            case .retry:
                retries += 1
                if retries > options.maxRetries {
                    return .retryExhausted(nil)
                }
                await sleeper(backoff(attempt: retries))
            case .retryAfter(let seconds):
                retries += 1
                if retries > options.maxRetries {
                    return .retryExhausted(nil)
                }
                // The server said when to come back. A small jitter keeps many
                // devices from retrying in the same instant.
                let wait = min(max(0, seconds), kWhisperrMaxRetryAfter)
                await sleeper(wait + Double.random(in: 0...0.25))
            }
        }
    }

    private func restore() async {
        guard let data = await persistence?.load(), !data.isEmpty else {
            return
        }
        restoredPriorState = true
        var state: PersistedState?
        if let decoded = try? JSONDecoder.whisperr.decode(PersistedState.self, from: data) {
            state = decoded
        } else if let legacyQueue = try? JSONDecoder.whisperr.decode([QueuedOperation].self, from: data) {
            // Data written by 0.1.x was the bare queue array.
            state = PersistedState(queue: legacyQueue)
        } else {
            log("failed to restore persisted state")
            state = nil
        }
        guard let state else {
            return
        }
        // Load persisted state without overwriting anything a caller mutated
        // after start() began (e.g. an identify() or setPushToken() that ran
        // while this restore's `await load()` was suspended): restore only the
        // fields still at their fresh-launch defaults, so a live value wins.
        if queue.isEmpty {
            queue = state.queue
        }
        if currentUserID == nil {
            currentUserID = state.userID
        }
        if lastPushUserID == nil, lastPushToken == nil {
            lastPushUserID = state.lastPushUserID
            lastPushToken = state.lastPushToken
            lastPushMetadata = PushMetadata(
                kind: state.lastPushKind,
                platform: state.lastPushPlatform,
                pushEnvironment: state.lastPushEnvironment
            )
        }
        if lastPushPermission == nil {
            lastPushPermission = state.pushPermission
        }
        if anonymousID == nil {
            anonymousID = state.anonymousID
        }
        if !optedOut {
            optedOut = state.optedOut ?? false
        }
        if seenAppVersion == nil, seenAppBuild == nil {
            seenAppVersion = state.appVersion
            seenAppBuild = state.appBuild
        }
        if openedPushMessageIDs.isEmpty {
            openedPushMessageIDs = state.openedPushMessageIDs ?? []
        }
        // 0.4.x opted out locally only: it could keep the last-sent pair, and
        // a failed in-flight batch could land back in its queue.
        if optedOut {
            queue = queue.compactMap(\.pushRetirements) + (takePushOptOut().map { [$0] } ?? [])
            await persist()
        }
    }

    private func persist() async {
        guard let persistence else {
            return
        }
        let state = PersistedState(
            queue: queue,
            userID: currentUserID,
            lastPushUserID: lastPushUserID,
            lastPushToken: lastPushToken,
            anonymousID: anonymousID,
            optedOut: optedOut ? true : nil,
            appVersion: seenAppVersion,
            appBuild: seenAppBuild,
            openedPushMessageIDs: openedPushMessageIDs.isEmpty ? nil : openedPushMessageIDs,
            lastPushKind: lastPushMetadata.kind,
            lastPushPlatform: lastPushMetadata.platform,
            lastPushEnvironment: lastPushMetadata.pushEnvironment,
            pushPermission: lastPushPermission
        )
        do {
            let data = state.isEmpty ? nil : try JSONEncoder.whisperr.encode(state)
            await persistence.save(data)
        } catch {
            log("failed to persist state: \(error)")
        }
    }

    private func buildChannels(
        email: String?,
        phone: String?,
        pushToken: String?,
        explicit: [WhisperrChannel]
    ) -> [WhisperrChannel] {
        var out: [WhisperrChannel] = []
        if let value = trimmedNonEmpty(email) {
            out.append(.email(value, optedIn: true))
        }
        if let value = trimmedNonEmpty(phone) {
            out.append(.sms(value, optedIn: true))
        }
        if let value = trimmedNonEmpty(pushToken) {
            out.append(.push(value, optedIn: true))
        }
        out.append(contentsOf: explicit)
        return out
    }

    /// Trait keys the engine reads for the user's zone. Any of them supplied by
    /// the caller means "don't default `timezone`".
    private static let timezoneKeys = ["timezone", "time_zone", "tz"]

    /// Merges the device defaults *under* the caller's traits: caller values
    /// always win, and a key the platform cannot provide is simply absent. Only
    /// full identify() calls get defaults — `setPushToken`'s partial identify
    /// stays traits-free by contract.
    private func withDeviceTraits(_ traits: [String: JSONValue]) -> [String: JSONValue] {
        var merged = deviceTraits()
        if Self.timezoneKeys.contains(where: { traits[$0] != nil }) {
            merged.removeValue(forKey: "timezone")
        }
        for (key, value) in traits {
            merged[key] = value
        }
        return merged
    }

    /// Records the opted-in push channel (if any) that an identify just sent,
    /// with its token fields. For the same (user, token) the fields merge as
    /// on the server: a field the entry did not send keeps its value.
    private func rememberPushChannel(userID: String, channels: [WhisperrChannel]) {
        for channel in channels where channel.type == .push && channel.optedIn != false {
            if lastPushUserID != userID || lastPushToken != channel.address {
                lastPushMetadata = PushMetadata()
            }
            lastPushUserID = userID
            lastPushToken = channel.address
            lastPushMetadata.merge(channel)
        }
    }

    /// A dropped (4xx) or overflow-evicted op never reached the server, so the
    /// (user, token) pair it would have registered must not stay marked as
    /// delivered — otherwise a single rejection wedges that token opted-out of
    /// every future setPushToken. Clears the mark when a discarded op carried it.
    private func forgetPushMark(_ discarded: [QueuedOperation]) async {
        guard let token = lastPushToken, let user = lastPushUserID else {
            return
        }
        for op in discarded where op.kind == .identify {
            guard op.body["external_user_id"] == .string(user),
                  case .array(let channels)? = op.body["channels"] else {
                continue
            }
            let carried = channels.contains { channel in
                guard case .object(let fields) = channel else {
                    return false
                }
                let optedIn = fields["opted_in"]
                return fields["channel"] == .string("push")
                    && fields["address"] == .string(token)
                    && (optedIn == nil || optedIn == .bool(true))
            }
            if carried {
                lastPushUserID = nil
                lastPushToken = nil
                lastPushMetadata = PushMetadata()
                await persist()
                return
            }
        }
    }

    private func trimmedNonEmpty(_ input: String?) -> String? {
        guard let input else {
            return nil
        }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func emit(_ error: WhisperrError) {
        options.onError?(error)
    }

    private func log(_ message: String) {
        if options.debug {
            print("[whisperr] \(message)")
        }
    }

    /// Exponential backoff with up to 30 % jitter, capped at `maxRetryDelay`.
    private func backoff(attempt: Int) -> TimeInterval {
        let exp = options.retryBaseDelay * pow(2, Double(max(0, attempt - 1)))
        let jittered = exp * (1 + Double.random(in: 0...0.3))
        return min(jittered, options.maxRetryDelay)
    }

    private func isSnakeCase(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return eventTypePattern.firstMatch(in: value, range: range) != nil
    }
}

private enum DeliveryOutcome {
    case ok
    case drop(Int?)
    case auth(Int?)
    case retryExhausted(Int?)

    var retainsBatch: Bool {
        switch self {
        case .auth, .retryExhausted:
            return true
        case .ok, .drop:
            return false
        }
    }
}

private let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    return formatter
}()

func formatTimestamp(_ date: Date) -> String {
    let milliseconds = floor(date.timeIntervalSince1970 * 1_000)
    let truncated = Date(timeIntervalSince1970: milliseconds / 1_000)
    return timestampFormatter.string(from: truncated)
}

extension JSONEncoder {
    static var whisperr: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var whisperr: JSONDecoder {
        JSONDecoder()
    }
}

private extension QueuedOperation {
    /// This identify cut down to its push opt-outs (a rotation, a denied
    /// permission, an earlier opt-out), or nil when it retires no token.
    var pushRetirements: QueuedOperation? {
        guard kind == .identify,
              let user = body["external_user_id"],
              case .array(let channels)? = body["channels"] else {
            return nil
        }
        let retired = channels.filter { channel in
            guard case .object(let fields) = channel else {
                return false
            }
            return fields["channel"] == .string("push") && fields["opted_in"] == .bool(false)
        }
        guard !retired.isEmpty else {
            return nil
        }
        return QueuedOperation(
            id: id,
            kind: .identify,
            body: ["external_user_id": user, "channels": .array(retired)]
        )
    }
}
