import XCTest
@testable import Whisperr

/// Signals v3 behavior, independent of the spec fixtures (CI reads
/// whisperr-spec main, which may not have the signalsV3 section yet).
final class SignalsTests: XCTestCase {
    private static let sessionPattern = "^sess_[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"

    private func properties(_ event: [String: JSONValue]) -> [String: JSONValue] {
        event["properties"]?.objectValue ?? [:]
    }

    private func session(_ event: [String: JSONValue]) -> String? {
        event["context"]?.objectValue?["session_id"]?.stringValue
    }

    // MARK: - Session

    func testEveryEventCarriesASessionIdAndAColdStartGetsANewOne() async throws {
        let transport = MockTransport()
        let persistence = InMemoryWhisperrPersistence()
        let clock = TestClock()
        let first = makeLifecycleClient(transport: transport, persistence: persistence, clock: clock)
        await first.handleAppLaunch(inForeground: true)
        try await first.screen("Home")
        try await first.track("cart_viewed")
        try await first.track("no_props")
        clock.advance(5)
        await first.handleDidEnterBackground()
        await first.close()

        let second = makeLifecycleClient(transport: transport, persistence: persistence, clock: clock)
        await second.handleAppLaunch(inForeground: true)
        await second.flush()

        let events = await transport.sentEvents()
        XCTAssertEqual(
            events.map { $0["event_type"] },
            ["app_installed", "app_opened", "screen_viewed", "cart_viewed", "no_props", "app_backgrounded", "app_opened"]
        )
        let sessions = events.map(session)
        let firstSession = try XCTUnwrap(sessions[0])
        XCTAssertNotNil(firstSession.range(of: Self.sessionPattern, options: .regularExpression), firstSession)
        XCTAssertEqual(Array(sessions[0...5]), Array(repeating: Optional(firstSession), count: 6))
        let secondSession = try XCTUnwrap(sessions[6])
        XCTAssertNotEqual(secondSession, firstSession)
        XCTAssertNotNil(secondSession.range(of: Self.sessionPattern, options: .regularExpression))
        // A track() without properties gets no common properties.
        XCTAssertEqual(properties(events[4]), [:])

        let backgrounded = properties(events[5])
        XCTAssertEqual(backgrounded["session_id"], .string(firstSession))
        XCTAssertEqual(backgrounded["foreground_ms"], 5_000)
        XCTAssertEqual(backgrounded["screen_count"], 1)
        XCTAssertEqual(backgrounded["unique_screen_count"], 1)
        XCTAssertEqual(backgrounded["event_count"], 2)
        XCTAssertEqual(backgrounded["error_count"], 0)
    }

    func testTheSessionRollsOnlyAfter30MinutesWithoutAnEvent() async throws {
        let transport = MockTransport()
        let clock = TestClock()
        let client = makeLifecycleClient(transport: transport, clock: clock)
        try await client.track("a")
        clock.advance(29 * 60)
        try await client.track("b")
        clock.advance(30 * 60 + 1)
        try await client.track("c")
        await client.flush()

        let sessions = await transport.sentEvents().map(session)
        XCTAssertEqual(sessions.count, 3)
        XCTAssertEqual(sessions[0], sessions[1])
        XCTAssertNotEqual(sessions[1], sessions[2])
    }

    func testTheSessionRollsWhenEitherClockShowsA30MinuteGap() async throws {
        let transport = MockTransport()
        let wall = TestClock()
        let monotonic = TestClock()
        let client = WhisperrClient(
            apiKey: "wrk_test",
            baseURL: URL(string: "https://api.test")!,
            options: WhisperrOptions(flushInterval: 0, maxRetries: 0, automaticEvents: false),
            persistence: InMemoryWhisperrPersistence(),
            transport: transport,
            clock: { wall.now },
            idGenerator: { UUID().uuidString },
            sleeper: { _ in },
            deviceTraits: { [:] },
            appEnvironment: { .fixture() },
            anonymousIDGenerator: nil,
            installsLifecycleObserver: false,
            pushPermissionProvider: { nil },
            uptime: { monotonic.now.timeIntervalSince1970 },
            runMarkers: .inMemory(),
            isDebugBuild: false
        )
        try await client.track("a")
        // The device slept: the monotonic clock stood still.
        wall.advance(31 * 60)
        try await client.track("b")
        // The wall clock was set back; the monotonic clock still ran.
        wall.advance(-60 * 60)
        monotonic.advance(31 * 60)
        try await client.track("c")
        try await client.track("d")
        await client.flush()

        let sessions = await transport.sentEvents().map(session)
        XCTAssertEqual(sessions.count, 4)
        XCTAssertNotEqual(sessions[0], sessions[1])
        XCTAssertNotEqual(sessions[1], sessions[2])
        XCTAssertEqual(sessions[2], sessions[3])
    }

    func testVisitCountersResetOnEachForeground() async throws {
        let transport = MockTransport()
        let clock = TestClock()
        let client = makeLifecycleClient(transport: transport, clock: clock)
        await client.handleAppLaunch(inForeground: true)
        try await client.screen("Home")
        try await client.screen("Cart")
        try await client.screen("Home")
        try await client.track("cart_viewed")
        try await client.track("checkout_started")
        await client.trackError(CartLoadError())
        clock.advance(3)
        await client.handleDidEnterBackground()
        clock.advance(1)
        await client.handleWillEnterForeground()
        try await client.screen("Home")
        clock.advance(2)
        await client.handleDidEnterBackground()

        let backgrounded = await transport.sentEvents().filter { $0["event_type"] == "app_backgrounded" }.map(properties)
        XCTAssertEqual(backgrounded.count, 2)
        XCTAssertEqual(backgrounded[0]["screen_count"], 3)
        XCTAssertEqual(backgrounded[0]["unique_screen_count"], 2)
        XCTAssertEqual(backgrounded[0]["event_count"], 2)
        XCTAssertEqual(backgrounded[0]["error_count"], 1)
        XCTAssertEqual(backgrounded[0]["foreground_ms"], 3_000)
        XCTAssertEqual(backgrounded[1]["screen_count"], 1)
        XCTAssertEqual(backgrounded[1]["unique_screen_count"], 1)
        XCTAssertEqual(backgrounded[1]["event_count"], 0)
        XCTAssertEqual(backgrounded[1]["error_count"], 0)
        XCTAssertEqual(backgrounded[1]["foreground_ms"], 2_000)
    }

    func testForegroundTimeUsesTheMonotonicClock() async throws {
        let transport = MockTransport()
        let uptime = TestClock()
        let client = WhisperrClient(
            apiKey: "wrk_test",
            baseURL: URL(string: "https://api.test")!,
            options: WhisperrOptions(flushInterval: 0, maxRetries: 0),
            persistence: InMemoryWhisperrPersistence(),
            transport: transport,
            // The wall clock jumps back an hour; foreground_ms does not.
            clock: { Date(timeIntervalSince1970: 1_780_229_600 - (uptime.now.timeIntervalSince1970 - 1_780_229_600) * 720) },
            idGenerator: { UUID().uuidString },
            sleeper: { _ in },
            deviceTraits: { [:] },
            appEnvironment: { .fixture() },
            anonymousIDGenerator: nil,
            installsLifecycleObserver: false,
            pushPermissionProvider: { nil },
            uptime: { uptime.now.timeIntervalSince1970 },
            runMarkers: .inMemory(),
            isDebugBuild: false
        )
        await client.handleAppLaunch(inForeground: true)
        uptime.advance(5)
        await client.handleDidEnterBackground()
        let backgrounded = await transport.sentEvents().first { $0["event_type"] == "app_backgrounded" }
        XCTAssertEqual(backgrounded.map(properties)?["foreground_ms"], 5_000)
    }

    // MARK: - app_opened

    func testAppOpenedIsDirectAndFlagsTheFirstOpenAfterAnUpdate() async throws {
        let transport = MockTransport()
        let persistence = InMemoryWhisperrPersistence()
        let first = makeLifecycleClient(transport: transport, persistence: persistence, environment: .fixture(version: "1.4.0", build: "140"))
        await first.handleAppLaunch(inForeground: true)
        await first.handleDidEnterBackground()
        await first.close()
        let second = makeLifecycleClient(transport: transport, persistence: persistence, environment: .fixture(version: "1.5.0", build: "150"))
        await second.handleAppLaunch(inForeground: true)
        await second.handleDidEnterBackground()
        await second.handleWillEnterForeground()
        await second.flush()

        let opens = await transport.sentEvents().filter { $0["event_type"] == "app_opened" }.map(properties)
        XCTAssertEqual(opens.map { $0["launch_source"] }, ["direct", "direct", "direct"])
        XCTAssertEqual(opens.map { $0["first_after_update"] }, [nil, true, nil])
        XCTAssertEqual(opens.map { $0["cold_start"] }, [true, true, false])
    }

    func testABackgroundLaunchSendsTheColdOpenAtTheFirstForeground() async throws {
        let transport = MockTransport()
        let client = makeLifecycleClient(transport: transport)
        await client.handleAppLaunch(inForeground: false)
        await client.handleWillEnterForeground()
        await client.flush()

        let events = await transport.sentEvents()
        XCTAssertEqual(events.map { $0["event_type"] }, ["app_installed", "app_opened"])
        XCTAssertEqual(properties(events[1])["cold_start"], true)
    }

    func testALaunchFromAPushSendsLaunchSourcePushBeforePushOpened() async throws {
        let transport = MockTransport()
        let client = makeLifecycleClient(transport: transport)
        await client.handleAppLaunch(inForeground: true)
        let payload = try XCTUnwrap(WhisperrPushPayload(
            userInfo: ["whisperr_message_id": "msg_8a01"],
            actionID: nil,
            coldStart: true
        ))
        _ = await client.handleNotification(payload)
        // A link after the push loses: push has the higher precedence.
        await client.recordLaunchURL(URL(string: "https://shop.example.com/cart?utm_source=ads")!)
        await client.flush()

        let events = await transport.sentEvents()
        XCTAssertEqual(events.map { $0["event_type"] }, ["app_installed", "app_opened", "push_opened"])
        let opened = properties(events[1])
        XCTAssertEqual(opened["launch_source"], "push")
        XCTAssertEqual(opened["whisperr_message_id"], "msg_8a01")
        XCTAssertNil(opened["link_route"])
        XCTAssertNil(opened["utm_source"])
    }

    func testALinkAfterTheFlushNoLongerChangesTheOpen() async throws {
        let transport = MockTransport()
        let client = makeLifecycleClient(transport: transport)
        await client.handleAppLaunch(inForeground: true)
        await client.flush()
        await client.recordLaunchURL(URL(string: "myapp://home?wsrc=widget")!)
        await client.flush()

        let opened = await transport.sentEvents().first { $0["event_type"] == "app_opened" }
        XCTAssertEqual(opened.map(properties)?["launch_source"], "direct")
    }

    func testLinkSignals() throws {
        let universal = try XCTUnwrap(WhisperrLaunchSignal.link(URL(string:
            "https://Shop.example.com/orders/12345/items/3f2c9a1e-8b7d-4c6e-9f00-1a2b3c4d5e6f/review/Zx9QmT4pLw8KvR2nB7?token=abc123&utm_source=newsletter&utm_medium=email&utm_campaign=spring_sale#top"
        )!))
        XCTAssertEqual(universal.source, .universalLink)
        XCTAssertEqual(universal.properties, [
            "link_host": "shop.example.com",
            "link_route": "/orders/:id/items/:id/review/:id",
            "utm_source": "newsletter",
            "utm_medium": "email",
            "utm_campaign": "spring_sale"
        ])

        let deep = try XCTUnwrap(WhisperrLaunchSignal.link(URL(string: "myapp://magic/Zx9QmT4pLw8KvR2nB7?next=%2Fhome")!))
        XCTAssertEqual(deep.source, .deepLink)
        XCTAssertEqual(deep.properties, ["link_route": "/magic/:id"])

        let widget = try XCTUnwrap(WhisperrLaunchSignal.link(URL(string: "myapp://home?wsrc=widget")!))
        XCTAssertEqual(widget.source, .widget)
        XCTAssertEqual(widget.properties, ["link_route": "/home"])

        let shortcut = try XCTUnwrap(WhisperrLaunchSignal.link(URL(string: "https://app.example.com/?wsrc=shortcut")!))
        XCTAssertEqual(shortcut.source, .shortcut)
        XCTAssertEqual(shortcut.properties, ["link_host": "app.example.com", "link_route": "/"])

        let email = try XCTUnwrap(WhisperrLaunchSignal.link(URL(string: "https://shop.example.com/cart?wmid=msg_e77&utm_source=whisperr")!))
        XCTAssertEqual(email.source, .email)
        XCTAssertEqual(email.properties, [
            "link_host": "shop.example.com",
            "link_route": "/cart",
            "utm_source": "whisperr",
            "whisperr_message_id": "msg_e77"
        ])
    }

    // MARK: - push_permission_changed

    func testAPermissionReadSendsTheNotificationSettings() async throws {
        let transport = MockTransport()
        let client = makeLifecycleClient(
            transport: transport,
            pushPermission: { .authorized },
            pushPermissionDetails: {
                ["alerts_enabled": true, "lock_screen": false, "scheduled_summary": true, "time_sensitive": false]
            }
        )
        await client.refreshPushPermission()
        await client.pushPermissionChanged(.denied)
        await client.flush()

        let changes = await transport.sentEvents().filter { $0["event_type"] == "push_permission_changed" }.map(properties)
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes[0]["status"], "authorized")
        XCTAssertEqual(changes[0]["alerts_enabled"], true)
        XCTAssertEqual(changes[0]["lock_screen"], false)
        XCTAssertEqual(changes[0]["scheduled_summary"], true)
        XCTAssertEqual(changes[0]["time_sensitive"], false)
        // A status the app reports itself carries no settings.
        XCTAssertEqual(changes[1]["status"], "denied")
        XCTAssertNil(changes[1]["alerts_enabled"])
    }

    // MARK: - app_error

    func testFingerprintVectors() {
        XCTAssertEqual(
            WhisperrSignals.fingerprint(name: "CartLoadError", frames: ["loadCart", "CartScreen", "renderWithHooks", "commitRoot"]),
            "0d3722bb489587fd"
        )
        XCTAssertEqual(WhisperrSignals.fingerprint(name: "TypeError", frames: ["fetchOffers"]), "92321c219d3e65b9")
        XCTAssertEqual(WhisperrSignals.fingerprint(name: "HTTP_500", frames: []), "84a5d0525e3659d3")
    }

    func testSHA256() {
        XCTAssertEqual(WhisperrSignals.sha256Hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(WhisperrSignals.sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            WhisperrSignals.sha256Hex(String(repeating: "a", count: 1_000)),
            "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3"
        )
    }

    func testFrameNamesDropImageAddressAndOffset() {
        XCTAssertEqual(
            WhisperrSignals.frameName("3   MyApp                0x0000000100abc123 $s5MyApp4loadyyF + 52"),
            "$s5MyApp4loadyyF"
        )
        XCTAssertEqual(
            WhisperrSignals.frameName("1   libobjc.A.dylib     0x0000000180abc123 objc_exception_throw + 60"),
            "objc_exception_throw"
        )
    }

    func testTrackErrorSendsTheTypeNameNeverTheMessage() async throws {
        let transport = MockTransport()
        let client = makeLifecycleClient(transport: transport)
        try await client.screen("Offers")
        await client.trackError(CartLoadError())
        await client.trackError(NSError(domain: "NSURLErrorDomain", code: -1009, userInfo: [NSLocalizedDescriptionKey: "secret"]), screen: "Checkout", kind: .network)
        await client.flush()

        let errors = await transport.sentEvents().filter { $0["event_type"] == "app_error" }
        XCTAssertEqual(errors.count, 2)
        let first = properties(errors[0])
        XCTAssertEqual(first["error_name"], "CartLoadError")
        XCTAssertEqual(first["error_kind"], "handled")
        XCTAssertEqual(first["fatal"], false)
        XCTAssertEqual(first["screen_name"], "Offers")
        XCTAssertEqual(first["fingerprint"], .string(WhisperrSignals.fingerprint(name: "CartLoadError", frames: [])))
        XCTAssertEqual(first["session_id"], errors[0]["context"]?.objectValue?["session_id"])
        let second = properties(errors[1])
        XCTAssertEqual(second["error_name"], "NSURLErrorDomain_-1009")
        XCTAssertEqual(second["error_kind"], "network")
        XCTAssertEqual(second["screen_name"], "Checkout")
        for error in errors {
            XCTAssertFalse("\(error)".contains("secret"))
        }
    }

    func testAppErrorDedupesByFingerprintAndCapsAt20PerSession() async throws {
        let transport = MockTransport()
        let clock = TestClock()
        let client = makeLifecycleClient(transport: transport, clock: clock)
        await client.handleAppLaunch(inForeground: true)
        await client.recordError(name: "CartLoadError", frames: [], kind: "handled", fatal: false, screen: nil)
        await client.recordError(name: "CartLoadError", frames: [], kind: "handled", fatal: false, screen: nil)
        for index in 1...20 {
            await client.recordError(name: "SyncError\(index)", frames: [], kind: "handled", fatal: false, screen: nil)
        }
        let queuedBeforeFlush = await transport.sentEvents().count
        XCTAssertEqual(queuedBeforeFlush, 0, "app_error never flushes on its own")
        clock.advance(1)
        await client.handleDidEnterBackground()

        let events = await transport.sentEvents()
        let errors = events.filter { $0["event_type"] == "app_error" }.map(properties)
        XCTAssertEqual(errors.count, 20)
        XCTAssertEqual(errors.first?["error_name"], "CartLoadError")
        XCTAssertEqual(errors.last?["error_name"], "SyncError19")
        let backgrounded = events.first { $0["event_type"] == "app_backgrounded" }.map(properties)
        XCTAssertEqual(backgrounded?["error_count"], 22)
    }

    func testCaptureErrorsOffIgnoresUncaughtErrorsButNotTrackError() async throws {
        let transport = MockTransport()
        let client = makeLifecycleClient(transport: transport, captureErrors: false)
        await client.handleUncaughtError(name: "OffersRenderError", frames: [], fatal: false)
        await client.trackError(CartLoadError())
        await client.flush()

        let errors = await transport.sentEvents().filter { $0["event_type"] == "app_error" }.map(properties)
        XCTAssertEqual(errors.map { $0["error_name"] }, ["CartLoadError"])
    }

    #if canImport(ObjectiveC)
    func testTheExceptionHandlerReportsAFatalErrorAndCallsThePreviousHandler() async throws {
        let original = NSGetUncaughtExceptionHandler()
        defer {
            NSSetUncaughtExceptionHandler(original)
            WhisperrErrorCapture.shared.resetForTesting()
        }
        PreviousHandlerProbe.shared.reset()
        NSSetUncaughtExceptionHandler { _ in PreviousHandlerProbe.shared.record() }
        WhisperrErrorCapture.shared.resetForTesting()

        let transport = MockTransport()
        let markers = WhisperrRunMarkerStore.inMemory()
        let client = makeLifecycleClient(transport: transport, runMarkers: markers)
        await client.handleAppLaunch(inForeground: true)
        try await client.screen("Checkout")
        WhisperrErrorCapture.shared.attach(client, runMarkers: markers)

        let handler = try XCTUnwrap(NSGetUncaughtExceptionHandler())
        handler(NSException(name: NSExceptionName("CheckoutStateError"), reason: "secret", userInfo: nil))
        XCTAssertEqual(PreviousHandlerProbe.shared.calls, 1, "the handler installed before the SDK still runs")
        XCTAssertEqual(markers.load()?.fatal, true)

        await client.flush()
        let error = await transport.sentEvents().first { $0["event_type"] == "app_error" }.map(properties)
        XCTAssertEqual(error?["error_name"], "CheckoutStateError")
        XCTAssertEqual(error?["error_kind"], "native")
        XCTAssertEqual(error?["fatal"], true)
        XCTAssertEqual(error?["screen_name"], "Checkout")
    }
    #endif

    // MARK: - app_crashed

    func testAnUncleanShutdownSendsAppCrashedBeforeTheNextAppOpened() async throws {
        let transport = MockTransport()
        let persistence = InMemoryWhisperrPersistence()
        let markers = WhisperrRunMarkerStore.inMemory()
        let first = makeLifecycleClient(transport: transport, persistence: persistence, runMarkers: markers)
        await first.handleAppLaunch(inForeground: true)
        try await first.screen("Checkout")
        await first.close() // killed in the foreground

        let second = makeLifecycleClient(transport: transport, persistence: persistence, runMarkers: markers)
        await second.handleAppLaunch(inForeground: true)
        await second.flush()

        let events = await transport.sentEvents()
        XCTAssertEqual(
            events.map { $0["event_type"] },
            ["app_installed", "app_opened", "screen_viewed", "app_crashed", "app_opened"]
        )
        let crashed = properties(events[3])
        XCTAssertEqual(crashed["crash_kind"], "abnormal_exit")
        XCTAssertEqual(crashed["detected_by"], "unclean_shutdown")
        XCTAssertEqual(crashed["foreground"], true)
        XCTAssertEqual(crashed["crashed_app_version"], "1.2.0")
        XCTAssertEqual(crashed["crashed_screen_name"], "Checkout")
        XCTAssertEqual(crashed["crashed_session_id"]?.stringValue, session(events[0]))
        XCTAssertEqual(session(events[3]), session(events[4]))
        XCTAssertNotEqual(session(events[3]), session(events[0]))
    }

    func testAFatalExceptionUpgradesAppCrashedToCrash() async throws {
        let transport = MockTransport()
        let persistence = InMemoryWhisperrPersistence()
        let markers = WhisperrRunMarkerStore.inMemory()
        let first = makeLifecycleClient(transport: transport, persistence: persistence, runMarkers: markers)
        await first.handleAppLaunch(inForeground: true)
        await first.handleUncaughtError(name: "CheckoutStateError", frames: [], fatal: true)
        await first.close()

        let second = makeLifecycleClient(transport: transport, persistence: persistence, runMarkers: markers)
        await second.handleAppLaunch(inForeground: true)
        await second.flush()

        let crashed = await transport.sentEvents().first { $0["event_type"] == "app_crashed" }.map(properties)
        XCTAssertEqual(crashed?["crash_kind"], "crash")
        XCTAssertEqual(crashed?["detected_by"], "native_exception")
    }

    func testABackgroundTerminationIsNotACrash() async throws {
        let transport = MockTransport()
        let persistence = InMemoryWhisperrPersistence()
        let markers = WhisperrRunMarkerStore.inMemory()
        let first = makeLifecycleClient(transport: transport, persistence: persistence, runMarkers: markers)
        await first.handleAppLaunch(inForeground: true)
        await first.handleDidEnterBackground()
        await first.close()

        let second = makeLifecycleClient(transport: transport, persistence: persistence, runMarkers: markers)
        await second.handleAppLaunch(inForeground: true)
        await second.flush()

        let types = await transport.sentEvents().map { $0["event_type"] }
        XCTAssertFalse(types.contains("app_crashed"))
    }

    func testADebugBuildNeverSendsAppCrashed() async throws {
        let transport = MockTransport()
        let persistence = InMemoryWhisperrPersistence()
        let markers = WhisperrRunMarkerStore.inMemory()
        let first = makeLifecycleClient(transport: transport, persistence: persistence, runMarkers: markers, isDebugBuild: true)
        await first.handleAppLaunch(inForeground: true)
        await first.close()

        let second = makeLifecycleClient(transport: transport, persistence: persistence, runMarkers: markers, isDebugBuild: true)
        await second.handleAppLaunch(inForeground: true)
        await second.flush()

        let types = await transport.sentEvents().map { $0["event_type"] }
        XCTAssertEqual(types, ["app_installed", "app_opened", "app_opened"])
        XCTAssertNotNil(markers.load(), "the new foreground visit has its own marker")
    }

    func testTheRunMarkerSurvivesInUserDefaults() throws {
        let suite = "net.whisperr.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        WhisperrRunMarkerStore(defaults: defaults).save(WhisperrRunMarker(sessionID: "sess_1", screen: "Home", appVersion: "1.0", fatal: nil))
        WhisperrRunMarkerStore(defaults: defaults).markFatal()
        XCTAssertEqual(
            WhisperrRunMarkerStore(defaults: defaults).load(),
            WhisperrRunMarker(sessionID: "sess_1", screen: "Home", appVersion: "1.0", fatal: true)
        )
    }
}

private struct CartLoadError: Error {}

/// Records calls from a C exception handler (which cannot capture context).
final class PreviousHandlerProbe: @unchecked Sendable {
    static let shared = PreviousHandlerProbe()
    private let lock = NSLock()
    private var count = 0

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        count = 0
    }

    func record() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
