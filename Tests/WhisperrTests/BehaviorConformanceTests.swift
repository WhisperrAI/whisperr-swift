import XCTest
@testable import Whisperr

final class BehaviorConformanceTests: XCTestCase {
    func testBehaviorConformance() async throws {
        let spec: BehaviorSpec = try loadSpec(fileName: "behavior.json", envKey: "WHISPERR_BEHAVIOR_SPEC_PATH")
        XCTAssertFalse(spec.cases.isEmpty)

        for testCase in spec.cases {
            let errors = ErrorRecorder()
            let transport = MockTransport(result: result(from: testCase.firstResponse))
            let maxRetries = testCase.clientOptions?.maxRetries ?? 0
            let client = makeClient(transport: transport, maxRetries: maxRetries, onError: { errors.append($0) })

            try await client.track(
                testCase.scenario.eventType,
                properties: testCase.scenario.properties ?? [:],
                userID: testCase.scenario.externalUserId
            )
            await client.flush()

            XCTAssertTrue(
                errors.values.contains { $0.type.rawValue == testCase.expect.errorType },
                "\(testCase.name): emitted \(testCase.expect.errorType)"
            )
            let afterFirst = await transport.batchBodies()
            XCTAssertEqual(afterFirst.count, 1, "\(testCase.name): first attempt")
            let retained = await client.pendingCount > 0
            XCTAssertEqual(retained, testCase.expect.retainedAfterFirstFlush)

            await transport.setResult(result(from: testCase.recoveryResponse))
            await client.flush()

            let afterRecovery = await transport.batchBodies()
            let retried = afterRecovery.count > afterFirst.count
            XCTAssertEqual(retried, testCase.expect.retriesAfterRecovery, "\(testCase.name): retry after recovery")

            let delivered = retried && eventType(in: afterRecovery.last) == testCase.scenario.eventType
            XCTAssertEqual(delivered, testCase.expect.deliveredAfterRecovery, "\(testCase.name): delivered after recovery")

            if testCase.expect.stableMessageIdOnRetry == true {
                XCTAssertEqual(messageID(in: afterRecovery[0]), messageID(in: afterRecovery[1]))
            }
        }
    }

    private func result(from response: BehaviorResponse) -> WhisperrSendResult {
        switch response.classification {
        case "ok":
            return .ok
        case "auth":
            return .auth(response.status)
        case "drop":
            return .drop(response.status)
        default:
            return .retry
        }
    }

    private func eventType(in body: JSONValue?) -> String? {
        body?.objectValue?["events"]?.arrayValue?.first?.objectValue?["event_type"]?.stringValue
    }

    private func messageID(in body: JSONValue) -> JSONValue? {
        body.objectValue?["events"]?.arrayValue?.first?.objectValue?["context"]?.objectValue?["$message_id"]
    }
}
