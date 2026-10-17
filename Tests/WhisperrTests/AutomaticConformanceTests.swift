import XCTest
@testable import Whisperr

struct AutomaticSpec: Decodable {
    let reserved: [ReservedEvent]
    let cases: [AutomaticCase]
    /// Contract v2 push events: push_received, push_opened action_id and
    /// cold_start.
    let pushEventsV2: AutomaticV2Section?
    /// Signals v3: session id, launch source, visit counters, app_error,
    /// app_crashed. Absent from specs before signals v3.
    let signalsV3: SignalsV3Spec?
}

struct SignalsV3Spec: Decodable {
    let legacyStrip: LegacyStrip?
    let fingerprintVectors: [FingerprintVector]?
    let sections: [String: SignalsV3Section]
}

struct LegacyStrip: Decodable {
    let events: [String]
    let properties: [String]

    /// What a v3 SDK strips before comparing legacy cases, for specs that
    /// predate signals v3 (CI reads whisperr-spec main).
    static let fallback = LegacyStrip(
        events: ["app_error", "app_crashed"],
        properties: [
            "launch_source", "whisperr_message_id", "link_route", "link_host",
            "utm_source", "utm_medium", "utm_campaign", "first_after_update",
            "session_id", "screen_count", "unique_screen_count", "event_count", "error_count"
        ]
    )
}

struct FingerprintVector: Decodable {
    let errorName: String
    let frames: [String]
    let fingerprint: String
}

struct SignalsV3Section: Decodable {
    let appliesTo: [String]
    let cases: [AutomaticCase]
}

struct AutomaticV2Section: Decodable {
    let supersedes: [String]
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
    let captureErrors: Bool?
    let debugBuild: Bool?
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
    /// Contract v2: the governed context keys this event must carry.
    let context: [String: JSONValue]?
}

/// Executes whisperr-spec conformance/automatic.json: the reserved automatic
/// events, their common properties, and the lifecycle flows that send them.
final class AutomaticConformanceTests: XCTestCase {
    func testAutomaticFlowsMatchSpec() async throws {
        let spec: AutomaticSpec = try loadSpec(fileName: "automatic.json", envKey: "WHISPERR_AUTOMATIC_SPEC_PATH")
        XCTAssertFalse(spec.cases.isEmpty)
        let superseded = supersededCases(in: "automatic.json")
        for testCase in spec.cases where !superseded.contains(testCase.name) {
            try await run(testCase, strip: spec.signalsV3?.legacyStrip ?? .fallback)
        }
    }

    func testPushEventsV2MatchSpec() async throws {
        let spec: AutomaticSpec = try loadSpec(fileName: "automatic.json", envKey: "WHISPERR_AUTOMATIC_SPEC_PATH")
        let section = try XCTUnwrap(spec.pushEventsV2, "automatic.json has no pushEventsV2")
        XCTAssertFalse(section.cases.isEmpty)
        for testCase in section.cases {
            // Swift has no Notification Service Extension receipt path.
            let receiptSources = testCase.steps.compactMap { $0.objectValue?["receivePush"]?.objectValue?["source"]?.stringValue }
            guard receiptSources.allSatisfy({ $0 == "foreground" }) else {
                continue
            }
            try await run(testCase, strip: spec.signalsV3?.legacyStrip ?? .fallback)
        }
    }

    func testSignalsV3MatchSpec() async throws {
        let spec: AutomaticSpec = try loadSpec(fileName: "automatic.json", envKey: "WHISPERR_AUTOMATIC_SPEC_PATH")
        guard let signals = spec.signalsV3 else {
            throw XCTSkip("this whisperr-spec has no signalsV3 section")
        }
        var ran = 0
        for (_, section) in signals.sections where section.appliesTo.contains("mobile") {
            for testCase in section.cases {
                // No quick-action API in this SDK.
                let usesShortcut = testCase.steps.contains { $0.objectValue?["launch"]?.objectValue?["via"]?.objectValue?["shortcut"] != nil }
                if usesShortcut {
                    continue
                }
                try await run(testCase, strip: nil)
                ran += 1
            }
        }
        XCTAssertGreaterThan(ran, 0)
    }

    func testFingerprintVectorsMatchSpec() throws {
        let spec: AutomaticSpec = try loadSpec(fileName: "automatic.json", envKey: "WHISPERR_AUTOMATIC_SPEC_PATH")
        guard let vectors = spec.signalsV3?.fingerprintVectors else {
            throw XCTSkip("this whisperr-spec has no signalsV3 fingerprint vectors")
        }
        for vector in vectors {
            XCTAssertEqual(
                WhisperrSignals.fingerprint(name: vector.errorName, frames: vector.frames),
                vector.fingerprint,
                vector.errorName
            )
        }
    }

    /// Every name this SDK sends on its own is in the reserved catalogue.
    func testSDKEventNamesAreReserved() throws {
        let spec: AutomaticSpec = try loadSpec(fileName: "automatic.json", envKey: "WHISPERR_AUTOMATIC_SPEC_PATH")
        let reserved = Set(spec.reserved.map(\.name))
        let sent = [
            "app_installed", "app_updated", "app_opened", "app_backgrounded",
            "screen_viewed", "push_opened", "push_received", "push_permission_changed"
        ]
        var v3: [String] = []
        if spec.signalsV3 != nil {
            v3 = ["app_error", "app_crashed"]
        }
        for name in v3 {
            XCTAssertTrue(reserved.contains(name), name)
        }
        for name in sent {
            XCTAssertTrue(reserved.contains(name), name)
        }
    }

    /// Runs one case. `strip` set: a legacy case, compared without the
    /// signals v3 events and properties.
    private func run(_ testCase: AutomaticCase, strip: LegacyStrip?) async throws {
        let transport = MockTransport()
        let runMarkers = WhisperrRunMarkerStore.inMemory()
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
                    deviceTraits: { traits },
                    captureErrors: testCase.config?.captureErrors ?? true,
                    runMarkers: runMarkers,
                    isDebugBuild: testCase.config?.debugBuild ?? false
                )
                try await launched.identify("user_1")
                await launched.handleAppLaunch(inForeground: true)
                let via = launch["via"]?.objectValue ?? [:]
                if let push = via["push"] {
                    let payload = try XCTUnwrap(WhisperrPushPayload(
                        userInfo: Self.userInfo(push),
                        actionID: nil,
                        coldStart: true
                    ), testCase.name)
                    _ = await launched.handleNotification(payload)
                }
                if let link = via["link"]?.stringValue {
                    await launched.recordLaunchURL(try XCTUnwrap(URL(string: link), testCase.name))
                }
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
            } else if let name = object["track"]?.stringValue {
                try await client?.track(name)
            } else if let error = object["trackError"]?.objectValue {
                await client?.recordError(
                    name: error["name"]?.stringValue ?? "",
                    frames: [],
                    kind: error["kind"]?.stringValue ?? "handled",
                    fatal: false,
                    screen: error["screen"]?.stringValue
                )
            } else if let error = object["uncaughtError"]?.objectValue {
                await client?.handleUncaughtError(
                    name: error["name"]?.stringValue ?? "",
                    frames: [],
                    fatal: error["fatal"]?.boolValue ?? false
                )
            } else if let data = object["pushOpened"]?.objectValue {
                let userInfo = data.reduce(into: [AnyHashable: Any]()) { out, pair in
                    out[pair.key] = pair.value.stringValue ?? ""
                }
                _ = await client?.handleNotification(userInfo: userInfo)
            } else if let receive = object["receivePush"]?.objectValue {
                _ = try await client?.trackPushReceived(userInfo: Self.userInfo(receive["data"]))
            } else if let open = object["openPush"]?.objectValue {
                let payload = try XCTUnwrap(WhisperrPushPayload(
                    userInfo: Self.userInfo(open["data"]),
                    actionID: open["actionId"]?.stringValue,
                    coldStart: open["launchedApp"]?.boolValue
                ), testCase.name)
                _ = await client?.handleNotification(payload)
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

        var sent = await transport.sentEvents()
        if let strip {
            sent = sent.compactMap { event in
                guard let type = event["event_type"]?.stringValue, !strip.events.contains(type) else {
                    return nil
                }
                var out = event
                var properties = event["properties"]?.objectValue ?? [:]
                for key in strip.properties {
                    properties.removeValue(forKey: key)
                }
                out["properties"] = .object(properties)
                return out
            }
        }
        if strip == nil {
            // Every event carries the session id; app_backgrounded and
            // app_error repeat it as a property.
            var bindings = SessionBindings()
            XCTAssertEqual(sent.count, testCase.expectedEvents.count, "\(testCase.name): event count")
            for (index, (event, wanted)) in zip(sent, testCase.expectedEvents).enumerated() {
                let label = "\(testCase.name) event[\(index)] \(wanted.event_type)"
                XCTAssertEqual(event["event_type"], .string(wanted.event_type), label)
                let actualProperties = event["properties"]?.objectValue ?? [:]
                var expectedProperties: [String: JSONValue] = [:]
                for (key, value) in substitute(wanted.properties) {
                    expectedProperties[key] = bindings.resolve(value, actualProperties[key], "\(label).\(key)")
                }
                XCTAssertEqual(JSONValue.object(actualProperties), JSONValue.object(expectedProperties), label)
                if let session = wanted.context?["session_id"] {
                    let actualSession = event["context"]?.objectValue?["session_id"]
                    let expectedSession = bindings.resolve(session, actualSession, "\(label).context.session_id")
                    XCTAssertEqual(actualSession, expectedSession, label)
                }
            }
            return
        }
        let actual = sent.map { event -> [String: JSONValue] in
            ["event_type": event["event_type"] ?? .null, "properties": event["properties"] ?? .null]
        }
        // The strip applies to both sides: legacy fixtures also name
        // whisperr_message_id on push_opened / push_received.
        let stripped = Set(strip?.properties ?? [])
        let expected = testCase.expectedEvents.map { event -> [String: JSONValue] in
            ["event_type": .string(event.event_type), "properties": .object(substitute(event.properties).filter { !stripped.contains($0.key) })]
        }
        XCTAssertEqual(actual, expected, testCase.name)
        for event in sent {
            XCTAssertNotNil(event["context"]?.objectValue?["$message_id"], "\(testCase.name): context.$message_id")
        }
        for (event, expectedEvent) in zip(sent, testCase.expectedEvents) {
            if let expectedContext = expectedEvent.context {
                assertGovernedContext(event["context"]?.objectValue ?? [:], expectedContext, testCase.name)
            }
        }
    }

    private static func userInfo(_ data: JSONValue?) -> [AnyHashable: Any] {
        (data?.objectValue ?? [:]).reduce(into: [AnyHashable: Any]()) { out, pair in
            out[pair.key] = pair.value.stringValue ?? ""
        }
    }

    private func substitute(_ properties: [String: JSONValue]) -> [String: JSONValue] {
        properties.mapValues { value in
            switch value {
            case "$platform":
                return "ios" // os_name too: the fixture names both $platform
            case "$sdk_name":
                return "whisperr-swift"
            case "$sdk_version":
                return .string(kWhisperrSdkVersion)
            case "$error_kind":
                return "native"
            case "$fatal_detected_by":
                return "native_exception"
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

/// Binds `$session_<x>` and `$fp_<x>` placeholders to the first value seen.
struct SessionBindings {
    private var values: [String: String] = [:]

    mutating func resolve(_ expected: JSONValue, _ actual: JSONValue?, _ label: String) -> JSONValue {
        guard case .string(let placeholder) = expected,
              placeholder.hasPrefix("$session_") || placeholder.hasPrefix("$fp_") else {
            return expected
        }
        guard case .string(let value)? = actual else {
            XCTFail("\(label): \(placeholder) has no string value")
            return expected
        }
        if let bound = values[placeholder] {
            XCTAssertEqual(value, bound, "\(label): \(placeholder)")
            return .string(bound)
        }
        XCTAssertFalse(values.values.contains(value), "\(label): \(placeholder) reuses another placeholder's value")
        let pattern = placeholder.hasPrefix("$session_")
            ? "^sess_[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
            : "^[0-9a-f]{16}$"
        XCTAssertNotNil(value.range(of: pattern, options: .regularExpression), "\(label): \(placeholder) = \(value)")
        values[placeholder] = value
        return .string(value)
    }
}
