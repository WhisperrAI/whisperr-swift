import XCTest
@testable import Whisperr

final class DroppedRequestWarningTests: XCTestCase {
    private func warning(_ status: Int) -> String {
        "[whisperr] dropped a request: the server rejected it with \(status). "
            + "Later rejections with this status are reported through onError, or here with debug on."
    }

    func testWarnsOncePerStatusCodeAndReportsEveryDropThroughOnError() async throws {
        let transport = MockTransport(result: .drop(400))
        let errors = ErrorRecorder()
        let lines = LineRecorder()
        let client = makeClient(
            transport: transport,
            onError: { errors.append($0) },
            logger: { lines.append($0) }
        )

        try await client.track("first_event", userID: "user_1")
        await client.flush()
        try await client.track("second_event", userID: "user_1")
        await client.flush()
        await transport.setResult(.drop(422))
        try await client.track("third_event", userID: "user_1")
        await client.flush()

        XCTAssertEqual(lines.values, [warning(400), warning(422)])
        XCTAssertEqual(
            errors.values.filter { $0.type == .dropped }.map(\.status),
            [400, 400, 422]
        )
        let pending = await client.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func testWithDebugOnEveryDropIsLogged() async throws {
        let transport = MockTransport(result: .drop(400))
        let lines = LineRecorder()
        let client = makeClient(transport: transport, debug: true, logger: { lines.append($0) })

        try await client.track("first_event", userID: "user_1")
        await client.flush()
        try await client.track("second_event", userID: "user_1")
        await client.flush()

        let dropLines = lines.values.filter { $0.contains("rejected") }
        XCTAssertEqual(dropLines, [
            "[whisperr] dropped a request: the server rejected it with 400.",
            "[whisperr] dropped a request: the server rejected it with 400.",
        ])
    }

    func testRetryableStatusesKeepTheOpWithoutAWarning() async throws {
        for result in [WhisperrSendResult.retry, .retryAfter(1)] {
            let transport = MockTransport(result: result)
            let errors = ErrorRecorder()
            let lines = LineRecorder()
            let client = makeClient(
                transport: transport,
                onError: { errors.append($0) },
                logger: { lines.append($0) }
            )

            try await client.track("feature_used", userID: "user_1")
            await client.flush()

            XCTAssertEqual(lines.values.filter { $0.contains("rejected") }, [])
            XCTAssertFalse(errors.values.contains { $0.type == .dropped })
            var pending = await client.pendingCount
            XCTAssertEqual(pending, 1)

            await transport.setResult(.ok)
            await client.flush()
            pending = await client.pendingCount
            XCTAssertEqual(pending, 0)
        }
    }
}
