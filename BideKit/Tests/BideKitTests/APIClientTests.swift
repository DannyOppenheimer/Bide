import XCTest
@testable import BideKit

// MARK: - Doubles

/// Serves canned responses in order and records what it was asked for.
private actor StubTransport: HTTPTransport {

    struct Stub {
        var status: Int = 200
        var json: String = "[]"
        var headers: [String: String] = [:]
    }

    private var remaining: [Stub]
    private(set) var received: [URLRequest] = []

    init(_ stubs: [Stub]) {
        remaining = stubs
    }

    init(status: Int = 200, json: String = "[]", headers: [String: String] = [:]) {
        remaining = [Stub(status: status, json: json, headers: headers)]
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        received.append(request)
        guard !remaining.isEmpty else {
            throw APIError.invalidResponse("stub transport ran out of responses")
        }
        let stub = remaining.removeFirst()
        guard
            let url = request.url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: stub.status,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
            )
        else {
            throw APIError.invalidResponse("could not build a stub response")
        }
        return (Data(stub.json.utf8), response)
    }
}

/// Fails the request before it is ever sent.
private struct FailingTransport: HTTPTransport {
    let error: any Error
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw error
    }
}

private struct StubSessionProvider: BideSessionProvider {
    var session: BideSession?
    func currentSession() async throws(APIError) -> BideSession {
        guard let session else { throw APIError.notAuthenticated }
        return session
    }
}

// MARK: - Tests

final class APIClientTests: XCTestCase {

    private let userID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let otherUserID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let bideID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!

    private var configuration: SupabaseConfiguration {
        guard let configuration = SupabaseConfiguration(
            projectURL: "https://abcdefgh.supabase.co",
            anonKey: "anon-key"
        ) else {
            preconditionFailure("test configuration should be valid")
        }
        return configuration
    }

    private func makeClient(
        transport: any HTTPTransport,
        signedIn: Bool = true
    ) -> SupabaseAPIClient {
        SupabaseAPIClient(
            configuration: configuration,
            sessionProvider: StubSessionProvider(
                session: signedIn ? BideSession(userID: userID, accessToken: "jwt-token") : nil
            ),
            transport: transport
        )
    }

    /// A bide with both people in it, shaped exactly as PostgREST returns an
    /// embedded resource — including the six fractional digits Postgres emits.
    private var bideJSON: String {
        """
        [{"id":"AAAAAAAA-0000-0000-0000-000000000001",
          "destination_name":"Blue Bottle Coffee",
          "lat":37.7952,"lng":-122.2718,
          "scheduled_for":"2026-08-11T20:00:00+00:00",
          "arrival_style":"on_time","is_solo":false,
          "created_at":"2026-08-11T19:43:25.205123+00:00",
          "created_by":"11111111-1111-1111-1111-111111111111",
          "participants":[
            {"user_id":"11111111-1111-1111-1111-111111111111","display_name":"Ada","mode":"walking",
             "eta_timestamp":"2026-08-11T19:55:00+00:00",
             "baseline_eta":"2026-08-11T19:53:00+00:00",
             "updated_at":"2026-08-11T19:43:25.5+00:00","status":"accepted"},
            {"user_id":"22222222-2222-2222-2222-222222222222","mode":"driving",
             "eta_timestamp":null,
             "updated_at":"2026-08-11T19:44:00.741882+00:00","status":"accepted"}]}]
        """
    }

    private func queryItems(of request: URLRequest) -> [String: String] {
        guard
            let url = request.url,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let items = components.queryItems
        else { return [:] }
        return Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } }) { first, _ in first }
    }

    private func body(of request: URLRequest) -> [String: Any] {
        guard
            let data = request.httpBody,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    // MARK: Timestamps

    /// Postgres emits a variable number of fractional digits — none, one, or
    /// six — and every one of them has to parse.
    func testPostgresTimestampParsesEveryFormatPostgresEmits() throws {
        let expected = Date(timeIntervalSince1970: 1_786_477_405.205)
        for string in [
            "2026-08-11T19:43:25.205123+00:00",
            "2026-08-11T19:43:25.205+00:00",
            "2026-08-11T19:43:25.205Z",
            "2026-08-11T12:43:25.205-07:00",
        ] {
            let parsed = try XCTUnwrap(PostgresTimestamp.date(from: string), string)
            XCTAssertEqual(parsed.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.0005, string)
        }

        // No fractional part at all — the case `.withFractionalSeconds` rejects.
        let whole = try XCTUnwrap(PostgresTimestamp.date(from: "2026-08-11T19:43:25+00:00"))
        XCTAssertEqual(whole.timeIntervalSince1970, 1_786_477_405, accuracy: 0.0005)
    }

    func testPostgresTimestampRejectsNonsense() {
        for string in ["", "not a date", "2026-08-11", "1786477405"] {
            XCTAssertNil(PostgresTimestamp.date(from: string), string)
        }
    }

    func testPostgresTimestampRoundTrips() throws {
        let date = Date(timeIntervalSince1970: 1_786_477_405.205)
        let string = PostgresTimestamp.string(from: date)
        XCTAssertTrue(string.hasSuffix("Z"), string)
        let parsed = try XCTUnwrap(PostgresTimestamp.date(from: string))
        XCTAssertEqual(parsed.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.0005)
    }

    // MARK: fetchBideState

    func testFetchBideStateBuildsTheRequest() async throws {
        let transport = StubTransport(json: bideJSON)
        _ = try await makeClient(transport: transport).fetchBideState(bideID: bideID)

        let requests = await transport.received
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host(), "abcdefgh.supabase.co")
        XCTAssertEqual(request.url?.path(), "/rest/v1/bides")
        XCTAssertEqual(queryItems(of: request)["id"], "eq.\(bideID.uuidString)")
        // Participants come back embedded, in the same round trip.
        XCTAssertEqual(
            queryItems(of: request)["select"],
            "id,destination_name,lat,lng,scheduled_for,arrival_style,is_solo,created_at,created_by,"
                + "participants(user_id,display_name,mode,eta_timestamp,baseline_eta,status,updated_at)"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "anon-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-token")
    }

    func testFetchBideStateDecodesTheBideAndItsParticipants() async throws {
        let state = try await makeClient(transport: StubTransport(json: bideJSON))
            .fetchBideState(bideID: bideID)

        XCTAssertEqual(state.bideID, bideID)
        XCTAssertEqual(state.destinationName, "Blue Bottle Coffee")
        XCTAssertEqual(state.lat, 37.7952)
        XCTAssertEqual(state.lng, -122.2718)
        XCTAssertEqual(state.createdBy, userID)
        XCTAssertEqual(state.participants.count, 2)

        let me = try XCTUnwrap(state.participant(userID))
        XCTAssertEqual(me.mode, .walking)
        XCTAssertEqual(me.status, .accepted)
        XCTAssertNotNil(me.etaTimestamp)

        // A participant who hasn't anchored an ETA yet is not a decode failure.
        let them = try XCTUnwrap(state.participant(otherUserID))
        XCTAssertEqual(them.mode, .driving)
        XCTAssertNil(them.etaTimestamp)

        XCTAssertEqual(state.participants(besides: userID).map(\.userID), [otherUserID])
    }

    /// Row-level security answers "a bide you can't see" with an empty result,
    /// not a 403, so an empty array is the not-found case.
    func testFetchBideStateTreatsEmptyResultAsNotFound() async {
        let client = makeClient(transport: StubTransport(json: "[]"))
        await XCTAssertThrowsAPIError(.notFound) {
            _ = try await client.fetchBideState(bideID: self.bideID)
        }
    }

    func testBideStateBridgesBackToTheTileURL() async throws {
        let state = try await makeClient(transport: StubTransport(json: bideJSON))
            .fetchBideState(bideID: bideID)

        let invite = state.invite
        XCTAssertEqual(invite.bideID, bideID)
        XCTAssertEqual(invite.destinationName, "Blue Bottle Coffee")
        XCTAssertEqual(BideInvite(url: invite.webURL()), invite)
    }

    // MARK: createBide

    func testCreateBideCallsTheFunctionThenReadsStateBack() async throws {
        let transport = StubTransport([
            .init(status: 200, json: "{}"),      // rpc/create_bide
            .init(status: 200, json: bideJSON),  // follow-up fetch
        ])
        let invite = BideInvite(
            bideID: bideID,
            destinationName: "Blue Bottle Coffee",
            lat: 37.7952,
            lng: -122.2718,
            createdAt: Date(timeIntervalSince1970: 1_786_477_405.205)
        )

        let state = try await makeClient(transport: transport).createBide(invite, mode: .walking)
        XCTAssertEqual(state.participants.count, 2)

        let requests = await transport.received
        XCTAssertEqual(requests.count, 2)

        let create = try XCTUnwrap(requests.first)
        XCTAssertEqual(create.httpMethod, "POST")
        XCTAssertEqual(create.url?.path(), "/rest/v1/rpc/create_bide")

        let sent = body(of: create)
        XCTAssertEqual(sent["p_bide_id"] as? String, bideID.uuidString)
        XCTAssertEqual(sent["p_destination_name"] as? String, "Blue Bottle Coffee")
        XCTAssertEqual(sent["p_lat"] as? Double, 37.7952)
        XCTAssertEqual(sent["p_lng"] as? Double, -122.2718)
        XCTAssertEqual(sent["p_mode"] as? String, "walking")
        XCTAssertEqual(sent["p_created_at"] as? String, "2026-08-11T19:43:25.205Z")
        // The creator's identity comes from the JWT, never from the body.
        XCTAssertNil(sent["p_created_by"])

        XCTAssertEqual(requests.last?.httpMethod, "GET")
    }

    func testCreateBideSurfacesTheFunctionFailureNotTheFetch() async {
        let transport = StubTransport([
            .init(status: 403, json: #"{"code":"42501","message":"violates row-level security policy"}"#),
        ])
        let client = makeClient(transport: transport)
        let invite = BideInvite(destinationName: "Somewhere", lat: 1, lng: 2)

        await XCTAssertThrowsAPIError(.notPermitted) {
            _ = try await client.createBide(invite, mode: .driving)
        }
    }

    // MARK: joinBide

    /// Joining goes through the function, not an upsert on /participants —
    /// row-level security refuses ON CONFLICT for someone who hasn't joined
    /// yet, because the conflict lookup can't see rows in that bide.
    func testJoinBideCallsTheFunction() async throws {
        let transport = StubTransport([
            .init(status: 200, json: "{}"),
            .init(status: 200, json: bideJSON),
        ])
        let state = try await makeClient(transport: transport).joinBide(bideID: bideID, mode: .driving)
        XCTAssertEqual(state.participants.count, 2)

        let requests = await transport.received
        let join = try XCTUnwrap(requests.first)
        XCTAssertEqual(join.httpMethod, "POST")
        XCTAssertEqual(join.url?.path(), "/rest/v1/rpc/join_bide")

        let sent = body(of: join)
        XCTAssertEqual(sent["p_bide_id"] as? String, bideID.uuidString)
        XCTAssertEqual(sent["p_mode"] as? String, "driving")
        // Identity comes from the JWT, so there is nothing here to forge.
        XCTAssertNil(sent["user_id"])
        XCTAssertNil(sent["p_user_id"])

        XCTAssertEqual(requests.last?.httpMethod, "GET")
    }

    /// Joining a bide that doesn't exist trips the foreign key, which is a
    /// clearer "no such bide" than the bare 409 the status line carries.
    func testJoinBideMapsForeignKeyViolationToNotFound() async {
        let client = makeClient(transport: StubTransport(
            status: 409,
            json: #"{"code":"23503","message":"insert or update on table \"participants\" violates foreign key constraint"}"#
        ))
        await XCTAssertThrowsAPIError(.notFound) {
            _ = try await client.joinBide(bideID: self.bideID, mode: .driving)
        }
    }

    // MARK: updateMyETA

    func testUpdateMyETAPatchesOnlyYourOwnRow() async throws {
        let participantJSON = """
            [{"user_id":"11111111-1111-1111-1111-111111111111","mode":"walking",
              "eta_timestamp":"2026-08-11T19:55:00.5+00:00",
              "updated_at":"2026-08-11T19:44:00.741882+00:00","status":"accepted"}]
            """
        let transport = StubTransport(json: participantJSON)
        let eta = Date(timeIntervalSince1970: 1_786_478_100.5)

        let participant = try await makeClient(transport: transport)
            .updateMyETA(bideID: bideID, arrivingAt: eta, baselineETA: eta, mode: .walking)

        XCTAssertEqual(participant.userID, userID)
        XCTAssertEqual(participant.etaTimestamp?.timeIntervalSince1970 ?? 0, eta.timeIntervalSince1970, accuracy: 0.0005)

        let requests = await transport.received
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path(), "/rest/v1/participants")
        // Both filters present: the policy already scopes this to the caller's
        // row, and the request says so too.
        XCTAssertEqual(queryItems(of: request)["bide_id"], "eq.\(bideID.uuidString)")
        XCTAssertEqual(queryItems(of: request)["user_id"], "eq.\(userID.uuidString)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Prefer"), "return=representation")

        let sent = body(of: request)
        XCTAssertEqual(sent["eta_timestamp"] as? String, "2026-08-11T19:55:00.500Z")
        XCTAssertEqual(sent["status"] as? String, "accepted")
        // The one thing that must never appear in a request body.
        XCTAssertNil(sent["lat"])
        XCTAssertNil(sent["lng"])
    }

    func testUpdateMyETACanClearTheETA() async throws {
        let transport = StubTransport(json: """
            [{"user_id":"11111111-1111-1111-1111-111111111111","mode":"walking","eta_timestamp":null,
              "updated_at":"2026-08-11T19:44:00+00:00","status":"arrived"}]
            """)
        let participant = try await makeClient(transport: transport)
            .updateMyETA(bideID: bideID, arrivingAt: nil, baselineETA: nil, mode: .walking, status: .arrived)

        XCTAssertNil(participant.etaTimestamp)
        XCTAssertEqual(participant.status, .arrived)

        let requests = await transport.received
        let request = try XCTUnwrap(requests.first)
        XCTAssertTrue(body(of: request)["eta_timestamp"] is NSNull)
    }

    /// Zero rows updated means the caller isn't in this bide.
    func testUpdateMyETAOnAForeignBideIsNotFound() async {
        let client = makeClient(transport: StubTransport(json: "[]"))
        await XCTAssertThrowsAPIError(.notFound) {
            _ = try await client.updateMyETA(bideID: self.bideID, arrivingAt: Date(), baselineETA: nil, mode: .driving)
        }
    }

    // MARK: Errors

    func testSignedOutFailsWithoutTouchingTheNetwork() async {
        let transport = StubTransport(json: bideJSON)
        let client = makeClient(transport: transport, signedIn: false)

        await XCTAssertThrowsAPIError(.notAuthenticated) {
            _ = try await client.fetchBideState(bideID: self.bideID)
        }
        let requests = await transport.received
        XCTAssertTrue(requests.isEmpty)
    }

    func testStatusCodesMapToTypedErrors() async {
        let cases: [(Int, String, APIError)] = [
            (401, "{}", .notAuthenticated),
            (403, "{}", .notPermitted),
            (404, "{}", .notFound),
            (409, "{}", .conflict),
            (500, #"{"message":"boom"}"#, .serverError(status: 500, message: "boom")),
            (503, "{}", .serverError(status: 503, message: nil)),
        ]
        for (status, json, expected) in cases {
            let client = makeClient(transport: StubTransport(status: status, json: json))
            await XCTAssertThrowsAPIError(expected, "status \(status)") {
                _ = try await client.fetchBideState(bideID: self.bideID)
            }
        }
    }

    func testRateLimitCarriesRetryAfter() async {
        let client = makeClient(transport: StubTransport(
            status: 429, json: "{}", headers: ["Retry-After": "30"]
        ))
        await XCTAssertThrowsAPIError(.rateLimited(retryAfter: 30)) {
            _ = try await client.fetchBideState(bideID: self.bideID)
        }
    }

    func testTransportFailureIsSurfacedAsTransport() async {
        let client = makeClient(transport: FailingTransport(error: URLError(.notConnectedToInternet)))
        await XCTAssertThrowsAPIError(.transport(URLError(.notConnectedToInternet))) {
            _ = try await client.fetchBideState(bideID: self.bideID)
        }
    }

    func testMalformedBodyIsADecodingFailure() async {
        let client = makeClient(transport: StubTransport(json: #"[{"id":"not-a-uuid"}]"#))
        do {
            _ = try await client.fetchBideState(bideID: bideID)
            XCTFail("expected a decoding failure")
        } catch {
            guard case .decodingFailed = error else {
                return XCTFail("expected .decodingFailed, got \(error)")
            }
        }
    }

    func testRetryableErrorsAreMarkedAsSuch() {
        XCTAssertTrue(APIError.transport(URLError(.timedOut)).isRetryable)
        XCTAssertTrue(APIError.rateLimited(retryAfter: nil).isRetryable)
        XCTAssertTrue(APIError.serverError(status: 500, message: nil).isRetryable)
        XCTAssertFalse(APIError.notPermitted.isRetryable)
        XCTAssertFalse(APIError.notFound.isRetryable)
        XCTAssertFalse(APIError.notAuthenticated.isRetryable)
    }

    // MARK: Configuration

    func testConfigurationRejectsAMalformedProjectURL() {
        XCTAssertNil(SupabaseConfiguration(projectURL: "", anonKey: "k"))
        XCTAssertNil(SupabaseConfiguration(projectURL: "not a url", anonKey: "k"))
        XCTAssertNil(SupabaseConfiguration(projectURL: "/rest/v1", anonKey: "k"))
        XCTAssertNotNil(SupabaseConfiguration(projectURL: "https://abcdefgh.supabase.co", anonKey: "k"))
    }

    // MARK: Travel mode

    func testTravelModeMatchesTheETAPolicy() {
        XCTAssertEqual(TravelMode.driving.reanchorInterval, 5 * 60)
        XCTAssertEqual(TravelMode.walking.reanchorInterval, 10 * 60)
        // Transit is exposed to timetables, so it re-anchors on the short
        // cadence like driving does.
        XCTAssertEqual(TravelMode.transit.reanchorInterval, 5 * 60)
    }

    /// Only these three can be picked or persisted, and the database's check
    /// constraint lists exactly the same set. A mode the ETA engine can't
    /// answer for must never reach a participant row.
    func testOnlyRoutableModesAreSelectable() {
        XCTAssertEqual(TravelMode.selectable, [.walking, .driving, .transit])
        for mode in [TravelMode.cycling, .flying, .train] {
            XCTAssertFalse(mode.isSelectable, "\(mode.rawValue) has no ETA source yet")
        }
        // The row still shows the unavailable ones — dimmed, not missing.
        XCTAssertEqual(TravelMode.displayOrder.count, 5)
        XCTAssertTrue(TravelMode.displayOrder.contains(.cycling))
    }

    /// Route deviation needs a polyline, which only these two come with.
    func testOnlyRoutedModesTrackDeviation() {
        XCTAssertTrue(TravelMode.walking.tracksRouteDeviation)
        XCTAssertTrue(TravelMode.driving.tracksRouteDeviation)
        XCTAssertFalse(TravelMode.transit.tracksRouteDeviation)
    }
}

// MARK: - Helper

/// Asserts an async call throws a specific ``APIError``.
private func XCTAssertThrowsAPIError(
    _ expected: APIError,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("expected \(expected) but nothing was thrown. \(message)", file: file, line: line)
    } catch let error as APIError {
        XCTAssertEqual(error, expected, message, file: file, line: line)
    } catch {
        XCTFail("expected \(expected) but got \(error). \(message)", file: file, line: line)
    }
}
