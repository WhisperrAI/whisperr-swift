import XCTest
@testable import Whisperr

/// The UIKit observer only exists on iOS-family platforms, and `swift test`
/// runs on macOS. These tests drive the same lifecycle hooks the observer
/// calls (`handleAppLaunch`, `handleWillEnterForeground`,
/// `handleDidEnterBackground`).
final class AutomaticEventsTests: XCTestCase {
    private let commonKeys: Set<String> = [
        "app_version", "app_build", "os_name", "os_version", "platform", "locale", "timezone",
        "sdk_name", "sdk_version"
    ]

    func testFirstLaunchSendsInstalledAndColdOpenWithCommonProperties() async throws {
        let transport = MockTransport()
        let client = makeLifecycleClient(transport: transport)
        await client.start()

        await client.handleAppLaunch(inForeground: true)
        await client.flush()

        let events = await transport.sentEvents()
        XCTAssertEqual(events.map { $0["event_type"] }, ["app_installed", "app_opened"])
        let installed = events[0]["properties"]?.objectValue ?? [:]
        XCTAssertEqual(installed, [
            "app_version": "1.2.0",
            "app_build": "42",
            "os_name": "ios",
            "os_version": "18.1",
            "platform": "ios",
            "sdk_name": "whisperr-swift",
            "sdk_version": .string(kWhisperrSdkVersion),
            "locale": "de-DE",
            "timezone": "Europe/Berlin"
        ])
        let opened = events[1]["properties"]?.objectValue ?? [:]
        XCTAssertEqual(opened["cold_start"], true)
        XCTAssertTrue(commonKeys.isSubset(of: Set(opened.keys)))
        // No identify yet: both go out under the anonymous handle.
        XCTAssertNotNil(events[0]["anonymous_id"])
        XCTAssertNil(events[0]["external_user_id"])
    }

    func testRelaunchWithSameVersionSendsOnlyOpen() async throws {
        let transport = MockTransport()
        let persistence = InMemoryWhisperrPersistence()
        let first = makeLifecycleClient(transport: transport, persistence: persistence)
        await first.handleAppLaunch(inForeground: true)
        await first.close()

        let second = makeLifecycleClient(transport: transport, persistence: persistence)
        await second.start()
        await second.handleAppLaunch(inForeground: true)
        await second.flush()

        let types = await transport.sentEvents().map { $0["event_type"] }
        XCTAssertEqual(types, ["app_installed", "app_opened", "app_opened"])
    }

    func testNewVersionSendsUpdatedWithPreviousVersion() async throws {
        let transport = MockTransport()
        let persistence = InMemoryWhisperrPersistence()
        let first = makeLifecycleClient(transport: transport, persistence: persistence)
        await first.handleAppLaunch(inForeground: false)
        await first.close()

        let second = makeLifecycleClient(
            transport: transport,
            persistence: persistence,
            environment: .fixture(version: "1.3.0", build: "50")
        )
        await second.handleAppLaunch(inForeground: false)
        await second.flush()

        let events = await transport.sentEvents()
        XCTAssertEqual(events.map { $0["event_type"] }, ["app_installed", "app_updated"])
        let updated = events[1]["properties"]?.objectValue ?? [:]
        XCTAssertEqual(updated["app_version"], "1.3.0")
        XCTAssertEqual(updated["app_build"], "50")
        XCTAssertEqual(updated["previous_version"], "1.2.0")
        XCTAssertEqual(updated["previous_build"], "42")
    }

    func testStateFromOlderSDKIsNotANewInstall() async throws {
        // 0.2.x persisted the user but no app version.
        let legacy = PersistedState(queue: [], userID: "user_1")
        let persistence = InMemoryWhisperrPersistence(data: try JSONEncoder.whisperr.encode(legacy))
        let transport = MockTransport()
        let client = makeLifecycleClient(transport: transport, persistence: persistence)
        await client.start()

        await client.handleAppLaunch(inForeground: true)
        await client.flush()

        let events = await transport.sentEvents()
        XCTAssertEqual(events.map { $0["event_type"] }, ["app_opened"])
        XCTAssertEqual(events[0]["external_user_id"], "user_1")
    }

    /// Raw bytes exactly as 0.2.2 wrote them to UserDefaults: each kind of
    /// earlier state on its own must suppress app_installed, and the version is
    /// stored silently so the next version change sends app_updated.
    func testUpgradeFrom022StateNeverSendsInstalled() async throws {
        let legacyPayloads: [String: String] = [
            "identified user": #"{"queue":[],"user_id":"user_1"}"#,
            "push dedupe pair only": #"{"queue":[],"last_push_user_id":"user_1","last_push_token":"tok_a"}"#,
            "queued events only": #"{"queue":[{"id":"m1","kind":"track","body":{"external_user_id":"user_1","event_type":"lesson_completed","occurred_at":"2026-05-31T12:13:20.000Z","properties":{},"context":{"$message_id":"m1"}}}]}"#,
            "0.1.x bare queue array": #"[{"id":"m1","kind":"track","body":{"external_user_id":"user_1","event_type":"lesson_completed","occurred_at":"2026-05-31T12:13:20.000Z","properties":{},"context":{"$message_id":"m1"}}}]"#,
            "unreadable bytes": "not json"
        ]
        for (label, raw) in legacyPayloads {
            let persistence = InMemoryWhisperrPersistence(data: Data(raw.utf8))
            let transport = MockTransport()
            let first = makeLifecycleClient(transport: transport, persistence: persistence)
            await first.handleAppLaunch(inForeground: false)
            await first.close()

            let second = makeLifecycleClient(
                transport: transport,
                persistence: persistence,
                environment: .fixture(version: "1.3.0", build: "50")
            )
            await second.handleAppLaunch(inForeground: false)
            await second.flush()

            let types = await transport.sentEvents().compactMap { $0["event_type"]?.stringValue }
            XCTAssertFalse(types.contains("app_installed"), label)
            XCTAssertEqual(types.filter { $0 == "app_updated" }, ["app_updated"], label)
            await second.close()
        }
    }

    func testWithoutPersistenceNoInstallIsGuessed() async throws {
        let transport = MockTransport()
        let client = makeLifecycleClient(transport: transport, persistence: nil)

        await client.handleAppLaunch(inForeground: true)
        await client.flush()

        let types = await transport.sentEvents().map { $0["event_type"] }
        XCTAssertEqual(types, ["app_opened"])
    }

    func testWarmOpenAndBackgroundCarryColdStartAndForegroundTime() async throws {
        let transport = MockTransport()
        let clock = TestClock()
        let client = makeLifecycleClient(transport: transport, clock: clock)
        try await client.identify("user_1")

        await client.handleAppLaunch(inForeground: true)
        clock.advance(12.5)
        await client.handleDidEnterBackground()
        await client.handleWillEnterForeground()
        clock.advance(3)
        await client.handleDidEnterBackground()

        let events = await transport.sentEvents()
        XCTAssertEqual(
            events.map { $0["event_type"] },
            ["app_installed", "app_opened", "app_backgrounded", "app_opened", "app_backgrounded"]
        )
        XCTAssertEqual(events[1]["properties"]?.objectValue?["cold_start"], true)
        XCTAssertEqual(events[2]["properties"]?.objectValue?["foreground_ms"], 12_500)
        XCTAssertEqual(events[3]["properties"]?.objectValue?["cold_start"], false)
        XCTAssertEqual(events[4]["properties"]?.objectValue?["foreground_ms"], 3_000)
        for event in events {
            XCTAssertEqual(event["external_user_id"], "user_1")
            XCTAssertTrue(commonKeys.isSubset(of: Set((event["properties"]?.objectValue ?? [:]).keys)))
        }
    }

    func testBackgroundFlushesTheQueue() async throws {
        let transport = MockTransport()
        let client = makeLifecycleClient(transport: transport)
        try await client.track("lesson_completed")
        let pendingBefore = await client.pendingCount
        XCTAssertEqual(pendingBefore, 1)

        await client.handleDidEnterBackground()

        let pendingAfter = await client.pendingCount
        XCTAssertEqual(pendingAfter, 0)
        let types = await transport.sentEvents().map { $0["event_type"] }
        XCTAssertEqual(types, ["lesson_completed", "app_backgrounded"])
    }

    func testOffSwitchSendsNoAutomaticEventsButStillFlushesOnBackground() async throws {
        let transport = MockTransport()
        let client = makeLifecycleClient(transport: transport, automaticEvents: false)

        await client.handleAppLaunch(inForeground: true)
        await client.handleWillEnterForeground()
        try await client.track("lesson_completed")
        await client.handleDidEnterBackground()

        let types = await transport.sentEvents().map { $0["event_type"] }
        XCTAssertEqual(types, ["lesson_completed"])
    }

    func testScreenSendsScreenViewed() async throws {
        let transport = MockTransport()
        let client = makeLifecycleClient(transport: transport)
        try await client.identify("user_1")

        try await client.screen("Paywall", properties: ["variant": "b"])
        try await client.screen("   ")
        await client.flush()

        let events = await transport.sentEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["event_type"], "screen_viewed")
        let properties = events[0]["properties"]?.objectValue ?? [:]
        XCTAssertEqual(properties["screen_name"], "Paywall")
        XCTAssertEqual(properties["variant"], "b")
        // Reserved events carry the common properties (automatic.json).
        XCTAssertEqual(properties["platform"], "ios")
        XCTAssertEqual(properties["timezone"], "Europe/Berlin")
    }

    func testDefaultEnvironmentReportsOSAndPlatform() {
        let environment = AppEnvironment.current()
        XCTAssertFalse(environment.osName.isEmpty)
        XCTAssertTrue(environment.osVersion?.contains(".") ?? false)
        #if os(macOS)
        XCTAssertEqual(environment.platform, "macos")
        XCTAssertEqual(environment.osName, "macos")
        #endif
        XCTAssertEqual(environment.osName, environment.osName.lowercased())
    }
}

final class PushOpenedTests: XCTestCase {
    func testPushOpenedReadsMessageIDAndDeepLink() async throws {
        let transport = MockTransport()
        let client = makeLifecycleClient(transport: transport)
        try await client.identify("user_1")

        let sent = try await client.trackPushOpened(userInfo: [
            "aps": ["alert": "Hi"],
            "whisperr_message_id": "msg_1",
            "deep_link": "myapp://streak"
        ])
        await client.flush()

        XCTAssertTrue(sent)
        let events = await transport.sentEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["event_type"], "push_opened")
        XCTAssertEqual(events[0]["external_user_id"], "user_1")
        let properties = events[0]["properties"]?.objectValue ?? [:]
        XCTAssertEqual(properties["whisperr_message_id"], "msg_1")
        XCTAssertEqual(properties["deep_link"], "myapp://streak")
        XCTAssertEqual(properties["sdk_name"], "whisperr-swift")
        XCTAssertEqual(properties["app_version"], "1.2.0")
    }

    func testPushOpenedReadsOneSignalAdditionalData() {
        let payload = WhisperrPushPayload(userInfo: [
            "custom": ["i": "os-id", "a": ["whisperr_message_id": "msg_2"]]
        ])
        XCTAssertEqual(payload, WhisperrPushPayload(messageID: "msg_2"))
    }

    func testNonWhisperrPushIsIgnored() async throws {
        let transport = MockTransport()
        let client = makeLifecycleClient(transport: transport)

        let sent = try await client.trackPushOpened(userInfo: ["aps": ["alert": "Hi"]])
        await client.flush()

        XCTAssertFalse(sent)
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testPushOpenedDedupesPerMessageIDAcrossRestarts() async throws {
        let transport = MockTransport()
        let persistence = InMemoryWhisperrPersistence()
        let first = makeLifecycleClient(transport: transport, persistence: persistence)
        let firstSend = try await first.trackPushOpened(userInfo: ["whisperr_message_id": "msg_1"])
        let repeatSend = try await first.trackPushOpened(userInfo: ["whisperr_message_id": "msg_1"])
        await first.close()

        let second = makeLifecycleClient(transport: transport, persistence: persistence)
        let afterRestart = try await second.trackPushOpened(userInfo: ["whisperr_message_id": "msg_1"])
        let other = try await second.trackPushOpened(userInfo: ["whisperr_message_id": "msg_2"])
        await second.flush()

        XCTAssertEqual([firstSend, repeatSend, afterRestart, other], [true, false, false, true])
        let ids = await transport.sentEvents().map { $0["properties"]?.objectValue?["whisperr_message_id"] }
        XCTAssertEqual(ids, ["msg_1", "msg_2"])
    }

    func testPushOpenIDIsNotMarkedWhenTheEventIsNotQueued() async throws {
        let transport = MockTransport()
        let client = makeLifecycleClient(transport: transport)
        await client.close()

        do {
            try await client.trackPushOpened(userInfo: ["whisperr_message_id": "msg_1"])
            XCTFail("expected closed")
        } catch let error as WhisperrClientError {
            XCTAssertEqual(error, .closed)
        }
        let remembered = await client.rememberedPushOpenCount
        XCTAssertEqual(remembered, 0)
    }

    func testConcurrentDuplicateTapsSendOnce() async throws {
        let transport = MockTransport()
        let client = makeLifecycleClient(transport: transport)
        async let a = client.trackPushOpened(userInfo: ["whisperr_message_id": "msg_1"])
        async let b = client.trackPushOpened(userInfo: ["whisperr_message_id": "msg_1"])
        let results = try await [a, b]
        await client.flush()

        XCTAssertEqual(results.filter { $0 }.count, 1)
        let ids = await transport.sentEvents().map { $0["properties"]?.objectValue?["whisperr_message_id"] }
        XCTAssertEqual(ids, ["msg_1"])
    }
}

final class OptOutTests: XCTestCase {
    func testOptOutDiscardsQueueAndStopsAllSends() async throws {
        let transport = MockTransport()
        let client = makeLifecycleClient(transport: transport)
        try await client.identify("user_1")
        try await client.track("lesson_completed")

        await client.optOut()
        try await client.track("lesson_completed")
        try await client.identify("user_1", traits: ["plan": "pro"])
        try await client.setPushToken("tok")
        try await client.screen("Home")
        await client.handleAppLaunch(inForeground: true)
        let pushSent = try await client.trackPushOpened(userInfo: ["whisperr_message_id": "msg_1"])
        await client.flush()

        XCTAssertFalse(pushSent)
        let optedOut = await client.isOptedOut
        XCTAssertTrue(optedOut)
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
        let pending = await client.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func testOptOutPersistsAcrossRestartAndResetAndOptInResumes() async throws {
        let transport = MockTransport()
        let persistence = InMemoryWhisperrPersistence()
        let first = makeLifecycleClient(transport: transport, persistence: persistence)
        await first.optOut()
        await first.reset()
        await first.close()

        let second = makeLifecycleClient(transport: transport, persistence: persistence)
        try await second.track("lesson_completed")
        await second.flush()
        let stillOptedOut = await second.isOptedOut
        XCTAssertTrue(stillOptedOut)
        let none = await transport.requests
        XCTAssertTrue(none.isEmpty)

        await second.optIn()
        try await second.track("lesson_completed")
        await second.flush()
        let types = await transport.sentEvents().map { $0["event_type"] }
        XCTAssertEqual(types, ["lesson_completed"])
    }

    func testPushOptOutIsRetriedAfterRestartWhileOptedOut() async throws {
        let transport = MockTransport()
        let persistence = InMemoryWhisperrPersistence()
        let first = makeLifecycleClient(transport: transport, persistence: persistence)
        try await first.identify("user_1")
        try await first.setPushToken("tok_a")
        await first.flush()

        await transport.setResult(.retry)
        await first.optOut()
        await first.optOut()
        await first.close()

        await transport.setResult(.ok)
        let triedBeforeRestart = await transport.requests.count
        let second = makeLifecycleClient(transport: transport, persistence: persistence)
        try await second.track("lesson_completed")
        await second.flush()

        let optOut: JSONValue = [
            "external_user_id": "user_1",
            "channels": [["channel": "push", "address": "tok_a", "opted_in": false]]
        ]
        let afterRestart = await transport.requests.dropFirst(triedBeforeRestart)
        XCTAssertEqual(Array(afterRestart), [MockTransport.Request(path: "/v1/identify", body: optOut)])
        let pending = await second.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func testQueuedRetirementsSurviveOptOut() async throws {
        let transport = MockTransport()
        let client = makeLifecycleClient(transport: transport)
        try await client.identify("user_1")
        try await client.setPushToken("tok_a")
        await client.flush()

        await transport.setResult(.retry)
        try await client.setPushToken("tok_b")
        try await client.track("lesson_completed")
        await client.optOut()
        await client.optIn()
        await client.optOut()
        await transport.setResult(.ok)
        let triedOffline = await transport.requests.count
        await client.flush()

        let delivered = await transport.requests.dropFirst(triedOffline).map(\.body)
        XCTAssertEqual(delivered, [
            ["external_user_id": "user_1", "channels": [["channel": "push", "address": "tok_a", "opted_in": false]]],
            ["external_user_id": "user_1", "channels": [["channel": "push", "address": "tok_b", "opted_in": false]]]
        ])
    }

    func testDataInFlightDuringOptOutIsNotRetried() async throws {
        let transport = GatedTransport()
        let client = WhisperrClient(
            apiKey: "wrk_test",
            options: WhisperrOptions(flushInterval: 0, maxRetries: 0, automaticEvents: false),
            persistence: InMemoryWhisperrPersistence(),
            transport: transport,
            sleeper: { _ in },
            deviceTraits: { [:] }
        )
        try await client.identify("user_1")
        try await client.setPushToken("tok_a")
        await client.flush()

        try await client.track("lesson_completed")
        await transport.holdNextSend()
        let inFlight = Task { await client.flush() }
        await transport.waitUntilHolding()
        await client.optOut()
        await transport.release(.retry)
        await inFlight.value
        await client.flush()

        let paths = await transport.requests.dropFirst(2).map(\.path)
        XCTAssertEqual(paths, ["/v1/events/batch", "/v1/identify"], "the failed batch is not sent again after the opt-out")
        let pending = await client.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func testOptedOutInstallFromOlderSDKRetiresItsTokenOnce() async throws {
        let transport = MockTransport()
        let persistence = InMemoryWhisperrPersistence()
        let legacy = PersistedState(userID: "user_1", lastPushUserID: "user_1", lastPushToken: "tok_a", optedOut: true)
        await persistence.save(try JSONEncoder.whisperr.encode(legacy))

        let first = makeLifecycleClient(transport: transport, persistence: persistence)
        await first.flush()
        await first.close()
        let second = makeLifecycleClient(transport: transport, persistence: persistence)
        await second.flush()

        let optOut: JSONValue = [
            "external_user_id": "user_1",
            "channels": [["channel": "push", "address": "tok_a", "opted_in": false]]
        ]
        let requests = await transport.requests
        XCTAssertEqual(requests, [MockTransport.Request(path: "/v1/identify", body: optOut)])
    }
}

final class RetryAfterTests: XCTestCase {
    func testParsesSecondsAndHTTPDateAndCaps() {
        let now = Date(timeIntervalSince1970: 1_780_229_600) // Sun, 31 May 2026 12:13:20 GMT
        XCTAssertEqual(parseRetryAfter("30", now: now), 30)
        XCTAssertEqual(parseRetryAfter(" 0 ", now: now), 0)
        XCTAssertEqual(parseRetryAfter("3600", now: now), kWhisperrMaxRetryAfter)
        XCTAssertEqual(parseRetryAfter("Sun, 31 May 2026 12:13:40 GMT", now: now), 20)
        XCTAssertEqual(parseRetryAfter("Sun, 31 May 2026 12:00:00 GMT", now: now), 0)
        XCTAssertNil(parseRetryAfter(nil, now: now))
        XCTAssertNil(parseRetryAfter("", now: now))
        XCTAssertNil(parseRetryAfter("1.5", now: now))
        XCTAssertNil(parseRetryAfter("-5", now: now))
        XCTAssertNil(parseRetryAfter("soon", now: now))
    }

    func testClientWaitsWhatTheServerAsks() async throws {
        let sleeps = SleepRecorder()
        let transport = ScriptedTransport(results: [.retryAfter(30), .ok])
        let client = WhisperrClient(
            apiKey: "wrk_test",
            options: WhisperrOptions(flushInterval: 0, maxRetries: 3),
            persistence: InMemoryWhisperrPersistence(),
            transport: transport,
            sleeper: { sleeps.record($0) },
            deviceTraits: { [:] }
        )
        try await client.track("lesson_completed", userID: "user_1")
        await client.flush()

        XCTAssertEqual(sleeps.values.count, 1)
        let wait = try XCTUnwrap(sleeps.values.first)
        XCTAssertGreaterThanOrEqual(wait, 30)
        XCTAssertLessThanOrEqual(wait, 30.25)
        let sends = await transport.sendCount
        XCTAssertEqual(sends, 2)
        let pending = await client.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func testRetryAfterCountsTowardMaxRetries() async throws {
        let errors = ErrorRecorder()
        let transport = ScriptedTransport(results: [.retryAfter(1), .retryAfter(1), .retryAfter(1)])
        let client = WhisperrClient(
            apiKey: "wrk_test",
            options: WhisperrOptions(flushInterval: 0, maxRetries: 1, onError: { errors.append($0) }),
            persistence: InMemoryWhisperrPersistence(),
            transport: transport,
            sleeper: { _ in },
            deviceTraits: { [:] }
        )
        try await client.track("lesson_completed", userID: "user_1")
        await client.flush()

        let sends = await transport.sendCount
        XCTAssertEqual(sends, 2)
        XCTAssertEqual(errors.values.map(\.type), [.retryExhausted])
        let pending = await client.pendingCount
        XCTAssertEqual(pending, 1)
    }
}

final class EmailShortcutTests: XCTestCase {
    /// Report 14 B1: the shortcut must not mark the address unverified. It
    /// sends no `verified` key (SPEC.md: "omit unless set"); an explicit value
    /// from the caller is kept.
    func testEmailShortcutOmitsVerifiedAndExplicitValueIsKept() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport)

        try await client.identify("user_1", email: "ada@example.com")
        try await client.identify("user_1", channels: [.email("ada@example.com", verified: false)])
        await client.flush()

        let channels = await transport.requests.map { $0.body.objectValue?["channels"] }
        XCTAssertEqual(channels, [
            [["channel": "email", "address": "ada@example.com", "opted_in": true]],
            [["channel": "email", "address": "ada@example.com", "verified": false]]
        ])
    }
}

final class PrivacyManifestTests: XCTestCase {
    func testManifestShipsAsResourceAndDeclaresUserDefaults() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let data = try Data(contentsOf: url)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        let apis = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        XCTAssertEqual(apis.first?["NSPrivacyAccessedAPIType"] as? String, "NSPrivacyAccessedAPICategoryUserDefaults")
        XCTAssertEqual(apis.first?["NSPrivacyAccessedAPITypeReasons"] as? [String], ["CA92.1"])
        let collected = try XCTUnwrap(plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        XCTAssertEqual(
            Set(collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String }),
            [
                "NSPrivacyCollectedDataTypeUserID",
                "NSPrivacyCollectedDataTypeDeviceID",
                "NSPrivacyCollectedDataTypeProductInteraction"
            ]
        )
        for entry in collected {
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false)
        }
    }
}

/// Returns the scripted results in order, then `.ok`.
actor ScriptedTransport: WhisperrTransport {
    private var results: [WhisperrSendResult]
    private(set) var sendCount = 0

    init(results: [WhisperrSendResult]) {
        self.results = results
    }

    func send(path: String, body: JSONValue) async -> WhisperrSendResult {
        sendCount += 1
        return results.isEmpty ? .ok : results.removeFirst()
    }
}
