import XCTest
@testable import Whisperr

final class DeviceTraitsTests: XCTestCase {
    private func identifyBodies(_ transport: MockTransport) async -> [JSONValue] {
        await transport.requests.filter { $0.path == "/v1/identify" }.map(\.body)
    }

    // MARK: resolver

    func testCurrentReadsIANAZoneAndBCP47Locale() {
        let traits = DeviceTraits.current(
            timeZone: TimeZone(identifier: "Europe/Berlin")!,
            locale: Locale(identifier: "de_DE")
        )
        XCTAssertEqual(traits, ["timezone": "Europe/Berlin", "locale": "de-DE"])
    }

    func testBCP47Normalization() {
        XCTAssertEqual(DeviceTraits.bcp47("de_DE"), "de-DE")
        XCTAssertEqual(DeviceTraits.bcp47("en"), "en")
        XCTAssertEqual(DeviceTraits.bcp47("en-US"), "en-US")
        XCTAssertEqual(DeviceTraits.bcp47("zh_Hans_CN"), "zh-Hans-CN")
        XCTAssertEqual(DeviceTraits.bcp47("en_US@calendar=gregorian"), "en-US")
        XCTAssertEqual(DeviceTraits.bcp47("en_US_POSIX"), "en-US-POSIX")
        XCTAssertNil(DeviceTraits.bcp47(""))
        XCTAssertNil(DeviceTraits.bcp47("_"))
        XCTAssertNil(DeviceTraits.bcp47("und"))
        XCTAssertNil(DeviceTraits.bcp47("1234"))
    }

    func testCurrentOmitsUnresolvableLocale() {
        let traits = DeviceTraits.current(
            timeZone: TimeZone(identifier: "Asia/Tokyo")!,
            locale: Locale(identifier: "")
        )
        XCTAssertEqual(traits, ["timezone": "Asia/Tokyo"])
    }

    func testRealDeviceReportsZoneAndLocale() {
        // The host always has a zone; its locale normalizes to a BCP 47 tag.
        let traits = DeviceTraits.current()
        XCTAssertEqual(traits["timezone"], .string(TimeZone.current.identifier))
        if let tag = traits["locale"]?.stringValue {
            let pattern = try! NSRegularExpression(pattern: #"^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$"#)
            XCTAssertNotNil(pattern.firstMatch(in: tag, range: NSRange(tag.startIndex..<tag.endIndex, in: tag)), tag)
        }
    }

    // MARK: identify()

    func testIdentifyFillsDefaultsInsideTraits() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport, deviceTraits: {
            ["timezone": "Europe/Berlin", "locale": "de-DE"]
        })

        try await client.identify("user_1", traits: ["plan": "pro"])
        await client.flush()

        let bodies = await identifyBodies(transport)
        XCTAssertEqual(bodies, [.object([
            "external_user_id": .string("user_1"),
            "traits": .object(["plan": "pro", "timezone": "Europe/Berlin", "locale": "de-DE"])
        ])])
    }

    func testIdentifyOnTheRealResolverPopulatesTheHostZone() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport, deviceTraits: { DeviceTraits.current() })

        try await client.identify("user_1")
        await client.flush()

        let traits = await identifyBodies(transport).first?.objectValue?["traits"]?.objectValue
        XCTAssertEqual(traits?["timezone"], .string(TimeZone.current.identifier))
        XCTAssertEqual(traits?["locale"], DeviceTraits.current()["locale"])
    }

    func testCallerSuppliedValuesAlwaysWin() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport, deviceTraits: {
            ["timezone": "Europe/Berlin", "locale": "de-DE"]
        })

        try await client.identify("user_1", traits: ["timezone": "America/New_York", "locale": "en-GB"])
        await client.flush()

        let traits = await identifyBodies(transport).first?.objectValue?["traits"]
        XCTAssertEqual(traits, .object(["timezone": "America/New_York", "locale": "en-GB"]))
    }

    func testLegacyTimezoneAliasCountsAsCallerSupplied() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport, deviceTraits: {
            ["timezone": "Europe/Berlin", "locale": "de-DE"]
        })

        try await client.identify("user_1", traits: ["tz": "Asia/Tokyo"])
        await client.flush()

        let traits = await identifyBodies(transport).first?.objectValue?["traits"]
        XCTAssertEqual(traits, .object(["tz": "Asia/Tokyo", "locale": "de-DE"]))
    }

    func testNoTraitsKeyWhenNothingResolvesAndCallerPassesNone() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport, deviceTraits: { [:] })

        try await client.identify("user_1")
        await client.flush()

        let bodies = await identifyBodies(transport)
        XCTAssertEqual(bodies, [.object(["external_user_id": .string("user_1")])])
    }

    func testOnlyTheUnavailableKeyIsOmitted() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport, deviceTraits: { ["locale": "fr-CA"] })

        try await client.identify("user_1", traits: ["plan": "pro"])
        await client.flush()

        let traits = await identifyBodies(transport).first?.objectValue?["traits"]
        XCTAssertEqual(traits, .object(["plan": "pro", "locale": "fr-CA"]))
    }

    func testSetPushTokenPartialIdentifyStaysTraitsFree() async throws {
        let transport = MockTransport()
        let client = makeClient(transport: transport, deviceTraits: {
            ["timezone": "Europe/Berlin", "locale": "de-DE"]
        })

        try await client.identify("user_1")
        await client.flush()
        try await client.setPushToken("apns_tok_a")
        await client.flush()

        let bodies = await identifyBodies(transport)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertNotNil(bodies[0].objectValue?["traits"])
        XCTAssertEqual(bodies[1], .object([
            "external_user_id": .string("user_1"),
            "channels": .array([.object([
                "channel": .string("push"),
                "address": .string("apns_tok_a"),
                "opted_in": .bool(true)
            ])])
        ]))
    }
}
