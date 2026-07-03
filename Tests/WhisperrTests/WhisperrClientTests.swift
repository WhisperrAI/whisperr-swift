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
}
