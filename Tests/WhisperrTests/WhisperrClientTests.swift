import XCTest
@testable import Whisperr

final class WhisperrClientTests: XCTestCase {
    func testIdentifyShortcutNormalizesChannels() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport)

        try await client.identify("user_123", traits: ["plan": "pro"], email: "ada@example.com")
        await client.flush()

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].path, "/v1/identify")
        XCTAssertEqual(requests[0].body.objectValue?["external_user_id"], "user_123")
        XCTAssertEqual(
            requests[0].body.objectValue?["channels"],
            [["channel": "email", "address": "ada@example.com", "opted_in": true]]
        )
    }

    func testTrackAddsStableMessageIDAndDropsInvalidEventType() async throws {
        let errors = ErrorRecorder()
        let transport = MockTransport()
        let client = makeClient(transport: transport, onError: { errors.append($0) })

        try await client.track("Bad Event", userID: "user_123")
        try await client.track("checkout_completed", properties: ["amount": 42], userID: "user_123")
        await client.flush()

        XCTAssertTrue(errors.values.contains { $0.type == .dropped })
        let body = await transport.batchBodies().first?.objectValue
        let event = body?["events"]?.arrayValue?.first?.objectValue
        XCTAssertEqual(event?["event_type"], "checkout_completed")
        XCTAssertEqual(event?["context"]?.objectValue?["$message_id"], "mid-1")
    }

    func testResetClearsCurrentUserAfterFlush() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport)

        try await client.identify("user_123")
        try await client.track("feature_used")
        await client.reset()

        let pending = await client.pendingCount
        XCTAssertEqual(pending, 0)
        do {
            try await client.track("feature_used")
            XCTFail("expected missingUserID after reset")
        } catch let error as WhisperrClientError {
            XCTAssertEqual(error, .missingUserID)
        }
    }

    func testAuthRetainsQueueForRecovery() async throws {
        let errors = ErrorRecorder()
        let transport = MockTransport(result: .auth(401))
        let client = makeClient(transport: transport, maxRetries: 0, onError: { errors.append($0) })

        try await client.track("feature_used", userID: "user_123")
        await client.flush()
        let retainedCount = await client.pendingCount
        XCTAssertEqual(retainedCount, 1)
        XCTAssertTrue(errors.values.contains { $0.type == .auth })

        await transport.setResult(.ok)
        await client.flush()
        let finalCount = await client.pendingCount
        let batchCount = await transport.batchBodies().count
        XCTAssertEqual(finalCount, 0)
        XCTAssertEqual(batchCount, 2)
    }

    func testSetPushTokenIgnoresEmptyTokens() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport)

        try await client.identify("user_1")
        await client.flush()
        // No throw, no request — safe to call every launch before getToken() is ready.
        try await client.setPushToken("")
        try await client.setPushToken("   ")
        await client.flush()

        let identifies = await transport.requests
            .filter { $0.path == "/v1/identify" }
        XCTAssertEqual(identifies.count, 1) // only the initial identify
    }

    func testDroppedPushRegistrationClearsDedupeMark() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport, maxRetries: 0)

        try await client.identify("user_1")
        await client.flush()

        await transport.setResult(.drop(400))
        try await client.setPushToken("tok_a") // registration rejected (4xx) → mark cleared
        await client.flush()

        await transport.setResult(.ok)
        try await client.setPushToken("tok_a") // same token — must re-send, not dedupe
        await client.flush()

        let pushRegistrations = await transport.requests
            .filter { $0.path == "/v1/identify" && $0.body.objectValue?["channels"] != nil }
            .map(\.body)
        // Two registrations: the dropped one and the re-sent one. A wedge would
        // have deduped the second call to zero.
        XCTAssertEqual(pushRegistrations.count, 2)
        XCTAssertEqual(pushRegistrations.last, .object([
            "external_user_id": .string("user_1"),
            "channels": .array([
                .object([
                    "channel": .string("push"),
                    "address": .string("tok_a"),
                    "opted_in": .bool(true)
                ])
            ])
        ]))
    }

    /// The MAJOR restore race: a setPushToken from the APNs callback fires while
    /// the launch's restore is still in flight, for an already-identified
    /// returning user. It must await restore (seeing the restored user + token)
    /// and send the rotation — not sail past a `started` flag with a nil user
    /// and silently buffer the token.
    func testSetPushTokenRacingRestoreRotatesForReturningUser() async throws {
        let seeded = try JSONEncoder.whisperr.encode(PersistedState(
            queue: [],
            userID: "user_1",
            lastPushUserID: "user_1",
            lastPushToken: "tok_a"
        ))
        let gated = GatedPersistence(seeded)
        let transport = MockTransport()
        let client = makeClient(transport: transport, persistence: gated)

        // Launch: start() begins restore and blocks inside load().
        let startTask = Task { await client.start() }
        await gated.awaitLoadEntered()

        // APNs delivers a rotated token mid-restore.
        let setTask = Task { try await client.setPushToken("tok_b") }
        await Task.yield()
        await Task.yield()
        await gated.releaseLoad()

        try await setTask.value
        await startTask.value
        await client.flush()

        let identifies = await transport.requests
            .filter { $0.path == "/v1/identify" }
            .map(\.body)
        XCTAssertEqual(identifies, [
            .object([
                "external_user_id": .string("user_1"),
                "channels": .array([
                    .object([
                        "channel": .string("push"),
                        "address": .string("tok_a"),
                        "opted_in": .bool(false)
                    ]),
                    .object([
                        "channel": .string("push"),
                        "address": .string("tok_b"),
                        "opted_in": .bool(true)
                    ])
                ])
            ])
        ])
    }
}

/// Persistence whose `load()` blocks until `releaseLoad()` is called, so a test
/// can deterministically interleave calls with an in-flight restore.
actor GatedPersistence: WhisperrPersistence {
    private var stored: Data?
    private var release: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private var didEnterLoad = false

    init(_ data: Data?) {
        stored = data
    }

    func load() async -> Data? {
        didEnterLoad = true
        entered?.resume()
        entered = nil
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            release = c
        }
        return stored
    }

    func save(_ data: Data?) async {
        stored = data
    }

    /// Unblocks the in-flight `load()`.
    func releaseLoad() {
        release?.resume()
        release = nil
    }

    /// Suspends until `load()` has been entered (restore is in flight).
    func awaitLoadEntered() async {
        if didEnterLoad { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            entered = c
        }
    }
}
