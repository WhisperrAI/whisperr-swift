import XCTest
@testable import Whisperr

final class WireConformanceTests: XCTestCase {
    func testWireConformance() async throws {
        let spec: WireSpec = try loadSpec(fileName: "wire.json", envKey: "WHISPERR_SPEC_PATH")
        XCTAssertFalse(spec.cases.isEmpty)

        for testCase in spec.cases {
            let transport = MockTransport()
            let clock = testCase.scenario["clockIso"]?.stringValue.map(parseFixtureDate)
                ?? Date(timeIntervalSince1970: 1_780_229_600)
            let client = makeClient(transport: transport, clock: { clock })

            try await apply(testCase, to: client)
            await client.flush()

            let requests = await transport.requests
            guard let request = requests.first(where: { $0.path == testCase.endpoint }) else {
                XCTFail("\(testCase.name): expected POST \(testCase.endpoint)")
                continue
            }

            if testCase.op == "track" {
                let event = try XCTUnwrap(request.body.objectValue?["events"]?.arrayValue?.first?.objectValue)
                for (key, expected) in testCase.expectedEvent ?? [:] {
                    XCTAssertEqual(event[key], expected, "\(testCase.name).\(key)")
                }
                for key in testCase.contextMustContain ?? [] {
                    XCTAssertNotNil(event["context"]?.objectValue?[key], "\(testCase.name).context.\(key)")
                }
                if testCase.occurredAtRfc3339Z == true {
                    let value = try XCTUnwrap(event["occurred_at"]?.stringValue)
                    XCTAssertTrue(Self.rfc3339MillisecondsRegex().firstMatch(
                        in: value,
                        range: NSRange(value.startIndex..<value.endIndex, in: value)
                    ) != nil)
                }
                if let expectedOccurredAt = testCase.expectedOccurredAt {
                    XCTAssertEqual(event["occurred_at"], .string(expectedOccurredAt), "\(testCase.name).occurred_at")
                }
            } else {
                let body = try XCTUnwrap(request.body.objectValue)
                for (key, expected) in testCase.expectedBody ?? [:] {
                    XCTAssertEqual(body[key], expected, "\(testCase.name).\(key)")
                }
            }
        }
    }

    private func apply(_ testCase: WireCase, to client: WhisperrClient) async throws {
        let scenario = testCase.scenario
        let externalUserID = try XCTUnwrap(scenario["externalUserId"]?.stringValue)

        if testCase.op == "track" {
            try await client.track(
                try XCTUnwrap(scenario["eventType"]?.stringValue),
                properties: scenario["properties"]?.objectValue ?? [:],
                userID: externalUserID
            )
            return
        }

        let channels = (scenario["channels"]?.arrayValue ?? []).compactMap { value -> WhisperrChannel? in
            guard let object = value.objectValue,
                  let typeValue = object["type"]?.stringValue,
                  let type = WhisperrChannelType(rawValue: typeValue),
                  let address = object["address"]?.stringValue else {
                return nil
            }
            return WhisperrChannel(
                type: type,
                address: address,
                optedIn: object["optedIn"]?.boolValue,
                verified: object["verified"]?.boolValue
            )
        }

        try await client.identify(
            externalUserID,
            traits: scenario["traits"]?.objectValue ?? [:],
            email: scenario["email"]?.stringValue,
            phone: scenario["phone"]?.stringValue,
            pushToken: scenario["pushToken"]?.stringValue,
            preferredChannel: scenario["preferredChannel"]?.stringValue.flatMap(WhisperrChannelType.init(rawValue:)),
            channels: channels
        )
    }

    private static func rfc3339MillisecondsRegex() -> NSRegularExpression {
        try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#)
    }
}
