import Foundation

public let kWhisperrSdkVersion = "0.2.0"
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

    private var queue: [QueuedOperation] = []
    private var currentUserID: String?
    /// Token captured before identify(); attached to the next identify.
    private var pendingPushToken: String?
    /// Last push token delivered and for which user — dedups refresh storms and
    /// lets a rotation opt the previous token out. Persisted (with the identity)
    /// so both survive an app restart.
    private var lastPushToken: String?
    private var lastPushUserID: String?
    private var started = false
    private var closed = false
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
        }
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
        guard !started else {
            return
        }
        started = true
        await restore()
        if options.flushInterval > 0 {
            let interval = options.flushInterval
            flushLoop = Task { [weak self, sleeper] in
                while !Task.isCancelled {
                    await sleeper(interval)
                    guard let self else { return }
                    await self.flush()
                }
            }
        }
    }

    public func close() async {
        guard !closed else {
            return
        }
        await flush()
        closed = true
        flushLoop?.cancel()
        flushLoop = nil
    }

    /// Identifies the current user and persists traits/contact channels.
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

        var body: [String: JSONValue] = ["external_user_id": .string(id)]
        if !traits.isEmpty {
            body["traits"] = .object(traits)
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
        // last-sent pair for this user, in which case there is nothing new
        // to send.
        if let pending = pendingPushToken,
           !resolvedChannels.contains(where: { $0.type == .push }),
           !(lastPushUserID == id && lastPushToken == pending) {
            resolvedChannels.append(.push(pending, optedIn: true))
        }
        rememberPushChannel(userID: id, channels: resolvedChannels)
        pendingPushToken = nil
        if !resolvedChannels.isEmpty {
            body["channels"] = .array(resolvedChannels.map { .object($0.body) })
        }

        await enqueue(QueuedOperation(
            id: idGenerator(),
            kind: .identify,
            body: body
        ))
    }

    /// Captures the device push token (FCM registration token / hex APNs token).
    ///
    /// With a known user this re-identifies the push channel immediately: a
    /// rotated token opts the previously sent one out, and setting the same
    /// token again is a no-op (safe to call on every launch or token refresh).
    /// Called before `identify`, the token is buffered in memory and attached
    /// to the next identify.
    public func setPushToken(_ token: String) async throws {
        try await ensureUsable()
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WhisperrClientError.emptyPushToken
        }
        guard let userID = currentUserID else {
            pendingPushToken = trimmed // attached to the next identify()
            return
        }
        let last = lastPushUserID == userID ? lastPushToken : nil
        if last == trimmed {
            return // refresh storm — token unchanged
        }
        var channels: [WhisperrChannel] = []
        // Rotation: retire the token this client previously registered.
        if let last {
            channels.append(.push(last, optedIn: false))
        }
        channels.append(.push(trimmed, optedIn: true))
        let body: [String: JSONValue] = [
            "external_user_id": .string(userID),
            "channels": .array(channels.map { .object($0.body) })
        ]
        lastPushUserID = userID
        lastPushToken = trimmed
        pendingPushToken = nil
        await enqueue(QueuedOperation(
            id: idGenerator(),
            kind: .identify,
            body: body
        ))
    }

    /// APNs convenience: hex-encodes the `deviceToken` from
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` and
    /// forwards it to `setPushToken(_:)`.
    public func setPushToken(deviceToken: Data) async throws {
        try await setPushToken(deviceToken.map { String(format: "%02x", $0) }.joined())
    }

    /// Tracks a product event for the current user, or for `userID` when supplied.
    public func track(
        _ eventType: String,
        properties: [String: JSONValue] = [:],
        context: [String: JSONValue] = [:],
        userID: String? = nil
    ) async throws {
        try await ensureUsable()
        let resolvedUserID = (userID ?? currentUserID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolvedUserID, !resolvedUserID.isEmpty else {
            throw WhisperrClientError.missingUserID
        }

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

        let body: [String: JSONValue] = [
            "external_user_id": .string(resolvedUserID),
            "event_type": .string(type),
            "occurred_at": .string(formatTimestamp(clock())),
            "properties": .object(properties),
            "context": .object(mergedContext)
        ]

        await enqueue(QueuedOperation(
            id: messageID,
            kind: .track,
            body: body
        ))
    }

    /// Clears the current user (e.g. on logout) after flushing pending work,
    /// including the persisted identity and last-sent push token pair.
    public func reset() async {
        await flush()
        currentUserID = nil
        pendingPushToken = nil
        lastPushToken = nil
        lastPushUserID = nil
        await persist()
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
            let outcome = await deliver(batch)

            switch outcome {
            case .ok:
                await persist()
            case .drop(let status):
                emit(.init(
                    type: .dropped,
                    message: "dropped \(batch.count) operation(s) - rejected by server",
                    status: status
                ))
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
            queue.removeFirst(overflow)
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
            }
        }
    }

    private func restore() async {
        guard let data = await persistence?.load(), !data.isEmpty else {
            return
        }
        if let state = try? JSONDecoder.whisperr.decode(PersistedState.self, from: data) {
            queue = state.queue
            currentUserID = state.userID
            lastPushUserID = state.lastPushUserID
            lastPushToken = state.lastPushToken
            return
        }
        do {
            // Data written by 0.1.x was the bare queue array.
            queue = try JSONDecoder.whisperr.decode([QueuedOperation].self, from: data)
        } catch {
            log("failed to restore persisted state: \(error)")
            queue = []
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
            lastPushToken: lastPushToken
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

    /// Records the opted-in push channel (if any) that an identify just sent.
    private func rememberPushChannel(userID: String, channels: [WhisperrChannel]) {
        for channel in channels where channel.type == .push && channel.optedIn != false {
            lastPushUserID = userID
            lastPushToken = channel.address
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

    private func backoff(attempt: Int) -> TimeInterval {
        let exp = options.retryBaseDelay * pow(2, Double(max(0, attempt - 1)))
        return min(exp, options.maxRetryDelay)
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
