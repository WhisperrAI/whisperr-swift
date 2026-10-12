import XCTest
@testable import Whisperr

// MARK: - Fixture model (whisperr-spec conformance/v2.json)

struct V2Spec: Decodable {
    let sections: [String: V2Section]
}

struct V2Section: Decodable {
    let appliesTo: [String]
    let supersedes: [String]
    let cases: [V2Case]
}

struct V2Case: Decodable {
    let name: String
    let device: [String: JSONValue]?
    let steps: [JSONValue]
    let expectedRequests: [V2ExpectedRequest]
}

struct V2ExpectedRequest: Decodable {
    let endpoint: String
    let body: JSONValue?
    let events: [JSONValue]?
}

/// The contract v2 sections this SDK implements. `serverVersionContext` is for
/// server SDKs only.
let kImplementedV2Sections = ["restoreIdentify", "appLanguage", "anonymousPush", "pushRegistration", "versionContext"]

func loadV2Spec() throws -> V2Spec {
    try loadSpec(fileName: "v2.json", envKey: "WHISPERR_V2_SPEC_PATH")
}

/// Legacy case names in `file` that the implemented v2 sections (and
/// automatic.json `pushEventsV2`) replace. A legacy harness skips them.
func supersededCases(in file: String) -> Set<String> {
    var entries: [String] = []
    if let spec = try? loadV2Spec() {
        for name in kImplementedV2Sections {
            entries += spec.sections[name]?.supersedes ?? []
        }
    }
    if let automatic: AutomaticSpec = try? loadSpec(fileName: "automatic.json", envKey: "WHISPERR_AUTOMATIC_SPEC_PATH") {
        entries += automatic.pushEventsV2?.supersedes ?? []
    }
    let prefix = file + ":"
    return Set(entries.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
}

/// The environment values a v2 case injects. Nil values: detection is off.
final class V2Device: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: JSONValue]?

    init(_ values: [String: JSONValue]?) {
        self.values = values
    }

    func replace(_ newValues: [String: JSONValue]) {
        lock.lock()
        defer { lock.unlock() }
        values = newValues
    }

    private var current: [String: JSONValue]? {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    var traits: [String: JSONValue] {
        guard let values = current else {
            return [:]
        }
        var out: [String: JSONValue] = [:]
        if let locale = values["locale"] {
            out["locale"] = locale
        }
        if let timezone = values["timezone"] {
            out["timezone"] = timezone
        }
        return out
    }

    var environment: AppEnvironment {
        guard let values = current else {
            return .silent
        }
        return AppEnvironment(
            appVersion: values["appVersion"]?.stringValue,
            appBuild: values["appBuild"]?.stringValue,
            osName: "ios",
            osVersion: values["osVersion"]?.stringValue,
            platform: "ios",
            clientAppID: values["clientAppId"]?.stringValue,
            pushPlatform: .ios,
            apnsEnvironment: values["pushEnv"]?.stringValue.flatMap(WhisperrPushEnvironment.init(rawValue:))
        )
    }

    var context: [String: JSONValue] {
        current == nil ? [:] : environment.eventContext
    }

    /// Swift reads no provider project from the device: the app passes it to
    /// setPushToken (firebaseProjectID / oneSignalAppID / providerProject).
    var providerProject: String? {
        current?["providerProject"]?.stringValue
    }
}

/// The context keys v2 governs: a key the expected event names must be equal,
/// one it does not name must be absent.
let kGovernedContextKeys = ["app_version", "app_build", "platform", "sdk_name", "sdk_version", "locale"]

/// Replaces `$platform`, `$sdk_name` and `$sdk_version` with this SDK's values.
func substituteSDKPlaceholders(_ value: JSONValue) -> JSONValue {
    switch value {
    case .string("$platform"):
        return "ios"
    case .string("$sdk_name"):
        return .string(kWhisperrSdkName)
    case .string("$sdk_version"):
        return .string(kWhisperrSdkVersion)
    case .object(let fields):
        return .object(fields.mapValues(substituteSDKPlaceholders))
    case .array(let items):
        return .array(items.map(substituteSDKPlaceholders))
    default:
        return value
    }
}

/// Checks the governed context keys of `context` against `expected`.
func assertGovernedContext(
    _ context: [String: JSONValue],
    _ expected: [String: JSONValue],
    _ label: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    for key in kGovernedContextKeys {
        XCTAssertEqual(context[key], expected[key].map(substituteSDKPlaceholders), "\(label): context.\(key)", file: file, line: line)
    }
}

// MARK: - Runner

/// Executes whisperr-spec conformance/v2.json: the contract v2 sections this
/// SDK implements (restore identify, app_language, anonymous push, push
/// registration, version context).
final class V2ConformanceTests: XCTestCase {
    func testRestoreIdentifySection() async throws {
        try await runSection("restoreIdentify")
    }

    func testAppLanguageSection() async throws {
        try await runSection("appLanguage")
    }

    func testAnonymousPushSection() async throws {
        try await runSection("anonymousPush")
    }

    func testPushRegistrationSection() async throws {
        try await runSection("pushRegistration")
    }

    func testVersionContextSection() async throws {
        try await runSection("versionContext")
    }

    func testEveryMobileSectionIsImplemented() throws {
        let spec = try loadV2Spec()
        let mobile = spec.sections.filter { $0.value.appliesTo.contains("mobile") }.keys
        XCTAssertEqual(Set(mobile), Set(kImplementedV2Sections))
    }

    private func runSection(_ name: String) async throws {
        let spec = try loadV2Spec()
        let section = try XCTUnwrap(spec.sections[name], "v2.json has no \(name) section")
        XCTAssertTrue(section.appliesTo.contains("mobile"), name)
        XCTAssertFalse(section.cases.isEmpty, name)
        for testCase in section.cases {
            try await run(testCase, label: "\(name).\(testCase.name)")
        }
    }

    private func run(_ testCase: V2Case, label: String) async throws {
        let transport = MockTransport()
        let persistence = InMemoryWhisperrPersistence()
        let clock = TestClock()
        let device = V2Device(testCase.device)
        func build() -> WhisperrClient {
            makeClient(
                transport: transport,
                persistence: persistence,
                clock: { clock.now },
                deviceTraits: { device.traits },
                environmentProvider: { device.environment },
                eventContext: { device.context }
            )
        }
        var client = build()

        for step in testCase.steps {
            let object = try XCTUnwrap(step.objectValue, "\(label): step \(step)")
            if let identify = object["identify"]?.objectValue {
                try await self.identify(client, identify, label)
            } else if let track = object["track"]?.objectValue {
                try await client.track(
                    try XCTUnwrap(track["eventType"]?.stringValue, label),
                    properties: track["properties"]?.objectValue ?? [:]
                )
            } else if let token = object["setPushToken"] {
                try await setPushToken(client, token, device: device, label)
            } else if let language = object["setAppLanguage"] {
                await client.setAppLanguage(language.stringValue)
            } else if let restart = object["restart"] {
                await client.close()
                client = build()
                if let thenIdentify = restart.objectValue?["thenIdentify"]?.objectValue {
                    // The same tick as construction: before any flush.
                    try await self.identify(client, thenIdentify, label)
                }
            } else if object["reset"] == true {
                await client.reset()
            } else if object["optOut"] == true {
                await client.optOut()
            } else if object["optIn"] == true {
                await client.optIn()
            } else if let raw = object["pushPermission"]?.stringValue {
                await client.pushPermissionChanged(try XCTUnwrap(WhisperrPushPermissionStatus(rawValue: raw), label))
            } else if let advance = object["advanceClock"]?.objectValue {
                clock.advance(Self.seconds(advance))
            } else if let values = object["setDevice"]?.objectValue {
                device.replace(values)
            } else {
                XCTFail("\(label): unknown step \(step)")
            }
            await client.flush()
        }
        await client.close()

        // Comparison is per endpoint: the identify bodies in order, and the
        // events in order. The order between an identify and an event is
        // open (a permission report queues both in one step).
        let requests = await transport.requests
        let identifyBodies = requests.filter { $0.path == "/v1/identify" }.map(\.body)
        let events = requests.filter { $0.path == "/v1/events/batch" }
            .flatMap { $0.body.objectValue?["events"]?.arrayValue ?? [] }
        let expectedBodies = testCase.expectedRequests.filter { $0.endpoint == "/v1/identify" }.compactMap(\.body)
        let expectedEvents = testCase.expectedRequests.filter { $0.endpoint == "/v1/events/batch" }
            .flatMap { $0.events ?? [] }
        XCTAssertEqual(
            requests.filter { $0.path != "/v1/identify" && $0.path != "/v1/events/batch" }.count, 0,
            "\(label): unexpected endpoint"
        )

        var bindings = PlaceholderBindings()
        XCTAssertEqual(identifyBodies.count, expectedBodies.count, "\(label): identify count")
        for (index, (actual, expected)) in zip(identifyBodies, expectedBodies).enumerated() {
            let expectedBody = substituteSDKPlaceholders(expected)
            var body = actual.objectValue ?? [:]
            // An SDK may keep a handle for its anonymous lane: ignore it on an
            // identified body unless the fixture names it.
            if body["external_user_id"] != nil, expectedBody.objectValue?["anonymous_id"] == nil {
                body.removeValue(forKey: "anonymous_id")
            }
            bindings.assertMatches(.object(body), expectedBody, "\(label) identify[\(index)]")
        }

        XCTAssertEqual(events.count, expectedEvents.count, "\(label): event count")
        for (index, (event, expectedEvent)) in zip(events, expectedEvents).enumerated() {
            let at = "\(label) event[\(index)]"
            var actualEvent = event.objectValue ?? [:]
            var wanted = substituteSDKPlaceholders(expectedEvent).objectValue ?? [:]
            let context = actualEvent["context"]?.objectValue ?? [:]
            XCTAssertNotNil(context["$message_id"], "\(at): context.$message_id")
            if wanted["event_type"] == "push_permission_changed" {
                // The automatic event: compared as automatic.json does, without
                // identity fields, occurred_at and context.
                XCTAssertEqual(actualEvent["event_type"], wanted["event_type"], at)
                XCTAssertEqual(actualEvent["properties"], wanted["properties"], at)
                continue
            }
            if let expectedContext = wanted["context"]?.objectValue {
                assertGovernedContext(context, expectedContext, at)
            }
            actualEvent.removeValue(forKey: "context")
            actualEvent.removeValue(forKey: "occurred_at")
            wanted.removeValue(forKey: "context")
            bindings.assertMatches(.object(actualEvent), .object(wanted), at)
        }
    }

    private func identify(_ client: WhisperrClient, _ step: [String: JSONValue], _ label: String) async throws {
        try await client.identify(
            try XCTUnwrap(step["externalUserId"]?.stringValue, label),
            traits: step["traits"]?.objectValue ?? [:],
            pushToken: step["pushToken"]?.stringValue
        )
    }

    private func setPushToken(_ client: WhisperrClient, _ step: JSONValue, device: V2Device, _ label: String) async throws {
        if let token = step.stringValue {
            try await client.setPushToken(token, providerProject: device.providerProject)
            return
        }
        let object = try XCTUnwrap(step.objectValue, label)
        XCTAssertNil(object["clientAppId"], "\(label): Swift reads client_app_id from the bundle only")
        try await client.setPushToken(
            try XCTUnwrap(object["token"]?.stringValue, label),
            kind: try object["kind"]?.stringValue.map { try XCTUnwrap(WhisperrPushKind(rawValue: $0), label) },
            platform: try object["platform"]?.stringValue.map { try XCTUnwrap(WhisperrPushPlatform(rawValue: $0), label) },
            environment: try object["pushEnv"]?.stringValue.map { try XCTUnwrap(WhisperrPushEnvironment(rawValue: $0), label) },
            providerProject: object["providerProject"]?.stringValue ?? device.providerProject
        )
    }

    private static func seconds(_ advance: [String: JSONValue]) -> TimeInterval {
        func number(_ key: String) -> Double {
            if case .number(let value)? = advance[key] {
                return value
            }
            return 0
        }
        return number("hours") * 3_600 + number("minutes") * 60 + number("seconds") + number("ms") / 1_000
    }
}
