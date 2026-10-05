import XCTest
@testable import Whisperr

/// Executes the anonymous-visitor flows pinned in whisperr-spec
/// conformance/anonymous.json: a track before identify is sent right away
/// under `anonymous_id`, identify carries the same handle (promotion), and
/// reset() rotates it.
final class AnonymousConformanceTests: XCTestCase {
    func testAnonymousFlowsMatchSpec() async throws {
        let spec: AnonymousSpec = try loadSpec(
            fileName: "anonymous.json",
            envKey: "WHISPERR_ANONYMOUS_SPEC_PATH"
        )
        XCTAssertFalse(spec.cases.isEmpty)

        for testCase in spec.cases {
            let transport = MockTransport()
            // Production anonymous id generator: the spec pins 1-128 chars.
            let client = WhisperrClient(
                apiKey: "wrk_test",
                baseURL: URL(string: "https://api.test")!,
                options: WhisperrOptions(flushInterval: 0, maxRetries: 0),
                persistence: InMemoryWhisperrPersistence(),
                transport: transport,
                sleeper: { _ in },
                deviceTraits: { [:] }
            )

            for step in testCase.steps {
                if let track = step.track {
                    guard case .string(let eventType)? = track["eventType"] else {
                        XCTFail("\(testCase.name): track step without eventType")
                        continue
                    }
                    var properties: [String: JSONValue] = [:]
                    if case .object(let object)? = track["properties"] {
                        properties = object
                    }
                    try await client.track(eventType, properties: properties)
                } else if let identify = step.identify {
                    guard case .string(let userID)? = identify["externalUserId"] else {
                        XCTFail("\(testCase.name): identify step without externalUserId")
                        continue
                    }
                    var traits: [String: JSONValue] = [:]
                    if case .object(let object)? = identify["traits"] {
                        traits = object
                    }
                    try await client.identify(userID, traits: traits)
                } else if step.reset == true {
                    await client.reset()
                } else {
                    XCTFail("\(testCase.name): unknown step")
                }
                await client.flush()
            }

            let requests = await transport.requests
            XCTAssertEqual(requests.count, testCase.expectedRequests.count, "\(testCase.name): request count")
            var bindings = PlaceholderBindings()
            for (index, (actual, expected)) in zip(requests, testCase.expectedRequests).enumerated() {
                let label = "\(testCase.name)[\(index)]"
                XCTAssertEqual(actual.path, expected.endpoint, label)
                if let expectedEvents = expected.events {
                    let events = actual.body.objectValue?["events"]?.arrayValue ?? []
                    XCTAssertEqual(events.count, expectedEvents.count, label)
                    for (event, expectedEvent) in zip(events, expectedEvents) {
                        var stripped = event.objectValue ?? [:]
                        XCTAssertNotNil(
                            stripped["context"]?.objectValue?["$message_id"],
                            "\(label): context.$message_id"
                        )
                        stripped.removeValue(forKey: "occurred_at")
                        stripped.removeValue(forKey: "context")
                        bindings.assertMatches(.object(stripped), expectedEvent, label)
                    }
                }
                if let expectedBody = expected.body {
                    bindings.assertMatches(actual.body, expectedBody, label)
                }
            }
            await client.close()
        }
    }
}

/// Binds `$anon_x` placeholders to the values the SDK generated: the same
/// placeholder must always carry the same value, different placeholders
/// different values, and every value must be 1-128 characters.
struct PlaceholderBindings {
    private var values: [String: String] = [:]

    mutating func assertMatches(
        _ actual: JSONValue,
        _ expected: JSONValue,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(substitute(expected, with: actual, label), actual, label, file: file, line: line)
    }

    /// Returns `expected` with each placeholder replaced by its bound value,
    /// binding new placeholders from the matching position in `actual`.
    private mutating func substitute(_ expected: JSONValue, with actual: JSONValue, _ label: String) -> JSONValue {
        switch expected {
        case .string(let value) where value.hasPrefix("$anon_"):
            if let bound = values[value] {
                return .string(bound)
            }
            guard case .string(let generated) = actual else {
                XCTFail("\(label): \(value) bound to a non-string")
                return expected
            }
            XCTAssertTrue((1...128).contains(generated.count), "\(label): anonymous_id length")
            XCTAssertFalse(values.values.contains(generated), "\(label): \(value) reuses another placeholder's value")
            values[value] = generated
            return .string(generated)
        case .object(let fields):
            let actualFields = actual.objectValue ?? [:]
            var out: [String: JSONValue] = [:]
            for (key, value) in fields {
                out[key] = substitute(value, with: actualFields[key] ?? .null, label)
            }
            return .object(out)
        case .array(let items):
            let actualItems = actual.arrayValue ?? []
            return .array(items.enumerated().map { index, item in
                substitute(item, with: index < actualItems.count ? actualItems[index] : .null, label)
            })
        default:
            return expected
        }
    }
}
