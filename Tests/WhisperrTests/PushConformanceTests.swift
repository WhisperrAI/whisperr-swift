import XCTest
@testable import Whisperr

/// Executes the push-token capture flows pinned in whisperr-spec
/// conformance/push.json: partial re-identify, rotation opt-out, dedup
/// (including across restarts), buffer-until-identify, opt-out, the token
/// change a denied or re-granted permission causes, and (kindCases) the
/// optional kind / platform / push_env token fields.
final class PushConformanceTests: XCTestCase {
    func testPushTokenFlowsMatchSpec() async throws {
        let spec = try loadPushSpec()
        XCTAssertFalse(spec.cases.isEmpty)
        try await run(spec.cases)
    }

    func testPushTokenKindFlowsMatchSpec() async throws {
        let spec = try loadPushSpec()
        let kindCases = try XCTUnwrap(spec.kindCases, "push.json has no kindCases")
        XCTAssertFalse(kindCases.isEmpty)
        try await run(kindCases)
    }

    private func loadPushSpec() throws -> PushSpec {
        try loadSpec(fileName: "push.json", envKey: "WHISPERR_PUSH_SPEC_PATH")
    }

    private func run(_ cases: [PushCase]) async throws {
        for testCase in cases {
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
                    var pushToken: String?
                    if case .string(let token)? = identify["pushToken"] {
                        pushToken = token
                    }
                    try await client.identify(userID, traits: traits, pushToken: pushToken)
                } else if let token = step.setPushToken {
                    try await client.setPushToken(
                        token.token,
                        kind: try token.kind.map { try XCTUnwrap(WhisperrPushKind(rawValue: $0), testCase.name) },
                        platform: try token.platform.map { try XCTUnwrap(WhisperrPushPlatform(rawValue: $0), testCase.name) },
                        environment: try token.pushEnv.map { try XCTUnwrap(WhisperrPushEnvironment(rawValue: $0), testCase.name) }
                    )
                } else if step.optOut == true {
                    await client.optOut()
                } else if step.optIn == true {
                    await client.optIn()
                } else if let raw = step.pushPermission {
                    let status = try XCTUnwrap(WhisperrPushPermissionStatus(rawValue: raw), testCase.name)
                    await client.pushPermissionChanged(status)
                } else if step.reset == true {
                    // Logout: clears the current user and the last-sent pair.
                    await client.reset()
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
