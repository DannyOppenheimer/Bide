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

    /// Encodes and decodes through *both* wire forms — the public web URL and
    /// the private app hand-off — asserting the invite comes back identical.
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
            // Multi-scalar clusters: ZWJ sequence, flag, skin-tone modifier.
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
            // Looks like query syntax on purpose.
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
            // Right-to-left.
            "مقهى",
            // Combining marks that normalization could otherwise fold.
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

    /// `createdAt` must survive encode/decode exactly, including for a `Date`
    /// straight off the system clock — that is the one that actually ships in
    /// a tile, and it carries finer precision than a tidy literal does.
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

    /// The initializer snaps `createdAt` to the millisecond the wire carries,
    /// so an invite always equals its own decoded copy.
    func testInitSnapsCreatedAtToMillisecond() {
        let invite = makeInvite(destinationName: "Now", createdAt: Date(timeIntervalSince1970: 1.0004567))
        XCTAssertEqual(invite.createdAt.timeIntervalSince1970, 1.000, accuracy: 0.0000001)
        // Idempotent: re-wrapping an already-snapped date changes nothing.
        XCTAssertEqual(makeInvite(destinationName: "Now", createdAt: invite.createdAt).createdAt, invite.createdAt)
    }

    /// A timestamp a person can read, not an opaque epoch offset.
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
        XCTAssertEqual(url.path, "/meet")
    }

    func testAppURLUsesCustomScheme() {
        let url = makeInvite(destinationName: "Blue Bottle Coffee").appURL()
        XCTAssertEqual(url.scheme, "bide")
        XCTAssertEqual(url.host, "invite")
    }

    /// The recipient may see this URL as raw text, so the destination — the
    /// only part that means anything to them — comes before the bookkeeping.
    func testDestinationAppearsFirstInTheQuery() {
        let url = makeInvite(destinationName: "Blue Bottle Coffee").webURL()
        XCTAssertTrue(
            url.absoluteString.hasPrefix("https://trybide.app/meet?to=Blue%20Bottle%20Coffee&"),
            url.absoluteString
        )
    }

    /// Punctuation that is legal in a query stays legible rather than being
    /// escaped into noise.
    func testReadablePunctuationIsNotEscaped() {
        let url = makeInvite(destinationName: "Rudy's Bar (Annex), Nob Hill: 3rd!").webURL()
        XCTAssertTrue(url.absoluteString.contains("to=Rudy's%20Bar%20(Annex),%20Nob%20Hill:%203rd!"), url.absoluteString)
    }

    /// A whole realistic invite should still be readable at a glance.
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
            "https://trybide.app/meet?to=Blue%20Bottle%20Coffee&lat=37.7952&lng=-122.2718"
                + "&style=on_time&t=2025-07-31T22:13:20.125Z&id=8B5C1E7A-4D3F-4C21-9E88-0A1B2C3D4E5F"
        )
    }

    /// An invite with a time carries it in the same readable form, right
    /// after the coordinates.
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
            "https://trybide.app/meet?to=Nats%20Park&lat=38.873&lng=-77.007"
                + "&at=2025-07-31T22:13:20.000Z&style=together"
                + "&t=2025-07-31T22:13:20.125Z&id=8B5C1E7A-4D3F-4C21-9E88-0A1B2C3D4E5F"
        )
    }

    // MARK: - Encoding safety

    /// The whole point of escaping `&` and `=`: a hostile place name must not
    /// be able to inject or overwrite query parameters.
    func testNameCannotInjectQueryParameters() {
        let invite = makeInvite(destinationName: "X&lat=0&lng=0&id=nope")
        let url = invite.webURL()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!

        XCTAssertEqual(components.percentEncodedQueryItems?.count, 6)
        XCTAssertEqual(BideInvite(url: url)?.lat, 37.7952)
        XCTAssertEqual(BideInvite(url: url)?.destinationName, "X&lat=0&lng=0&id=nope")
    }

    /// `URLComponents` leaves `+` unescaped in query values, which a
    /// form-style decoder reads as a space. We escape it ourselves.
    func testPlusIsPercentEncoded() {
        let url = makeInvite(destinationName: "Coffee + Tea").webURL()
        XCTAssertFalse(url.absoluteString.contains("+"))
        XCTAssertTrue(url.absoluteString.contains("%2B"))
    }

    /// `;` is a parameter separator to some servers, and this URL now reaches
    /// one.
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

    /// Emoji are the worst case: four UTF-8 bytes become twelve percent-encoded
    /// characters, so a name that looks short can still blow the budget.
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

    /// Over budget the name is cut, but only on `Character` boundaries — a
    /// truncated tile should never show half an emoji.
    func testOverBudgetNameIsTruncatedOnCharacterBoundaries() {
        let name = String(repeating: "👨‍👩‍👧‍👦", count: 1_000)
        let invite = makeInvite(destinationName: name)
        guard let decoded = BideInvite(url: invite.webURL()) else {
            return XCTFail("truncated invite should still decode")
        }

        XCTAssertLessThan(decoded.destinationName.count, name.count)
        XCTAssertFalse(decoded.destinationName.isEmpty)
        XCTAssertTrue(name.hasPrefix(decoded.destinationName))
        // Every surviving cluster is intact, not a severed ZWJ sequence.
        XCTAssertTrue(decoded.destinationName.allSatisfy { $0 == "👨‍👩‍👧‍👦" })
        // Everything but the name survives truncation untouched.
        XCTAssertEqual(decoded.bideID, invite.bideID)
        XCTAssertEqual(decoded.lat, invite.lat)
        XCTAssertEqual(decoded.lng, invite.lng)
        XCTAssertEqual(decoded.createdAt, invite.createdAt)
    }

    /// A name that fits must not be touched — truncation is a last resort, not
    /// a routine trim.
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

        // Everything that identifies the bide is required. `at` and `style`
        // are not in this list on purpose — see the test below.
        for dropped in allItems where ["to", "lat", "lng", "t", "id"].contains(dropped.name) {
            var stripped = components
            stripped.percentEncodedQueryItems = allItems.filter { $0.name != dropped.name }
            XCTAssertNil(BideInvite(url: stripped.url!), "decoding should fail without \(dropped.name)")
        }
    }

    /// An asap invite carries no `at` at all, and a tile from a build that
    /// predates arrival styles carries no `style`. Neither may fail the
    /// decode: the recipient would see nothing rather than a meetup.
    func testDecodeToleratesAMissingTimeAndStyle() throws {
        let base = makeInvite(destinationName: "Blue Bottle").webURL()
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.percentEncodedQueryItems = components.percentEncodedQueryItems?
            .filter { $0.name != "style" && $0.name != "at" }

        let decoded = try XCTUnwrap(BideInvite(url: components.url!))
        XCTAssertNil(decoded.scheduledFor, "no time means asap, not a failure")
        XCTAssertEqual(decoded.arrivalStyle, .onTime, "the default the design specifies")
    }

    /// A time survives the round trip at the precision the wire format holds.
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
        XCTAssertNil(BideInvite(url: URL(string: "https://trybide.app/meet")!))
        XCTAssertNil(BideInvite(url: URL(string: "bide://invite")!))
    }

    func testDecodeFailsOnForeignSchemeHostOrPath() {
        let query = URLComponents(
            url: makeInvite(destinationName: "Blue Bottle").webURL(),
            resolvingAgainstBaseURL: false
        )!.percentEncodedQuery!

        for url in [
            // Look-alike hosts.
            "https://trybide.app.evil.com/meet?\(query)",
            "https://nottrybide.app/meet?\(query)",
            "https://trybide.com/meet?\(query)",
            // Right host, wrong page.
            "https://trybide.app/privacy?\(query)",
            "https://trybide.app/?\(query)",
            // Downgraded scheme.
            "http://trybide.app/meet?\(query)",
            // A future message kind, and the pre-BideInvite wire format.
            "bide://accept?\(query)",
            "bide://tile?\(query)",
        ] {
            XCTAssertNil(BideInvite(url: URL(string: url)!), url)
        }
    }

    /// Hostnames are case-insensitive, and this one may be retyped by hand.
    func testDecodeAcceptsCaseInsensitiveHost() {
        let query = URLComponents(
            url: makeInvite(destinationName: "Blue Bottle").webURL(),
            resolvingAgainstBaseURL: false
        )!.percentEncodedQuery!
        XCTAssertNotNil(BideInvite(url: URL(string: "https://TryBide.App/meet?\(query)")!))
    }

    func testDecodeFailsOnMalformedValues() {
        let id = "8B5C1E7A-4D3F-4C21-9E88-0A1B2C3D4E5F"
        let time = "2025-07-31T22:13:20.125Z"
        for query in [
            "to=Cafe&lat=1&lng=2&t=\(time)&id=not-a-uuid",
            "to=Cafe&lat=north&lng=2&t=\(time)&id=\(id)",
            "to=Cafe&lat=1&lng=west&t=\(time)&id=\(id)",
            "to=Cafe&lat=1&lng=2&t=never&id=\(id)",
            // A date, but not in the format the wire promises.
            "to=Cafe&lat=1&lng=2&t=2025-07-31&id=\(id)",
            "to=Cafe&lat=1&lng=2&t=1754000000&id=\(id)",
            // Non-finite coordinates would poison MKDirections.
            "to=Cafe&lat=nan&lng=2&t=\(time)&id=\(id)",
            "to=Cafe&lat=1&lng=inf&t=\(time)&id=\(id)",
            // Escapes that are syntactically valid but decode to invalid
            // UTF-8: a lone continuation byte, and a truncated sequence.
            "to=%FF&lat=1&lng=2&t=\(time)&id=\(id)",
            "to=%C3%28&lat=1&lng=2&t=\(time)&id=\(id)",
        ] {
            XCTAssertNil(BideInvite(url: URL(string: "https://trybide.app/meet?\(query)")!), query)
        }
    }

    /// A stray `%` that isn't a valid escape at all never reaches the decoder:
    /// `URL(string:)` re-encodes it to `%25` while parsing, so it arrives as a
    /// literal percent sign rather than failing the decode.
    func testStrayPercentInInboundURLDecodesAsLiteral() {
        let url = URL(string: "https://trybide.app/meet?to=%E0%A4%A&lat=1&lng=2"
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
