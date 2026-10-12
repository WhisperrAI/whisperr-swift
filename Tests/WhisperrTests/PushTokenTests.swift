import XCTest
@testable import Whisperr

/// APNs / FCM token capture with kind, platform and push_env, and the dedupe
/// on token fields.
final class PushTokenTests: XCTestCase {
    private let apnsBytes = Data([0xA1, 0xB2, 0x0C, 0xFF] + Array(repeating: UInt8(0x01), count: 28))
    private var apnsHex: String {
        "a1b20cff" + String(repeating: "01", count: 28)
    }

    private func pushEntries(_ transport: MockTransport) async -> [[String: JSONValue]] {
        await transport.requests
            .filter { $0.path == "/v1/identify" }
            .compactMap { $0.body.objectValue?["channels"]?.arrayValue }
            .map { $0.compactMap(\.objectValue) }
            .flatMap { $0 }
    }

    private func identifyBodies(_ transport: MockTransport) async -> [JSONValue] {
        await transport.requests.filter { $0.path == "/v1/identify" }.map(\.body)
    }

    func testDeviceTokenSendsLowercaseHexWithAPNsKindPlatformEnvironmentAndBundleID() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport, environment: .device)
        try await client.identify("user_1")

        try await client.setPushToken(apnsBytes, environment: .production)
        await client.flush()

        let entries = await pushEntries(transport)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0], [
            "channel": "push",
            "address": .string(apnsHex),
            "opted_in": true,
            "kind": "apns",
            "platform": "ios",
            "push_env": "production",
            "client_app_id": "com.example.app"
        ])
        XCTAssertEqual(apnsHex.count, 64)
    }

    func testDeviceTokenWithoutOverrideUsesTheDetectedEnvironment() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport, environment: .device)
        try await client.identify("user_1")

        try await client.setPushToken(deviceToken: apnsBytes) // 0.3.x label
        await client.flush()

        let entries = await pushEntries(transport)
        XCTAssertEqual(entries.first?["push_env"], "sandbox")
        XCTAssertEqual(entries.first?["kind"], "apns")
    }

    func testRealEnvironmentReadsTheDetectedPushFields() {
        let environment = AppEnvironment.current()
        XCTAssertEqual(environment.apnsEnvironment, WhisperrPushEnvironment.current)
        XCTAssertEqual(environment.pushPlatform, WhisperrPushPlatform.current)
        XCTAssertEqual(environment.clientAppID, Bundle.main.bundleIdentifier)
    }

    func testFCMTokenSendsFCMKind() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport)
        try await client.identify("user_1")

        try await client.setPushToken(fcmToken: "fcm_tok_a")
        await client.flush()

        let entries = await pushEntries(transport)
        XCTAssertEqual(entries.first?["kind"], "fcm")
        XCTAssertEqual(entries.first?["address"], "fcm_tok_a")
        XCTAssertNil(entries.first?["push_env"])
    }

    func testBareStringTokenSendsNoTokenFields() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport)
        try await client.identify("user_1")

        try await client.setPushToken("ExponentPushToken[abc]")
        await client.flush()

        let entries = await pushEntries(transport)
        XCTAssertEqual(entries, [["channel": "push", "address": "ExponentPushToken[abc]", "opted_in": true]])
    }

    func testSameTokenAndFieldsIsANoOpIncludingAfterRestart() async throws {
        let transport = MockTransport()
        let persistence = InMemoryWhisperrPersistence()
        let first = makeClient(transport: transport, persistence: persistence)
        try await first.identify("user_1")
        try await first.setPushToken(apnsBytes, environment: .sandbox)
        try await first.setPushToken(apnsBytes, environment: .sandbox)
        // A bare-string call with the same token sets no new field: no-op.
        try await first.setPushToken(apnsHex)
        await first.close()

        let second = makeClient(transport: transport, persistence: persistence)
        try await second.setPushToken(apnsBytes, environment: .sandbox)
        await second.flush()

        let entries = await pushEntries(transport)
        XCTAssertEqual(entries.count, 1)
    }

    func testEnvironmentChangeOnSameTokenResendsWithoutOptOut() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport)
        try await client.identify("user_1")
        try await client.setPushToken(apnsBytes, environment: .sandbox)
        try await client.setPushToken(apnsBytes, environment: .production)
        await client.flush()

        let entries = await pushEntries(transport)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map { $0["push_env"] }, ["sandbox", "production"])
        // The same address is never opted out.
        XCTAssertFalse(entries.contains { $0["opted_in"] == false })
    }

    /// An install upgraded from 0.3.x has the (user, token) pair persisted but
    /// no token fields. The first APNs capture after the upgrade must send the
    /// fields once (the APNs sender needs push_env), and never opt the same
    /// token out.
    func testUpgradeFromStateWithoutTokenFieldsSendsTheFieldsOnce() async throws {
        let legacy = PersistedState(userID: "user_1", lastPushUserID: "user_1", lastPushToken: apnsHex)
        let persistence = InMemoryWhisperrPersistence(data: try JSONEncoder.whisperr.encode(legacy))
        let transport = MockTransport()
        let client = makeClient(transport: transport, persistence: persistence)

        try await client.setPushToken(apnsBytes, environment: .production)
        try await client.setPushToken(apnsBytes, environment: .production)
        await client.flush()

        // One registration, then the restore identify for the stored user
        // (queued at the flush).
        let bodies = await identifyBodies(transport)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertNil(bodies[1].objectValue?["channels"])
        let entries = await pushEntries(transport)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["address"], .string(apnsHex))
        XCTAssertEqual(entries[0]["opted_in"], true)
        XCTAssertEqual(entries[0]["push_env"], "production")
    }

    func testTokenSetBeforeIdentifyKeepsItsFieldsWhenAttachedToTheUser() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport)
        try await client.setPushToken(apnsBytes, environment: .sandbox)
        try await client.identify("user_1")
        await client.flush()

        // Sent anonymously at once, then attached to the user's identify.
        let bodies = await identifyBodies(transport)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertNotNil(bodies[0].objectValue?["anonymous_id"])
        XCTAssertNil(bodies[0].objectValue?["external_user_id"])
        XCTAssertEqual(bodies[1].objectValue?["external_user_id"], "user_1")
        let entries = await pushEntries(transport)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map { $0["kind"] }, ["apns", "apns"])
        XCTAssertEqual(entries.map { $0["push_env"] }, ["sandbox", "sandbox"])

        // The identify recorded the fields: the same capture is a no-op.
        try await client.setPushToken(apnsBytes, environment: .sandbox)
        await client.flush()
        let after = await pushEntries(transport)
        XCTAssertEqual(after.count, 2)
    }

    func testRotationOptOutCarriesNoTokenFields() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport)
        try await client.identify("user_1")
        try await client.setPushToken(apnsBytes, environment: .sandbox)
        let rotated = Data(repeating: 0x02, count: 32)
        try await client.setPushToken(rotated, environment: .sandbox)
        await client.flush()

        let entries = await pushEntries(transport)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[1], ["channel": "push", "address": .string(apnsHex), "opted_in": false])
        XCTAssertEqual(entries[2]["address"], .string(String(repeating: "02", count: 32)))
        XCTAssertEqual(entries[2]["kind"], "apns")
    }

    func testResetMovesTheTokenWithItsFields() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport)
        try await client.identify("user_1")
        try await client.setPushToken(apnsBytes, environment: .sandbox)
        await client.reset()
        try await client.identify("user_1")
        try await client.setPushToken(apnsBytes, environment: .sandbox)
        await client.flush()

        // Registration, opt-out under the old user (no fields), anonymous
        // opt-in with the fields, attached to the next identify; the last
        // capture is a no-op.
        let entries = await pushEntries(transport)
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries.map { $0["opted_in"] }, [true, false, true, true])
        XCTAssertEqual(entries.map { $0["push_env"] }, ["sandbox", nil, "sandbox", "sandbox"])
    }

    func testChannelBodyDropsTokenFieldsOnNonPushChannels() {
        let channel = WhisperrChannel(type: .email, address: "a@b.c", kind: .fcm, platform: .ios, pushEnvironment: .sandbox)
        XCTAssertEqual(channel.body, ["channel": "email", "address": "a@b.c"])
    }
}

/// The APNs environment detection.
final class PushEnvironmentResolverTests: XCTestCase {
    private func profile(entitlements: String) -> Data {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Name</key><string>Test Profile</string>
            <key>Entitlements</key>
            <dict>\(entitlements)</dict>
        </dict>
        </plist>
        """
        // The plist sits inside a binary CMS envelope.
        return Data([0x30, 0x82, 0x0F, 0x00, 0x06, 0x09]) + Data(plist.utf8) + Data([0xA0, 0x82, 0x00, 0xFF])
    }

    func testDevelopmentProfileIsSandbox() {
        let data = profile(entitlements: "<key>aps-environment</key><string>development</string>")
        XCTAssertEqual(PushEnvironmentResolver.apsEnvironment(inProfile: data), .sandbox)
        XCTAssertEqual(PushEnvironmentResolver.resolve(profile: data, isSimulator: false, isDebugBuild: false), .sandbox)
    }

    func testProductionProfileWinsOverADebugBuild() {
        let data = profile(entitlements: "<key>aps-environment</key><string>production</string>")
        XCTAssertEqual(PushEnvironmentResolver.resolve(profile: data, isSimulator: false, isDebugBuild: true), .production)
    }

    func testMacEntitlementKeyIsRead() {
        let data = profile(entitlements: "<key>com.apple.developer.aps-environment</key><string>development</string>")
        XCTAssertEqual(PushEnvironmentResolver.apsEnvironment(inProfile: data), .sandbox)
    }

    func testProfileWithoutPushEntitlementFallsBackToTheBuild() {
        let data = profile(entitlements: "<key>get-task-allow</key><true/>")
        XCTAssertNil(PushEnvironmentResolver.apsEnvironment(inProfile: data))
        XCTAssertEqual(PushEnvironmentResolver.resolve(profile: data, isSimulator: false, isDebugBuild: true), .sandbox)
        XCTAssertEqual(PushEnvironmentResolver.resolve(profile: data, isSimulator: false, isDebugBuild: false), .production)
    }

    func testNoProfileFallbacks() {
        XCTAssertEqual(PushEnvironmentResolver.resolve(profile: nil, isSimulator: true, isDebugBuild: false), .sandbox)
        XCTAssertEqual(PushEnvironmentResolver.resolve(profile: nil, isSimulator: false, isDebugBuild: true), .sandbox)
        // App Store and TestFlight builds carry no profile and are not DEBUG.
        XCTAssertEqual(PushEnvironmentResolver.resolve(profile: nil, isSimulator: false, isDebugBuild: false), .production)
    }

    func testGarbageProfileIsIgnored() {
        XCTAssertNil(PushEnvironmentResolver.apsEnvironment(inProfile: Data([0x00, 0x01, 0x02])))
        XCTAssertNil(PushEnvironmentResolver.apsEnvironment(inProfile: Data("<?xml broken".utf8)))
    }
}
