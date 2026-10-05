import XCTest
#if canImport(UserNotifications)
import UserNotifications
#endif
@testable import Whisperr

final class PermissionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: WhisperrPushPermissionStatus?

    init(_ value: WhisperrPushPermissionStatus?) {
        self.value = value
    }

    func set(_ value: WhisperrPushPermissionStatus?) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }

    func get() -> WhisperrPushPermissionStatus? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class PushPermissionTests: XCTestCase {
    private func permissionEvents(_ transport: MockTransport) async -> [[String: JSONValue]] {
        await transport.sentEvents().filter { $0["event_type"] == "push_permission_changed" }
    }

    func testFirstReportSendsStatusWithCommonProperties() async throws {
        let transport = MockTransport()
        let client = makeLifecycleClient(transport: transport)
        try await client.identify("user_1")

        let sent = await client.pushPermissionChanged(.notDetermined)
        await client.flush()

        XCTAssertTrue(sent)
        let events = await permissionEvents(transport)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["external_user_id"], "user_1")
        let properties = events[0]["properties"]?.objectValue ?? [:]
        XCTAssertEqual(properties["status"], "not_determined")
        XCTAssertNil(properties["previous_status"])
        XCTAssertEqual(properties["platform"], "ios")
        XCTAssertEqual(properties["sdk_name"], "whisperr-swift")
    }

    func testSendsOnlyOnChangeWithPreviousStatus() async throws {
        let transport = MockTransport()
        let client = makeLifecycleClient(transport: transport)

        let results = [
            await client.pushPermissionChanged(.notDetermined),
            await client.pushPermissionChanged(.notDetermined),
            await client.pushPermissionChanged(.authorized),
            await client.pushPermissionChanged(.authorized),
            await client.pushPermissionChanged(.denied)
        ]
        await client.flush()

        XCTAssertEqual(results, [true, false, true, false, true])
        let properties = await permissionEvents(transport).map { $0["properties"]?.objectValue ?? [:] }
        XCTAssertEqual(properties.map { $0["status"] }, ["not_determined", "authorized", "denied"])
        XCTAssertEqual(properties.map { $0["previous_status"] }, [nil, "not_determined", "authorized"])
    }

    func testStoredStatusSurvivesRestart() async throws {
        let transport = MockTransport()
        let persistence = InMemoryWhisperrPersistence()
        let first = makeLifecycleClient(transport: transport, persistence: persistence)
        await first.pushPermissionChanged(.provisional)
        await first.close()

        let second = makeLifecycleClient(transport: transport, persistence: persistence)
        let repeatSent = await second.pushPermissionChanged(.provisional)
        let changed = await second.pushPermissionChanged(.denied)
        await second.flush()

        XCTAssertFalse(repeatSent)
        XCTAssertTrue(changed)
        let previous = await permissionEvents(transport).last?["properties"]?.objectValue?["previous_status"]
        XCTAssertEqual(previous, "provisional")
    }

    func testResetForgetsTheStoredStatus() async throws {
        let transport = MockTransport()
        let client = makeLifecycleClient(transport: transport)
        try await client.identify("user_1")
        await client.pushPermissionChanged(.authorized)
        await client.reset()
        try await client.identify("user_2")
        let sent = await client.pushPermissionChanged(.authorized)
        await client.flush()

        XCTAssertTrue(sent)
        let events = await permissionEvents(transport)
        XCTAssertEqual(events.map { $0["external_user_id"] }, ["user_1", "user_2"])
        XCTAssertNil(events[1]["properties"]?.objectValue?["previous_status"])
    }

    func testOptedOutSendsNothingAndKeepsTheStoredStatus() async throws {
        let transport = MockTransport()
        let client = makeLifecycleClient(transport: transport)
        await client.pushPermissionChanged(.authorized)
        await client.flush()
        await client.optOut()
        let whileOut = await client.pushPermissionChanged(.denied)
        await client.optIn()
        let afterIn = await client.pushPermissionChanged(.denied)
        await client.flush()

        XCTAssertFalse(whileOut)
        XCTAssertTrue(afterIn)
        let properties = await permissionEvents(transport).map { $0["properties"]?.objectValue ?? [:] }
        XCTAssertEqual(properties.map { $0["status"] }, ["authorized", "denied"])
        XCTAssertEqual(properties.last?["previous_status"], "authorized")
    }

    func testConcurrentSameStatusSendsOnce() async throws {
        let transport = MockTransport()
        let client = makeLifecycleClient(transport: transport)
        async let a = client.pushPermissionChanged(.denied)
        async let b = client.pushPermissionChanged(.denied)
        let results = await [a, b]
        await client.flush()

        XCTAssertEqual(results.filter { $0 }.count, 1)
        let count = await permissionEvents(transport).count
        XCTAssertEqual(count, 1)
    }

    func testForegroundReadsThePermissionAutomatically() async throws {
        let transport = MockTransport()
        let permission = PermissionBox(.notDetermined)
        let client = makeLifecycleClient(transport: transport, pushPermission: { permission.get() })

        await client.handleAppLaunch(inForeground: true)
        await client.handleDidEnterBackground()
        await client.handleWillEnterForeground() // unchanged: nothing
        await client.handleDidEnterBackground()
        permission.set(.authorized) // the user allowed notifications
        await client.handleWillEnterForeground()
        await client.flush()

        let types = await transport.sentEvents().compactMap { $0["event_type"]?.stringValue }
        XCTAssertEqual(types, [
            "app_installed", "app_opened", "push_permission_changed",
            "app_backgrounded", "app_opened",
            "app_backgrounded", "app_opened", "push_permission_changed"
        ])
        let last = await permissionEvents(transport).last?["properties"]?.objectValue ?? [:]
        XCTAssertEqual(last["status"], "authorized")
        XCTAssertEqual(last["previous_status"], "not_determined")
    }

    func testBackgroundLaunchDoesNotReadThePermission() async throws {
        let transport = MockTransport()
        let client = makeLifecycleClient(transport: transport, pushPermission: { .denied })
        await client.handleAppLaunch(inForeground: false)
        await client.flush()

        let count = await permissionEvents(transport).count
        XCTAssertEqual(count, 0)
    }

    func testSwitchesStopTheAutomaticRead() async throws {
        for (automaticEvents, automaticPushPermission) in [(true, false), (false, true)] {
            let transport = MockTransport()
            let client = makeLifecycleClient(
                transport: transport,
                automaticEvents: automaticEvents,
                automaticPushPermission: automaticPushPermission,
                pushPermission: { .denied }
            )
            await client.handleAppLaunch(inForeground: true)
            await client.handleWillEnterForeground()
            await client.flush()
            let count = await permissionEvents(transport).count
            XCTAssertEqual(count, 0, "automaticEvents=\(automaticEvents) automaticPushPermission=\(automaticPushPermission)")

            // The manual API still sends.
            let sent = await client.pushPermissionChanged(.denied)
            XCTAssertTrue(sent)
        }
    }

    func testRefreshReturnsTheStatusRead() async throws {
        let transport = MockTransport()
        let client = makeLifecycleClient(transport: transport, pushPermission: { .provisional })
        let status = await client.refreshPushPermission()
        await client.flush()

        XCTAssertEqual(status, .provisional)
        let count = await permissionEvents(transport).count
        XCTAssertEqual(count, 1)
    }

    func testUnreadablePermissionSendsNothing() async throws {
        let transport = MockTransport()
        let client = makeLifecycleClient(transport: transport) // provider returns nil
        let status = await client.refreshPushPermission()
        XCTAssertNil(status)
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    #if os(macOS)
    func testDefaultReaderReturnsNilOutsideAnAppBundle() async {
        // swift test runs in a command-line runner, not an .app.
        let status = await WhisperrPushPermission.current()
        XCTAssertNil(status)
    }
    #endif

    #if canImport(UserNotifications)
    func testAuthorizationStatusMapping() {
        XCTAssertEqual(WhisperrPushPermissionStatus(UNAuthorizationStatus.authorized), .authorized)
        XCTAssertEqual(WhisperrPushPermissionStatus(UNAuthorizationStatus.denied), .denied)
        XCTAssertEqual(WhisperrPushPermissionStatus(UNAuthorizationStatus.notDetermined), .notDetermined)
        XCTAssertEqual(WhisperrPushPermissionStatus(UNAuthorizationStatus.provisional), .provisional)
        XCTAssertEqual(WhisperrPushPermissionStatus(UNAuthorizationStatus(rawValue: 4)!), .authorized) // ephemeral
        XCTAssertNil(WhisperrPushPermissionStatus(UNAuthorizationStatus(rawValue: 99)!))
        XCTAssertEqual(WhisperrPushPermissionStatus.notDetermined.rawValue, "not_determined")
    }
    #endif
}

/// Opens and deep links.
final class NotificationHandlingTests: XCTestCase {
    func testWhisperrDeepLinkKeyWinsOverDeepLink() {
        let payload = WhisperrPushPayload(userInfo: [
            "whisperr_message_id": "msg_1",
            "deep_link": "myapp://old",
            "data": ["whisperr_deep_link": "myapp://offers/annual"]
        ])
        XCTAssertEqual(payload?.deepLink, "myapp://offers/annual")
        XCTAssertEqual(payload?.deepLinkURL, URL(string: "myapp://offers/annual"))
    }

    func testLegacyDeepLinkKeyIsStillRead() {
        let payload = WhisperrPushPayload(userInfo: ["whisperr_message_id": "msg_1", "deep_link": "https://example.com/a"])
        XCTAssertEqual(payload?.deepLinkURL, URL(string: "https://example.com/a"))
    }

    func testDeepLinkWithoutSchemeIsNotAURL() {
        let payload = WhisperrPushPayload(userInfo: ["whisperr_message_id": "msg_1", "whisperr_deep_link": "offers/annual"])
        XCTAssertEqual(payload?.deepLink, "offers/annual")
        XCTAssertNil(payload?.deepLinkURL)
    }

    func testHandleNotificationTracksOnceAndReturnsTheLink() async throws {
        let transport = MockTransport()
        let client = makeLifecycleClient(transport: transport)
        try await client.identify("user_1")
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Your streak"]],
            "whisperr_message_id": "msg_9",
            "whisperr_deep_link": "myapp://streak"
        ]

        let first = await client.handleNotification(userInfo: userInfo)
        let second = await client.handleNotification(userInfo: userInfo)
        await client.flush()

        XCTAssertEqual(first, URL(string: "myapp://streak"))
        XCTAssertEqual(second, URL(string: "myapp://streak")) // the link again; no second event
        let events = await transport.sentEvents()
        XCTAssertEqual(events.count, 1)
        let properties = events[0]["properties"]?.objectValue ?? [:]
        XCTAssertEqual(properties["whisperr_message_id"], "msg_9")
        XCTAssertEqual(properties["deep_link"], "myapp://streak")
    }

    func testHandleNotificationIgnoresOtherProviders() async throws {
        let transport = MockTransport()
        let client = makeLifecycleClient(transport: transport)
        let url = await client.handleNotification(userInfo: ["deep_link": "myapp://news"])
        await client.flush()

        XCTAssertNil(url)
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testHandleNotificationOnAClosedClientStillReturnsTheLink() async {
        let client = makeLifecycleClient(transport: MockTransport())
        await client.close()
        let url = await client.handleNotification(WhisperrPushPayload(messageID: "m", deepLink: "myapp://x"))
        XCTAssertEqual(url, URL(string: "myapp://x"))
    }

    func testFacadeKeepsThePendingDeepLinkForTheUI() {
        _ = Whisperr.consumePendingDeepLink() // start clean
        let posted = expectation(forNotification: Whisperr.deepLinkNotification, object: nil)

        let url = Whisperr.handleNotification(userInfo: [
            "whisperr_message_id": "msg_facade",
            "whisperr_deep_link": "myapp://paywall"
        ])

        wait(for: [posted], timeout: 1)
        XCTAssertEqual(url, URL(string: "myapp://paywall"))
        XCTAssertEqual(Whisperr.consumePendingDeepLink(), URL(string: "myapp://paywall"))
        XCTAssertNil(Whisperr.consumePendingDeepLink()) // handled once
    }

    func testFacadeIgnoresNonWhisperrNotifications() {
        _ = Whisperr.consumePendingDeepLink()
        XCTAssertNil(Whisperr.handleNotification(userInfo: ["deep_link": "myapp://news"]))
        XCTAssertNil(Whisperr.consumePendingDeepLink())
    }
}
