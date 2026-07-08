import XCTest
@testable import Whisperr

/// Executes the push-token capture flows pinned in whisperr-spec
/// conformance/push.json: partial re-identify, rotation opt-out, dedup
/// (including across restarts), and buffer-until-identify.
final class PushConformanceTests: XCTestCase {
    func testPushTokenFlowsMatchSpec() async throws {
        let spec: PushSpec = try loadSpec(
            fileName: "push.json",
            envKey: "WHISPERR_PUSH_SPEC_PATH"
        )
        XCTAssertFalse(spec.cases.isEmpty)

        for testCase in spec.cases {
            let transport = MockTransport()
            let persistence = InMemoryWhisperrPersistence()
            var client = makeClient(transport: transport, persistence: persistence)

            for step in testCase.steps {
                if let identify = step.identify {
                    guard case .string(let userID)? = identify["externalUserId"] else {
                        XCTFail("\(testCase.name): identify step without externalUserId")
                        continue
                    }
                    var traits: [String: JSONValue] = [:]
                    if case .object(let object)? = identify["traits"] {
                        traits = object
                    }
                    try await client.identify(userID, traits: traits)
                } else if let token = step.setPushToken {
                    try await client.setPushToken(token)
                } else if step.restart == true {
                    // App relaunch: tear down the client and build a fresh one
                    // sharing the same persistence; identity and last-sent
                    // token must be restored from it.
                    await client.close()
                    client = makeClient(transport: transport, persistence: persistence)
                } else {
                    XCTFail("\(testCase.name): unknown step")
                }
                // Deliver each step before the next, so request order is pinned.
                await client.flush()
            }

            let identifies = await transport.requests
                .filter { $0.path == "/v1/identify" }
                .map(\.body)
            XCTAssertEqual(
                identifies,
                testCase.expectedBodies,
                testCase.name
            )
            await client.close()
        }
    }
}
