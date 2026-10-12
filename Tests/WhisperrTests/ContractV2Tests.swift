import XCTest
@testable import Whisperr

private func identifies(_ transport: MockTransport) async -> [[String: JSONValue]] {
    await transport.requests
        .filter { $0.path == "/v1/identify" }
        .compactMap(\.body.objectValue)
}

private let device: @Sendable () -> [String: JSONValue] = {
    ["timezone": "Europe/Berlin", "locale": "de-DE"]
}

/// C1: one restore identify per app start for the stored user.
final class RestoreIdentifyTests: XCTestCase {
    /// A stored user from an earlier session: identify, deliver, close.
    private func seed(
        _ persistence: InMemoryWhisperrPersistence,
        _ transport: MockTransport,
        clock: TestClock,
        traits: @escaping @Sendable () -> [String: JSONValue] = device
    ) async throws {
        let first = makeClient(transport: transport, persistence: persistence, clock: { clock.now }, deviceTraits: traits)
        try await first.identify("user_1", traits: ["plan": "pro"])
        await first.close()
    }

    func testStoredUserWithoutAnEarlierIdentifyGetsOneRestoreIdentify() async throws {
        // State an older SDK wrote: a stored user and anonymous id, no record
        // of a delivered identify.
        let legacy = PersistedState(userID: "user_1", anonymousID: "anon-1", appLanguage: "pt-BR")
        let persistence = InMemoryWhisperrPersistence(data: try JSONEncoder.whisperr.encode(legacy))
        let transport = MockTransport()
        let client = makeClient(transport: transport, persistence: persistence, deviceTraits: device)

        await client.flush()
        await client.flush()

        let bodies = await identifies(transport)
        XCTAssertEqual(bodies, [[
            "external_user_id": "user_1",
            "anonymous_id": "anon-1",
            "traits": ["timezone": "Europe/Berlin", "locale": "de-DE", "app_language": "pt-BR"]
        ]])
    }

    func testRestoreIsSkippedWithin24HoursWhenTheTraitsAreUnchanged() async throws {
        let persistence = InMemoryWhisperrPersistence()
        let transport = MockTransport()
        let clock = TestClock()
        try await seed(persistence, transport, clock: clock)

        clock.advance(23 * 3_600)
        let second = makeClient(transport: transport, persistence: persistence, clock: { clock.now }, deviceTraits: device)
        await second.flush()

        let count = await identifies(transport).count
        XCTAssertEqual(count, 1)
    }

    func testRestoreIsSentAfter24Hours() async throws {
        let persistence = InMemoryWhisperrPersistence()
        let transport = MockTransport()
        let clock = TestClock()
        try await seed(persistence, transport, clock: clock)

        clock.advance(24 * 3_600)
        let second = makeClient(transport: transport, persistence: persistence, clock: { clock.now }, deviceTraits: device)
        await second.flush()

        let bodies = await identifies(transport)
        XCTAssertEqual(bodies.count, 2)
        // Device defaults only: no caller traits, no channels.
        XCTAssertEqual(bodies[1], [
            "external_user_id": "user_1",
            "traits": ["timezone": "Europe/Berlin", "locale": "de-DE"]
        ])

        // The delivered restore starts a new window.
        clock.advance(3_600)
        let third = makeClient(transport: transport, persistence: persistence, clock: { clock.now }, deviceTraits: device)
        await third.flush()
        let after = await identifies(transport).count
        XCTAssertEqual(after, 2)
    }

    func testRestoreIsSentWithin24HoursWhenADeviceTraitChanged() async throws {
        let persistence = InMemoryWhisperrPersistence()
        let transport = MockTransport()
        let clock = TestClock()
        try await seed(persistence, transport, clock: clock)

        let second = makeClient(
            transport: transport,
            persistence: persistence,
            clock: { clock.now },
            deviceTraits: { ["timezone": "America/New_York", "locale": "de-DE"] }
        )
        await second.flush()

        let bodies = await identifies(transport)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[1]["traits"], ["timezone": "America/New_York", "locale": "de-DE"])
    }

    func testRestoreIsSentWithin24HoursWhenTheStoredAppLanguageIsNew() async throws {
        // A stored app language the server never got (for example its
        // partial identify was dropped): the next start sends it.
        let persistence = InMemoryWhisperrPersistence()
        let transport = MockTransport()
        let clock = TestClock()
        try await seed(persistence, transport, clock: clock)
        let data = await persistence.load()
        var state = try JSONDecoder.whisperr.decode(PersistedState.self, from: XCTUnwrap(data))
        state.appLanguage = "fr"
        await persistence.save(try JSONEncoder.whisperr.encode(state))

        let second = makeClient(transport: transport, persistence: persistence, clock: { clock.now }, deviceTraits: device)
        await second.flush()

        let bodies = await identifies(transport)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[1]["traits"]?.objectValue?["app_language"], "fr")
    }

    func testAppIdentifyingTheSameUserFirstSkipsTheRestore() async throws {
        let legacy = PersistedState(userID: "user_1")
        let persistence = InMemoryWhisperrPersistence(data: try JSONEncoder.whisperr.encode(legacy))
        let transport = MockTransport()
        let client = makeClient(transport: transport, persistence: persistence, deviceTraits: device)

        await client.start()
        try await client.identify("user_1", traits: ["plan": "pro"])
        await client.flush()

        let bodies = await identifies(transport)
        XCTAssertEqual(bodies, [[
            "external_user_id": "user_1",
            "traits": ["timezone": "Europe/Berlin", "locale": "de-DE", "plan": "pro"]
        ]])
    }

    func testAppIdentifyingAnotherUserFirstSkipsTheRestore() async throws {
        let legacy = PersistedState(userID: "user_1")
        let persistence = InMemoryWhisperrPersistence(data: try JSONEncoder.whisperr.encode(legacy))
        let transport = MockTransport()
        let client = makeClient(transport: transport, persistence: persistence)

        await client.start()
        try await client.identify("user_2")
        await client.flush()

        let bodies = await identifies(transport)
        XCTAssertEqual(bodies, [["external_user_id": "user_2"]])
    }

    func testResetOrOptOutBeforeTheRestoreSkipsIt() async throws {
        for action in ["reset", "optOut"] {
            let legacy = PersistedState(userID: "user_1")
            let persistence = InMemoryWhisperrPersistence(data: try JSONEncoder.whisperr.encode(legacy))
            let transport = MockTransport()
            let client = makeClient(transport: transport, persistence: persistence)

            await client.start()
            if action == "reset" {
                await client.reset()
            } else {
                await client.optOut()
            }
            await client.flush()

            let count = await identifies(transport).count
            XCTAssertEqual(count, 0, action)
        }
    }

    func testOptedOutUserGetsNoRestore() async throws {
        let legacy = PersistedState(userID: "user_1", optedOut: true)
        let persistence = InMemoryWhisperrPersistence(data: try JSONEncoder.whisperr.encode(legacy))
        let transport = MockTransport()
        let client = makeClient(transport: transport, persistence: persistence)
        await client.flush()
        let count = await identifies(transport).count
        XCTAssertEqual(count, 0)
    }

    func testTheDebounceQueuesTheRestoreWithoutAFlush() async throws {
        let legacy = PersistedState(userID: "user_1")
        let persistence = InMemoryWhisperrPersistence(data: try JSONEncoder.whisperr.encode(legacy))
        let transport = MockTransport()
        let delays = SleepRecorder()
        let client = makeClient(
            transport: transport,
            persistence: persistence,
            sleeper: { delays.record($0) },
            restoreDebounceFires: true
        )

        await client.start()
        for _ in 0..<1_000 where await client.pendingCount == 0 {
            await Task.yield()
        }

        XCTAssertEqual(delays.values, [WhisperrClient.restoreIdentifyDelay])
        let pending = await client.pendingCount
        XCTAssertEqual(pending, 1)
        let requests = await transport.requests.count
        XCTAssertEqual(requests, 0)
        // It waits in the persisted queue: a relaunch still sends it once.
        let relaunched = makeClient(transport: transport, persistence: persistence)
        await relaunched.flush()
        let bodies = await identifies(transport)
        XCTAssertEqual(bodies, [["external_user_id": "user_1"]])
    }

    func testOfflineRestoreStaysQueuedAndIsNotRepeated() async throws {
        let legacy = PersistedState(userID: "user_1")
        let persistence = InMemoryWhisperrPersistence(data: try JSONEncoder.whisperr.encode(legacy))
        let transport = MockTransport(result: .retry)
        let client = makeClient(transport: transport, maxRetries: 0, persistence: persistence)

        await client.flush()
        await client.flush()
        let pending = await client.pendingCount
        XCTAssertEqual(pending, 1)

        await transport.setResult(.ok)
        await client.flush()
        let sent = await identifies(transport).filter { $0 == ["external_user_id": "user_1"] }
        // Two failed attempts and one delivery of the same single op.
        XCTAssertEqual(sent.count, 3)
        let left = await client.pendingCount
        XCTAssertEqual(left, 0)
    }
}

/// C2: setAppLanguage.
final class AppLanguageTests: XCTestCase {
    func testWithAUserSendsAPartialIdentify() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport, deviceTraits: device)
        try await client.identify("user_1")
        await client.setAppLanguage("pt_BR")
        await client.flush()

        let bodies = await identifies(transport)
        XCTAssertEqual(bodies.last, ["external_user_id": "user_1", "traits": ["app_language": "pt-BR"]])
    }

    func testWithoutAUserSendsAnAnonymousIdentify() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport, anonymousIDGenerator: { "anon-1" })
        await client.setAppLanguage("de")
        try await client.track("lesson_started")
        await client.flush()

        let bodies = await identifies(transport)
        XCTAssertEqual(bodies, [["anonymous_id": "anon-1", "traits": ["app_language": "de"]]])
        let events = await transport.sentEvents()
        XCTAssertEqual(events.first?["anonymous_id"], "anon-1")
    }

    func testInvalidSameAndNilSendNothing() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport)
        try await client.identify("user_1")
        await client.setAppLanguage("de")
        await client.setAppLanguage("de")
        await client.setAppLanguage("not a tag")
        await client.setAppLanguage("")
        await client.setAppLanguage("und")
        let kept = await client.currentAppLanguage
        XCTAssertEqual(kept, "de")
        await client.setAppLanguage(nil)
        let cleared = await client.currentAppLanguage
        XCTAssertNil(cleared)
        try await client.identify("user_1")
        await client.flush()

        let bodies = await identifies(transport)
        XCTAssertEqual(bodies, [
            ["external_user_id": "user_1"],
            ["external_user_id": "user_1", "traits": ["app_language": "de"]],
            ["external_user_id": "user_1"]
        ])
    }

    func testEveryIdentifyCarriesTheStoredValueAndACallerValueWins() async throws {
        let transport = MockTransport()
        let persistence = InMemoryWhisperrPersistence()
        let first = makeClient(transport: transport, persistence: persistence)
        await first.setAppLanguage("es")
        await first.close()

        let second = makeClient(transport: transport, persistence: persistence)
        try await second.identify("user_1", traits: ["plan": "pro"])
        try await second.identify("user_1", traits: ["app_language": "it"])
        await second.flush()

        let bodies = await identifies(transport)
        XCTAssertEqual(bodies.count, 3)
        XCTAssertEqual(bodies[1]["traits"], ["plan": "pro", "app_language": "es"])
        XCTAssertEqual(bodies[2]["traits"], ["app_language": "it"])
    }

    func testOptedOutStoresButDoesNotSend() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport)
        try await client.identify("user_1")
        await client.flush()
        await client.optOut()
        await client.setAppLanguage("fr")
        await client.flush()
        let stored = await client.currentAppLanguage
        XCTAssertEqual(stored, "fr")
        let count = await identifies(transport).count
        XCTAssertEqual(count, 1)
    }

    func testTagNormalization() {
        XCTAssertEqual(WhisperrClient.normalizedLanguageTag(" zh_Hant_TW "), "zh-Hant-TW")
        XCTAssertEqual(WhisperrClient.normalizedLanguageTag("en"), "en")
        XCTAssertNil(WhisperrClient.normalizedLanguageTag("e"))
        XCTAssertNil(WhisperrClient.normalizedLanguageTag("en--US"))
        XCTAssertNil(WhisperrClient.normalizedLanguageTag("12"))
    }
}

/// C3: anonymous push tokens.
final class AnonymousPushTokenTests: XCTestCase {
    func testTokenBeforeIdentifyIsSentAnonymouslyThenAttachedToTheUser() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport, anonymousIDGenerator: { "anon-1" })
        try await client.setPushToken("fcm_tok_a")
        try await client.setPushToken("fcm_tok_a") // same subject + token: nothing
        try await client.identify("user_1")
        try await client.setPushToken("fcm_tok_a") // attached already: nothing
        await client.flush()

        let bodies = await identifies(transport)
        XCTAssertEqual(bodies, [
            ["anonymous_id": "anon-1", "channels": [["channel": "push", "address": "fcm_tok_a", "opted_in": true]]],
            [
                "external_user_id": "user_1",
                "anonymous_id": "anon-1",
                "channels": [["channel": "push", "address": "fcm_tok_a", "opted_in": true]]
            ]
        ])
    }

    func testAnonymousRotationOptsTheOldTokenOutUnderTheHandle() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport, anonymousIDGenerator: { "anon-1" })
        try await client.setPushToken("fcm_tok_a")
        try await client.setPushToken("fcm_tok_b")
        await client.flush()

        let bodies = await identifies(transport)
        XCTAssertEqual(bodies.last, [
            "anonymous_id": "anon-1",
            "channels": [
                ["channel": "push", "address": "fcm_tok_a", "opted_in": false],
                ["channel": "push", "address": "fcm_tok_b", "opted_in": true]
            ]
        ])
    }

    func testResetMovesTheTokenToANewHandle() async throws {
        let transport = MockTransport()
        let handles = IDSequence()
        let client = makeClient(transport: transport, anonymousIDGenerator: { "anon-" + handles.next() })
        try await client.track("app_used") // creates anon-mid-1
        try await client.identify("user_1")
        try await client.setPushToken("fcm_tok_a")
        await client.reset()
        await client.flush()

        let bodies = await identifies(transport)
        XCTAssertEqual(Array(bodies.suffix(2)), [
            ["external_user_id": "user_1", "channels": [["channel": "push", "address": "fcm_tok_a", "opted_in": false]]],
            ["anonymous_id": "anon-mid-2", "channels": [["channel": "push", "address": "fcm_tok_a", "opted_in": true]]]
        ])
        // The pair is recorded under the new handle: the same token is a no-op.
        try await client.setPushToken("fcm_tok_a")
        await client.flush()
        let after = await identifies(transport).count
        XCTAssertEqual(after, bodies.count)
    }

    func testResetWithoutATokenSendsNothing() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport)
        try await client.identify("user_1")
        await client.reset()
        await client.flush()
        let count = await identifies(transport).count
        XCTAssertEqual(count, 1)
    }

    func testDeniedHoldsTheTokenAndARegrantRegistersItAnonymously() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport, anonymousIDGenerator: { "anon-1" })
        await client.pushPermissionChanged(.denied)
        try await client.setPushToken("fcm_tok_a")
        await client.flush()
        let held = await identifies(transport).count
        XCTAssertEqual(held, 0)

        await client.pushPermissionChanged(.authorized)
        await client.flush()
        let bodies = await identifies(transport)
        XCTAssertEqual(bodies, [
            ["anonymous_id": "anon-1", "channels": [["channel": "push", "address": "fcm_tok_a", "opted_in": true]]]
        ])
    }

    func testDeniedOptsAnAnonymousTokenOut() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport, anonymousIDGenerator: { "anon-1" })
        try await client.setPushToken("fcm_tok_a")
        await client.pushPermissionChanged(.denied)
        await client.flush()
        let bodies = await identifies(transport)
        XCTAssertEqual(bodies.last, [
            "anonymous_id": "anon-1",
            "channels": [["channel": "push", "address": "fcm_tok_a", "opted_in": false]]
        ])
    }

    func testOptOutOptsAnAnonymousTokenOutThenSendsNothing() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport, anonymousIDGenerator: { "anon-1" })
        try await client.setPushToken("fcm_tok_a")
        await client.flush()
        await client.optOut()
        try await client.setPushToken("fcm_tok_b")
        await client.flush()
        let bodies = await identifies(transport)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies.last, [
            "anonymous_id": "anon-1",
            "channels": [["channel": "push", "address": "fcm_tok_a", "opted_in": false]]
        ])
    }

    func testAnonymousPairSurvivesARestart() async throws {
        let transport = MockTransport()
        let persistence = InMemoryWhisperrPersistence()
        let first = makeClient(transport: transport, persistence: persistence, anonymousIDGenerator: { "anon-1" })
        try await first.setPushToken("fcm_tok_a")
        await first.close()

        let second = makeClient(transport: transport, persistence: persistence)
        try await second.setPushToken("fcm_tok_a")
        try await second.identify("user_1")
        await second.flush()

        let bodies = await identifies(transport)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[1]["anonymous_id"], "anon-1")
        XCTAssertEqual(bodies[1]["channels"], [["channel": "push", "address": "fcm_tok_a", "opted_in": true]])
    }
}

/// C4: push contract v2.
final class PushContractV2Tests: XCTestCase {
    private func entries(_ transport: MockTransport) async -> [[String: JSONValue]] {
        await identifies(transport).flatMap { ($0["channels"]?.arrayValue ?? []).compactMap(\.objectValue) }
    }

    func testProviderProjectAndDeviceFieldsAreSent() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport, environment: .device)
        try await client.identify("user_1")
        try await client.setPushToken(fcmToken: "fcm_tok_a", firebaseProjectID: "my-firebase")
        try await client.setPushToken(oneSignalSubscriptionID: "os_sub_1", oneSignalAppID: "os-app")
        try await client.setPushToken("aa11", kind: .apns, providerProject: "ignored-for-apns")
        await client.flush()

        let sent = await entries(transport).filter { $0["opted_in"] == true }
        XCTAssertEqual(sent, [
            [
                "channel": "push", "address": "fcm_tok_a", "opted_in": true, "kind": "fcm",
                "platform": "ios", "client_app_id": "com.example.app", "provider_project": "my-firebase"
            ],
            [
                "channel": "push", "address": "os_sub_1", "opted_in": true, "kind": "onesignal_sub",
                "platform": "ios", "client_app_id": "com.example.app", "provider_project": "os-app"
            ],
            [
                "channel": "push", "address": "aa11", "opted_in": true, "kind": "apns",
                "platform": "ios", "push_env": "sandbox", "client_app_id": "com.example.app"
            ]
        ])
    }

    func testIdentifyPushTokenShortcutCarriesTheDeviceFields() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport, environment: .device)
        try await client.identify("user_1", pushToken: "fcm_tok_a")
        await client.flush()
        let sent = await entries(transport)
        XCTAssertEqual(sent, [[
            "channel": "push", "address": "fcm_tok_a", "opted_in": true,
            "platform": "ios", "client_app_id": "com.example.app"
        ]])
    }

    func testANewProviderProjectOnTheSameTokenResends() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport)
        try await client.identify("user_1")
        try await client.setPushToken(fcmToken: "fcm_tok_a")
        try await client.setPushToken(fcmToken: "fcm_tok_a", firebaseProjectID: "p1")
        try await client.setPushToken(fcmToken: "fcm_tok_a", firebaseProjectID: "p1")
        await client.flush()
        let count = await entries(transport).count
        XCTAssertEqual(count, 2)
    }

    func testTheSameTokenIsSentAgainAfterSevenDays() async throws {
        let transport = MockTransport()
        let persistence = InMemoryWhisperrPersistence()
        let clock = TestClock()
        let first = makeClient(transport: transport, persistence: persistence, clock: { clock.now })
        try await first.identify("user_1")
        try await first.setPushToken("fcm_tok_a")
        await first.close()

        clock.advance(6 * 86_400)
        let second = makeClient(transport: transport, persistence: persistence, clock: { clock.now })
        try await second.setPushToken("fcm_tok_a")
        await second.close()
        let early = await entries(transport).count
        XCTAssertEqual(early, 1)

        clock.advance(86_400)
        let third = makeClient(transport: transport, persistence: persistence, clock: { clock.now })
        try await third.setPushToken("fcm_tok_a")
        try await third.setPushToken("fcm_tok_a")
        await third.flush()
        let sent = await entries(transport)
        XCTAssertEqual(sent.count, 2)
        // A re-registration, never an opt-out of the same address.
        XCTAssertEqual(sent.map { $0["opted_in"] }, [true, true])
    }

    func testPushOpenedCarriesActionIDAndColdStart() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport)
        try await client.identify("user_1")
        try await client.trackPushOpened(WhisperrPushPayload(messageID: "m1"))
        try await client.trackPushOpened(WhisperrPushPayload(messageID: "m2", actionID: "reply", coldStart: true))
        try await client.trackPushOpened(WhisperrPushPayload(messageID: "m3", coldStart: false))
        await client.flush()

        let properties = await transport.sentEvents().compactMap { $0["properties"]?.objectValue }
        XCTAssertEqual(properties.map { $0["action_id"] }, ["default", "reply", "default"])
        XCTAssertEqual(properties.map { $0["cold_start"] }, [nil, true, false])
    }

    func testUserInfoPayloadHasNoColdStartWithoutAUIKitLifecycle() throws {
        let payload = try XCTUnwrap(WhisperrPushPayload(userInfo: ["whisperr_message_id": "m1"]))
        XCTAssertNil(payload.actionID)
        #if canImport(UIKit) && !os(watchOS)
        XCTAssertNotNil(payload.coldStart)
        #else
        XCTAssertNil(payload.coldStart)
        #endif
    }

    func testPushReceivedIsSentOncePerMessageID() async throws {
        let transport = MockTransport()
        let persistence = InMemoryWhisperrPersistence()
        let first = makeLifecycleClient(transport: transport, persistence: persistence)
        try await first.identify("user_1")
        let sent = try await first.trackPushReceived(userInfo: ["whisperr_message_id": "m1", "whisperr_deep_link": "app://x"])
        let again = try await first.trackPushReceived(userInfo: ["whisperr_message_id": "m1"])
        let other = try await first.trackPushReceived(userInfo: ["aps": ["alert": "hi"]])
        await first.close()
        XCTAssertTrue(sent)
        XCTAssertFalse(again)
        XCTAssertFalse(other)

        let second = makeLifecycleClient(transport: transport, persistence: persistence)
        let afterRestart = try await second.trackPushReceived(WhisperrPushPayload(messageID: "m1"))
        XCTAssertFalse(afterRestart)
        await second.optOut()
        let optedOut = try await second.trackPushReceived(WhisperrPushPayload(messageID: "m2"))
        XCTAssertFalse(optedOut)

        let events = await transport.sentEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["event_type"], "push_received")
        let properties = try XCTUnwrap(events[0]["properties"]?.objectValue)
        XCTAssertEqual(properties["whisperr_message_id"], "m1")
        XCTAssertEqual(properties["foreground"], true)
        XCTAssertEqual(properties["source"], "foreground")
        XCTAssertNil(properties["deep_link"])
    }

    func testTheOffSwitchStopsPushReceivedButNotPushOpened() async throws {
        let transport = MockTransport()
        let client = makeLifecycleClient(transport: transport, automaticEvents: false)
        let received = try await client.trackPushReceived(WhisperrPushPayload(messageID: "m1"))
        let opened = try await client.trackPushOpened(WhisperrPushPayload(messageID: "m1"))
        await client.flush()
        XCTAssertFalse(received)
        XCTAssertTrue(opened)
        let types = await transport.sentEvents().map { $0["event_type"] }
        XCTAssertEqual(types, ["push_opened"])
    }

    func testRestoreRecordUsesTheDeviceTraitsNotTheCallerOverride() async throws {
        // identify() with a caller locale: the record keeps the device
        // restore traits, so the next start does not overwrite the caller's
        // value with a restore identify.
        let transport = MockTransport()
        let persistence = InMemoryWhisperrPersistence()
        let first = makeClient(transport: transport, persistence: persistence, deviceTraits: device)
        try await first.identify("user_1", traits: ["locale": "en-US"])
        await first.close()
        let second = makeClient(transport: transport, persistence: persistence, deviceTraits: device)
        await second.flush()
        let count = await identifies(transport).count
        XCTAssertEqual(count, 1)
    }

    func testSentAtIsTheDeliveryTime() async throws {
        // Queued offline for 3 days, delivered, then 6 more days: still
        // inside 7 days of the delivery, so no re-registration.
        let transport = MockTransport(result: .retry)
        let clock = TestClock()
        let client = makeClient(transport: transport, maxRetries: 0, clock: { clock.now })
        try await client.identify("user_1")
        try await client.setPushToken("fcm_tok_a")
        await client.flush()
        clock.advance(3 * 86_400)
        await transport.setResult(.ok)
        await client.flush()
        clock.advance(6 * 86_400)
        try await client.setPushToken("fcm_tok_a")
        await client.flush()
        let registrations = await identifies(transport).filter { $0["channels"] != nil }
        // Delivered once on day 3 (it waited behind the failed identify). With
        // sent_at at enqueue time (day 0), day 9 would send it again.
        XCTAssertEqual(registrations.count, 1)
    }

    func testRequestPushAuthorizationReportsTheResult() async throws {
        let transport = MockTransport()
        let asked = SleepRecorder() // records 1 for provisional, 0 otherwise
        let client = makeLifecycleClient(
            transport: transport,
            pushAuthorization: { provisional in
                asked.record(provisional ? 1 : 0)
                return provisional ? .provisional : .denied
            }
        )
        let quiet = await client.requestPushAuthorization(provisional: true)
        let loud = await client.requestPushAuthorization()
        await client.flush()

        XCTAssertEqual(quiet, .provisional)
        XCTAssertEqual(loud, .denied)
        XCTAssertEqual(asked.values, [1, 0])
        let statuses = await transport.sentEvents()
            .filter { $0["event_type"] == "push_permission_changed" }
            .map { $0["properties"]?.objectValue?["status"] }
        XCTAssertEqual(statuses, ["provisional", "denied"])
    }

    func testRequestPushAuthorizationOutsideAnAppReturnsNil() async {
        let status = await WhisperrPushPermission.request(provisional: false)
        XCTAssertNil(status)
    }
}

/// C5: versions on every event.
final class EventContextTests: XCTestCase {
    func testEveryEventCarriesTheVersionKeysAndACallerKeyWins() async throws {
        let transport = MockTransport()
        let client = makeClient(
            transport: transport,
            eventContext: { AppEnvironment.device.eventContext }
        )
        try await client.track("lesson_started", context: ["app_version": "9.9.9", "screen": "home"])
        try await client.trackPushOpened(WhisperrPushPayload(messageID: "m1"))
        await client.flush()

        let contexts = await transport.sentEvents().compactMap { $0["context"]?.objectValue }
        XCTAssertEqual(contexts.count, 2)
        XCTAssertEqual(contexts[0], [
            "app_version": "9.9.9", "app_build": "230", "platform": "ios",
            "sdk_name": "whisperr-swift", "sdk_version": .string(kWhisperrSdkVersion),
            "screen": "home", "$message_id": "mid-1"
        ])
        XCTAssertEqual(contexts[1]["app_version"], "2.3.0")
        XCTAssertNil(contexts[1]["locale"])
    }

    func testMissingValuesAreOmitted() {
        let context = AppEnvironment.silent.eventContext
        XCTAssertEqual(context, ["platform": "ios", "sdk_name": "whisperr-swift", "sdk_version": .string(kWhisperrSdkVersion)])
    }

    func testTheDefaultContextComesFromTheEnvironment() async throws {
        let transport = MockTransport()
        let client = makeLifecycleClient(transport: transport, automaticEvents: false)
        try await client.track("lesson_started")
        await client.flush()
        let context = await transport.sentEvents().first?["context"]?.objectValue
        XCTAssertEqual(context?["app_version"], "1.2.0")
        XCTAssertEqual(context?["app_build"], "42")
        XCTAssertEqual(context?["sdk_version"], .string(kWhisperrSdkVersion))
    }
}
