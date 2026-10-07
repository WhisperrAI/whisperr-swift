import XCTest
@testable import Whisperr

struct AutomaticSpec: Decodable {
    let reserved: [ReservedEvent]
    let cases: [AutomaticCase]
}

struct ReservedEvent: Decodable {
    let name: String
}

struct AutomaticCase: Decodable {
    let name: String
    let storage: String?
    let config: AutomaticConfig?
    let device: AutomaticDevice
    let steps: [JSONValue]
    let expectedEvents: [AutomaticExpectedEvent]
}

struct AutomaticConfig: Decodable {
    let automaticEvents: Bool?
}

struct AutomaticDevice: Decodable {
    let osVersion: String?
    let locale: String?
    let timezone: String?
    let timezoneOffsetMinutes: Int?
}

struct AutomaticExpectedEvent: Decodable {
    let event_type: String
    let properties: [String: JSONValue]
}

/// Executes whisperr-spec conformance/automatic.json: the reserved automatic
/// events, their common properties, and the lifecycle flows that send them.
final class AutomaticConformanceTests: XCTestCase {
    func testAutomaticFlowsMatchSpec() async throws {
        let spec: AutomaticSpec = try loadSpec(fileName: "automatic.json", envKey: "WHISPERR_AUTOMATIC_SPEC_PATH")
        XCTAssertFalse(spec.cases.isEmpty)
        for testCase in spec.cases {
            try await run(testCase)
        }
    }

    /// Every name this SDK sends on its own is in the reserved catalogue.
    func testSDKEventNamesAreReserved() throws {
        let spec: AutomaticSpec = try loadSpec(fileName: "automatic.json", envKey: "WHISPERR_AUTOMATIC_SPEC_PATH")
        let reserved = Set(spec.reserved.map(\.name))
        let sent = [
            "app_installed", "app_updated", "app_opened", "app_backgrounded",
            "screen_viewed", "push_opened", "push_permission_changed"
        ]
        for name in sent {
            XCTAssertTrue(reserved.contains(name), name)
        }
    }

    private func run(_ testCase: AutomaticCase) async throws {
        let transport = MockTransport()
        let persistence = InMemoryWhisperrPersistence()
        if testCase.storage == "legacy_sdk_state" {
            // State an older SDK wrote: a stored user, no stored app version.
            let legacy = PersistedState(userID: "legacy_user")
            await persistence.save(try JSONEncoder.whisperr.encode(legacy))
        }
        let clock = TestClock()
        let device = testCase.device
        let traits: [String: JSONValue] = {
            var out: [String: JSONValue] = [:]
            if let locale = device.locale {
                out["locale"] = .string(locale)
            }
            if let timezone = device.timezone {
                out["timezone"] = .string(timezone)
            }
            if let offset = device.timezoneOffsetMinutes {
                out["timezone_offset_minutes"] = .number(Double(offset))
            }
            return out
        }()
        var client: WhisperrClient?

        for step in testCase.steps {
            let object = step.objectValue ?? [:]
            if let launch = object["launch"]?.objectValue {
                let environment = AppEnvironment(
                    appVersion: launch["appVersion"]?.stringValue,
                    appBuild: launch["appBuild"]?.stringValue,
                    osName: "ios",
                    osVersion: device.osVersion,
                    platform: "ios"
                )
                let launched = makeLifecycleClient(
                    transport: transport,
                    persistence: persistence,
                    automaticEvents: testCase.config?.automaticEvents ?? true,
                    environment: environment,
                    clock: clock,
                    deviceTraits: { traits }
                )
                try await launched.identify("user_1")
                await launched.handleAppLaunch(inForeground: true)
                client = launched
            } else if let background = object["background"]?.objectValue {
                clock.advance((background["afterMs"]?.doubleValue ?? 0) / 1_000)
                await client?.handleDidEnterBackground()
            } else if let foreground = object["foreground"]?.objectValue {
                clock.advance((foreground["afterMs"]?.doubleValue ?? 0) / 1_000)
                await client?.handleWillEnterForeground()
            } else if object["terminate"] == true {
                await client?.close()
                client = nil
            } else if let screen = object["screen"]?.stringValue {
                try await client?.screen(screen)
            } else if let data = object["pushOpened"]?.objectValue {
                let userInfo = data.reduce(into: [AnyHashable: Any]()) { out, pair in
                    out[pair.key] = pair.value.stringValue ?? ""
                }
                _ = await client?.handleNotification(userInfo: userInfo)
            } else if let raw = object["pushPermission"]?.stringValue {
                let status = try XCTUnwrap(WhisperrPushPermissionStatus(rawValue: raw), testCase.name)
                await client?.pushPermissionChanged(status)
            } else if object["reset"] == true {
                await client?.reset()
            } else if object["optOut"] == true {
                await client?.optOut()
            } else if object["optIn"] == true {
                await client?.optIn()
            } else {
                XCTFail("\(testCase.name): unknown step \(step)")
            }
            await client?.flush()
        }
        await client?.close()

        let sent = await transport.sentEvents()
        let actual = sent.map { event -> [String: JSONValue] in
            ["event_type": event["event_type"] ?? .null, "properties": event["properties"] ?? .null]
        }
        let expected = testCase.expectedEvents.map { event -> [String: JSONValue] in
            ["event_type": .string(event.event_type), "properties": .object(substitute(event.properties))]
        }
        XCTAssertEqual(actual, expected, testCase.name)
        for event in sent {
            XCTAssertNotNil(event["context"]?.objectValue?["$message_id"], "\(testCase.name): context.$message_id")
        }
    }

    private func substitute(_ properties: [String: JSONValue]) -> [String: JSONValue] {
        properties.mapValues { value in
            switch value {
            case "$platform":
                return "ios"
            case "$sdk_name":
                return "whisperr-swift"
            case "$sdk_version":
                return .string(kWhisperrSdkVersion)
            default:
                return value
            }
        }
    }
}

private extension JSONValue {
    var doubleValue: Double? {
        if case .number(let value) = self {
            return value
        }
        return nil
    }
}
