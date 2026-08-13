import XCTest
@testable import BideKit

final class BideInviteTests: XCTestCase {

    private func makeInvite(
        destinationName: String,
        lat: Double = 37.7952,
        lng: Double = -122.2718,
        createdAt: Date = Date(timeIntervalSince1970: 1_754_000_000.125)
    ) -> BideInvite {
        BideInvite(
            bideID: UUID(uuidString: "8B5C1E7A-4D3F-4C21-9E88-0A1B2C3D4E5F")!,
            destinationName: destinationName,
            lat: lat,
            lng: lng,
            createdAt: createdAt
        )
    }

    private func assertRoundTrips(
        _ invite: BideInvite,
        _ message: String = "",
        line: UInt = #line
    ) {
        for url in [invite.webURL(), invite.appURL()] {
            guard let decoded = BideInvite(url: url) else {
                XCTFail("failed to decode \(url.absoluteString) \(message)", line: line)
                continue
            }
            XCTAssertEqual(decoded, invite, "\(url.absoluteString) \(message)", line: line)
        }
    }

    // MARK: - Round trips

    func testRoundTripPlainName() {
        assertRoundTrips(makeInvite(destinationName: "Blue Bottle Coffee"))
    }

    func testRoundTripEmoji() {
        for name in [
            "Blue Bottle ☕️",
            "🚲",
            "Pier 39 🌉🦭 sunset",
            "Family 👨‍👩‍👧‍👦 brunch",
            "🇯🇵 Izakaya",
            "Wave 👋🏽 Cafe",
        ] {
            assertRoundTrips(makeInvite(destinationName: name), name)
        }
    }

    func testRoundTripAmpersand() {
        for name in [
            "Bar & Grill",
            "Dean & DeLuca",
            "&",
            "&&&",
            "Fish & Chips & Beer",
            "A&lat=hijacked",
        ] {
            assertRoundTrips(makeInvite(destinationName: name), name)
        }
    }

    func testRoundTripNonASCII() {
        for name in [
            "Café Zoë",
            "東京タワー",
            "Þingvellir",
            "Ελληνικό καφενείο",
            "Мосты́",
            "北京烤鸭",
            "Ẓāhir",
            "مقهى",
            "e\u{0301}clair",
        ] {
            assertRoundTrips(makeInvite(destinationName: name), name)
        }
    }

    func testRoundTripURLReservedCharacters() {
        for name in [
            "50% Off",
            "A+B",
            "Coffee + Tea",
            "Suite #3",
            "lat=1&lng=2",
            "Who? Me!",
            "North/South",
            "100%%",
            "%zz",
            "?#[]@!$'()*,;:",
            "a;b=c",
        ] {
            assertRoundTrips(makeInvite(destinationName: name), name)
        }
    }

    func testRoundTripMixedName() {
        assertRoundTrips(makeInvite(destinationName: "Café ☕️ & Bar #1 — 50% off, naïve+bold 東京"))
    }

    func testRoundTripEmptyName() {
        assertRoundTrips(makeInvite(destinationName: ""))
    }

    func testRoundTripWhitespaceIsPreserved() {
        assertRoundTrips(makeInvite(destinationName: "  double  spaced  "))
        assertRoundTrips(makeInvite(destinationName: "line\nbreak\ttab"))
    }

    func testRoundTripCoordinates() {
        for (lat, lng) in [
            (0.0, 0.0),
            (37.7952, -122.2718),
            (-33.8688, 151.2093),
            (89.999999999, -179.999999999),
            (-0.0, 0.0),
            (51.477928, -0.001545),
        ] {
            assertRoundTrips(makeInvite(destinationName: "Somewhere", lat: lat, lng: lng), "\(lat),\(lng)")
        }
    }

    func testRoundTripPreservesCoordinatePrecision() {
        let invite = makeInvite(destinationName: "Precise", lat: 37.79520000000001, lng: -122.27180000000003)
        let decoded = BideInvite(url: invite.webURL())
        XCTAssertEqual(decoded?.lat, 37.79520000000001)
        XCTAssertEqual(decoded?.lng, -122.27180000000003)
    }

    func testRoundTripPreservesBideID() {
        let id = UUID()
        let invite = BideInvite(bideID: id, destinationName: "Anywhere", lat: 1, lng: 2)
        XCTAssertEqual(BideInvite(url: invite.webURL())?.bideID, id)
    }

    // MARK: - Timestamps

    func testRoundTripCreatedAtIsExact() {
        var dates: [Date] = [
            Date(timeIntervalSince1970: 0),
            Date(timeIntervalSince1970: 1_754_000_000.125),
            Date(timeIntervalSince1970: 4_000_000_000),
            Date(timeIntervalSinceReferenceDate: 0),
        ]
        for _ in 0..<200 {
            dates.append(Date())
            dates.append(Date(timeIntervalSinceNow: .random(in: -1_000_000...1_000_000)))
        }

        for date in dates {
            let invite = makeInvite(destinationName: "Now", createdAt: date)
            XCTAssertEqual(
                BideInvite(url: invite.webURL())?.createdAt,
                invite.createdAt,
                "\(date.timeIntervalSinceReferenceDate)"
            )
        }
    }

    func testInitSnapsCreatedAtToMillisecond() {
        let invite = makeInvite(destinationName: "Now", createdAt: Date(timeIntervalSince1970: 1.0004567))
        XCTAssertEqual(invite.createdAt.timeIntervalSince1970, 1.000, accuracy: 0.0000001)
        XCTAssertEqual(makeInvite(destinationName: "Now", createdAt: invite.createdAt).createdAt, invite.createdAt)
    }

    func testTimestampIsReadableISO8601() {
        let invite = makeInvite(
            destinationName: "Blue Bottle",
            createdAt: Date(timeIntervalSince1970: 1_754_000_000.125)
        )
        XCTAssertTrue(
            invite.webURL().absoluteString.contains("t=2025-07-31T22:13:20.125Z"),
            invite.webURL().absoluteString
        )
    }

    // MARK: - Public URL shape

    func testWebURLIsOnTrybideApp() {
        let url = makeInvite(destinationName: "Blue Bottle Coffee").webURL()
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "trybide.app")
        XCTAssertEqual(url.path, "/trip")
    }

    func testAppURLUsesCustomScheme() {
        let url = makeInvite(destinationName: "Blue Bottle Coffee").appURL()
        XCTAssertEqual(url.scheme, "bide")
        XCTAssertEqual(url.host, "invite")
    }

    func testDestinationAppearsFirstInTheQuery() {
        let url = makeInvite(destinationName: "Blue Bottle Coffee").webURL()
        XCTAssertTrue(
            url.absoluteString.hasPrefix("https://trybide.app/trip?to=Blue%20Bottle%20Coffee&"),
            url.absoluteString
        )
    }

    func testReadablePunctuationIsNotEscaped() {
        let url = makeInvite(destinationName: "Rudy's Bar (Annex), Nob Hill: 3rd!").webURL()
        XCTAssertTrue(url.absoluteString.contains("to=Rudy's%20Bar%20(Annex),%20Nob%20Hill:%203rd!"), url.absoluteString)
    }

    func testTypicalURLIsLegible() {
        let invite = BideInvite(
            bideID: UUID(uuidString: "8B5C1E7A-4D3F-4C21-9E88-0A1B2C3D4E5F")!,
            destinationName: "Blue Bottle Coffee",
            lat: 37.7952,
            lng: -122.2718,
            createdAt: Date(timeIntervalSince1970: 1_754_000_000.125)
        )
        XCTAssertEqual(
            invite.webURL().absoluteString,
            "https://trybide.app/trip?to=Blue%20Bottle%20Coffee&lat=37.7952&lng=-122.2718"
                + "&style=on_time&t=2025-07-31T22:13:20.125Z&id=8B5C1E7A-4D3F-4C21-9E88-0A1B2C3D4E5F"
        )
    }

    func testScheduledURLIsLegible() {
        let invite = BideInvite(
            bideID: UUID(uuidString: "8B5C1E7A-4D3F-4C21-9E88-0A1B2C3D4E5F")!,
            destinationName: "Nats Park",
            lat: 38.873,
            lng: -77.007,
            scheduledFor: Date(timeIntervalSince1970: 1_754_000_000),
            arrivalStyle: .together,
            createdAt: Date(timeIntervalSince1970: 1_754_000_000.125)
        )
        XCTAssertEqual(
            invite.webURL().absoluteString,
            "https://trybide.app/trip?to=Nats%20Park&lat=38.873&lng=-77.007"
                + "&at=2025-07-31T22:13:20.000Z&style=together"
                + "&t=2025-07-31T22:13:20.125Z&id=8B5C1E7A-4D3F-4C21-9E88-0A1B2C3D4E5F"
        )
    }

    // MARK: - Encoding safety

    func testNameCannotInjectQueryParameters() {
        let invite = makeInvite(destinationName: "X&lat=0&lng=0&id=nope")
        let url = invite.webURL()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!

        XCTAssertEqual(components.percentEncodedQueryItems?.count, 6)
        XCTAssertEqual(BideInvite(url: url)?.lat, 37.7952)
        XCTAssertEqual(BideInvite(url: url)?.destinationName, "X&lat=0&lng=0&id=nope")
    }

    func testPlusIsPercentEncoded() {
        let url = makeInvite(destinationName: "Coffee + Tea").webURL()
        XCTAssertFalse(url.absoluteString.contains("+"))
        XCTAssertTrue(url.absoluteString.contains("%2B"))
    }

    func testSemicolonIsPercentEncoded() {
        let url = makeInvite(destinationName: "a;b").webURL()
        XCTAssertTrue(url.absoluteString.contains("%3B"), url.absoluteString)
    }

    // MARK: - Payload budget

    func testTypicalPayloadIsWellUnderOneKB() {
        let url = makeInvite(destinationName: "Blue Bottle Coffee, 300 Webster St").webURL()
        XCTAssertLessThan(url.absoluteString.utf8.count, 250)
    }

    func testLongNameStaysUnderOneKB() {
        let name = String(repeating: "Very Long Cafe Name ", count: 500)
        XCTAssertLessThan(makeInvite(destinationName: name).webURL().absoluteString.utf8.count, BideInvite.maxURLByteCount)
    }

    func testLongEmojiNameStaysUnderOneKB() {
        for name in [
            String(repeating: "🚲", count: 5_000),
            String(repeating: "👨‍👩‍👧‍👦", count: 1_000),
            String(repeating: "東", count: 5_000),
            String(repeating: "&", count: 5_000),
        ] {
            let invite = makeInvite(destinationName: name)
            for url in [invite.webURL(), invite.appURL()] {
                XCTAssertLessThan(
                    url.absoluteString.utf8.count,
                    BideInvite.maxURLByteCount,
                    "\(name.prefix(1)) x \(name.count)"
                )
            }
        }
    }

    func testOverBudgetNameIsTruncatedOnCharacterBoundaries() {
        let name = String(repeating: "👨‍👩‍👧‍👦", count: 1_000)
        let invite = makeInvite(destinationName: name)
        guard let decoded = BideInvite(url: invite.webURL()) else {
            return XCTFail("truncated invite should still decode")
        }

        XCTAssertLessThan(decoded.destinationName.count, name.count)
        XCTAssertFalse(decoded.destinationName.isEmpty)
        XCTAssertTrue(name.hasPrefix(decoded.destinationName))
        XCTAssertTrue(decoded.destinationName.allSatisfy { $0 == "👨‍👩‍👧‍👦" })
        XCTAssertEqual(decoded.bideID, invite.bideID)
        XCTAssertEqual(decoded.lat, invite.lat)
        XCTAssertEqual(decoded.lng, invite.lng)
        XCTAssertEqual(decoded.createdAt, invite.createdAt)
    }

    func testNameAtTheEdgeOfTheBudgetIsNotTruncated() {
        let name = String(repeating: "a", count: 800)
        let url = makeInvite(destinationName: name).webURL()
        XCTAssertEqual(BideInvite(url: url)?.destinationName, name)
        XCTAssertLessThan(url.absoluteString.utf8.count, BideInvite.maxURLByteCount)
    }

    // MARK: - Decoding failures

    func testDecodeFailsOnMissingFields() {
        let base = makeInvite(destinationName: "Blue Bottle").webURL()
        let components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        let allItems = components.percentEncodedQueryItems!

        for dropped in allItems where ["to", "lat", "lng", "t", "id"].contains(dropped.name) {
            var stripped = components
            stripped.percentEncodedQueryItems = allItems.filter { $0.name != dropped.name }
            XCTAssertNil(BideInvite(url: stripped.url!), "decoding should fail without \(dropped.name)")
        }
    }

    func testDecodeToleratesAMissingTimeAndStyle() throws {
        let base = makeInvite(destinationName: "Blue Bottle").webURL()
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.percentEncodedQueryItems = components.percentEncodedQueryItems?
            .filter { $0.name != "style" && $0.name != "at" }

        let decoded = try XCTUnwrap(BideInvite(url: components.url!))
        XCTAssertNil(decoded.scheduledFor, "no time means asap, not a failure")
        XCTAssertEqual(decoded.arrivalStyle, .onTime, "the default the design specifies")
    }

    func testScheduledTimeRoundTrips() {
        assertRoundTrips(
            BideInvite(
                destinationName: "Nats Park",
                lat: 38.873,
                lng: -77.007,
                scheduledFor: Date(timeIntervalSince1970: 1_786_478_100.5),
                arrivalStyle: .together
            )
        )
    }

    func testDecodeFailsOnNoQueryAtAll() {
        XCTAssertNil(BideInvite(url: URL(string: "https://trybide.app/trip")!))
        XCTAssertNil(BideInvite(url: URL(string: "bide://invite")!))
    }

    func testDecodeFailsOnForeignSchemeHostOrPath() {
        let query = URLComponents(
            url: makeInvite(destinationName: "Blue Bottle").webURL(),
            resolvingAgainstBaseURL: false
        )!.percentEncodedQuery!

        for url in [
            "https://trybide.app.evil.com/trip?\(query)",
            "https://nottrybide.app/trip?\(query)",
            "https://trybide.com/trip?\(query)",
            "https://trybide.app/privacy?\(query)",
            "https://trybide.app/?\(query)",
            "http://trybide.app/trip?\(query)",
            "bide://accept?\(query)",
            "bide://tile?\(query)",
        ] {
            XCTAssertNil(BideInvite(url: URL(string: url)!), url)
        }
    }

    func testDecodeStillAcceptsTheLegacyMeetPath() {
        let invite = makeInvite(destinationName: "Blue Bottle")
        let query = URLComponents(url: invite.webURL(), resolvingAgainstBaseURL: false)!
            .percentEncodedQuery!

        XCTAssertEqual(BideInvite(url: URL(string: "https://trybide.app/meet?\(query)")!), invite)
        XCTAssertFalse(invite.webURL().absoluteString.contains("/meet"))
    }

    func testDecodeAcceptsCaseInsensitiveHost() {
        let query = URLComponents(
            url: makeInvite(destinationName: "Blue Bottle").webURL(),
            resolvingAgainstBaseURL: false
        )!.percentEncodedQuery!
        XCTAssertNotNil(BideInvite(url: URL(string: "https://TryBide.App/trip?\(query)")!))
    }

    func testDecodeFailsOnMalformedValues() {
        let id = "8B5C1E7A-4D3F-4C21-9E88-0A1B2C3D4E5F"
        let time = "2025-07-31T22:13:20.125Z"
        for query in [
            "to=Cafe&lat=1&lng=2&t=\(time)&id=not-a-uuid",
            "to=Cafe&lat=north&lng=2&t=\(time)&id=\(id)",
            "to=Cafe&lat=1&lng=west&t=\(time)&id=\(id)",
            "to=Cafe&lat=1&lng=2&t=never&id=\(id)",
            "to=Cafe&lat=1&lng=2&t=2025-07-31&id=\(id)",
            "to=Cafe&lat=1&lng=2&t=1754000000&id=\(id)",
            "to=Cafe&lat=nan&lng=2&t=\(time)&id=\(id)",
            "to=Cafe&lat=1&lng=inf&t=\(time)&id=\(id)",
            "to=%FF&lat=1&lng=2&t=\(time)&id=\(id)",
            "to=%C3%28&lat=1&lng=2&t=\(time)&id=\(id)",
        ] {
            XCTAssertNil(BideInvite(url: URL(string: "https://trybide.app/trip?\(query)")!), query)
        }
    }

    func testStrayPercentInInboundURLDecodesAsLiteral() {
        let url = URL(string: "https://trybide.app/trip?to=%E0%A4%A&lat=1&lng=2"
            + "&t=2025-07-31T22:13:20.125Z&id=8B5C1E7A-4D3F-4C21-9E88-0A1B2C3D4E5F")!
        XCTAssertEqual(BideInvite(url: url)?.destinationName, "%E0%A4%A")
    }

    // MARK: - Codable

    func testCodableRoundTrip() {
        let invite = makeInvite(destinationName: "Café ☕️ & Bar")
        let data = try! JSONEncoder().encode(invite)
        XCTAssertEqual(try! JSONDecoder().decode(BideInvite.self, from: data), invite)
    }
}
