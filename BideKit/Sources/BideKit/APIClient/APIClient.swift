import Foundation

/// Talks to the Bide server.
///
/// Only ever transmits an arrival TIMESTAMP, never a location — the schema has
/// nowhere to put one. The destination's coordinates travel once, when the bide
/// is created, because a destination is a place both people agreed on rather
/// than a person.
///
/// There are no realtime subscriptions here, by design: the Messages extension
/// cannot hold a socket, run in the background, or register for push, so every
/// update reaches the other person as an APNs push handled by the container app.
public protocol BideAPI: Sendable {

    /// Creates a bide from an invite and joins it as the creator, in one
    /// transaction.
    func createBide(_ invite: BideInvite, mode: TravelMode, isSolo: Bool) async throws(APIError) -> BideState

    /// Joins an existing bide, or answers one you're already in. Idempotent:
    /// accepting twice updates your travel mode rather than failing, which is
    /// something a real person does.
    func joinBide(
        bideID: UUID,
        mode: TravelMode,
        status: ParticipantStatus
    ) async throws(APIError) -> BideState

    /// Publishes your own arrival estimate. Writes only your participant row —
    /// row-level security guarantees it, and the request says so anyway.
    func updateMyETA(
        bideID: UUID,
        arrivingAt: Date?,
        baselineETA: Date?,
        mode: TravelMode,
        status: ParticipantStatus
    ) async throws(APIError) -> Participant

    /// The bide and everyone in it.
    func fetchBideState(bideID: UUID) async throws(APIError) -> BideState

    /// Every bide you're part of. Row-level security does the filtering: what
    /// comes back is exactly what you're a participant in.
    func fetchMyBides() async throws(APIError) -> [BideState]

    /// Drops out. Used both when someone declines outright and when accepting
    /// a clashing bide pushes them out of an earlier one.
    func leaveBide(bideID: UUID) async throws(APIError)

    /// Sets the name shown beside your avatar, across every bide you're in.
    func updateDisplayName(_ name: String) async throws(APIError)
}

extension BideAPI {

    /// The common case: a fresh ETA, still en route.
    public func updateMyETA(
        bideID: UUID,
        arrivingAt: Date,
        baselineETA: Date?,
        mode: TravelMode
    ) async throws(APIError) -> Participant {
        try await updateMyETA(
            bideID: bideID,
            arrivingAt: arrivingAt,
            baselineETA: baselineETA,
            mode: mode,
            status: .accepted
        )
    }

    /// Creating a shared bide, which is the usual case.
    public func createBide(_ invite: BideInvite, mode: TravelMode) async throws(APIError) -> BideState {
        try await createBide(invite, mode: mode, isSolo: false)
    }

    /// Accepting a tile.
    public func joinBide(bideID: UUID, mode: TravelMode) async throws(APIError) -> BideState {
        try await joinBide(bideID: bideID, mode: mode, status: .accepted)
    }
}

// MARK: - Supabase implementation

public struct SupabaseAPIClient: BideAPI {

    private let configuration: SupabaseConfiguration
    private let sessionProvider: any BideSessionProvider
    private let transport: any HTTPTransport

    public init(
        configuration: SupabaseConfiguration,
        sessionProvider: any BideSessionProvider,
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.configuration = configuration
        self.sessionProvider = sessionProvider
        self.transport = transport
    }

    /// Columns to pull for a full bide, including the embedded participant rows.
    /// PostgREST resolves `participants(...)` through the foreign key.
    private static let bideSelect = """
        id,destination_name,lat,lng,scheduled_for,arrival_style,is_solo,created_at,created_by,\
        participants(user_id,display_name,mode,eta_timestamp,baseline_eta,status,updated_at)
        """

    // MARK: Requests

    public func createBide(
        _ invite: BideInvite,
        mode: TravelMode,
        isSolo: Bool
    ) async throws(APIError) -> BideState {
        let session = try await requireSession()

        // A function call, not two inserts: the bide and the creator's
        // participant row have to land together, or the creator can't read back
        // the bide they just made.
        let body = try encode([
            "p_bide_id": .string(invite.bideID.uuidString),
            "p_destination_name": .string(invite.destinationName),
            "p_lat": .number(invite.lat),
            "p_lng": .number(invite.lng),
            "p_scheduled_for": invite.scheduledFor.map { .string(PostgresTimestamp.string(from: $0)) } ?? .null,
            "p_arrival_style": .string(invite.arrivalStyle.rawValue),
            "p_is_solo": .bool(isSolo),
            "p_created_at": .string(PostgresTimestamp.string(from: invite.createdAt)),
            "p_mode": .string(mode.rawValue),
        ])

        let request = try makeRequest(
            method: "POST",
            path: "/rest/v1/rpc/create_bide",
            session: session,
            body: body,
            prefer: "return=minimal"
        )
        _ = try await performExpectingSuccess(request)

        // The function returns the bide row, but not its participants, so read
        // the full state back rather than hand callers a half-populated roster.
        return try await fetchBideState(bideID: invite.bideID)
    }

    public func joinBide(
        bideID: UUID,
        mode: TravelMode,
        status: ParticipantStatus
    ) async throws(APIError) -> BideState {
        let session = try await requireSession()

        // A function rather than an upsert on /participants. PostgREST's
        // `resolution=merge-duplicates` emits ON CONFLICT DO UPDATE, which
        // row-level security refuses for a newcomer: the conflict lookup needs
        // to read rows in a bide they cannot see yet. See the migration.
        //
        // The caller's identity is not in the body — join_bide takes it from
        // auth.uid(), so there is nothing here to forge.
        let body = try encode([
            "p_bide_id": .string(bideID.uuidString),
            "p_mode": .string(mode.rawValue),
            "p_status": .string(status.rawValue),
        ])

        let request = try makeRequest(
            method: "POST",
            path: "/rest/v1/rpc/join_bide",
            session: session,
            body: body,
            prefer: "return=minimal"
        )
        _ = try await performExpectingSuccess(request)

        return try await fetchBideState(bideID: bideID)
    }

    public func updateMyETA(
        bideID: UUID,
        arrivingAt: Date?,
        baselineETA: Date?,
        mode: TravelMode,
        status: ParticipantStatus
    ) async throws(APIError) -> Participant {
        let session = try await requireSession()

        // An arrival TIMESTAMP and nothing else about where they are. There is
        // no column here that could hold a location even if this tried to send
        // one — see the privacy invariant in the schema.
        let body = try encode([
            "eta_timestamp": arrivingAt.map { .string(PostgresTimestamp.string(from: $0)) } ?? .null,
            "baseline_eta": baselineETA.map { .string(PostgresTimestamp.string(from: $0)) } ?? .null,
            "mode": .string(mode.rawValue),
            "status": .string(status.rawValue),
        ])

        // `user_id` is redundant with the update policy, which already limits
        // this to the caller's own row. It is here so the request states its
        // intent, and so a policy regression shows up as zero rows updated
        // rather than as a silent write to someone else's row.
        let request = try makeRequest(
            method: "PATCH",
            path: "/rest/v1/participants",
            session: session,
            queryItems: [
                URLQueryItem(name: "bide_id", value: "eq.\(bideID.uuidString)"),
                URLQueryItem(name: "user_id", value: "eq.\(session.userID.uuidString)"),
            ],
            body: body,
            prefer: "return=representation"
        )

        let data = try await performExpectingSuccess(request)
        let updated: [Participant] = try decode(data)
        guard let participant = updated.first else {
            // Nothing matched: not a participant in this bide, or no such bide.
            throw APIError.notFound
        }
        return participant
    }

    public func fetchBideState(bideID: UUID) async throws(APIError) -> BideState {
        let session = try await requireSession()

        let request = try makeRequest(
            method: "GET",
            path: "/rest/v1/bides",
            session: session,
            queryItems: [
                URLQueryItem(name: "id", value: "eq.\(bideID.uuidString)"),
                URLQueryItem(name: "select", value: Self.bideSelect),
            ]
        )

        let data = try await performExpectingSuccess(request)
        let bides: [BideState] = try decode(data)
        guard let bide = bides.first else {
            throw APIError.notFound
        }
        return bide
    }

    public func fetchMyBides() async throws(APIError) -> [BideState] {
        let session = try await requireSession()

        // No `user_id` filter: the read policy already narrows this to bides
        // the caller participates in. Adding one would imply the server would
        // otherwise hand over someone else's.
        let request = try makeRequest(
            method: "GET",
            path: "/rest/v1/bides",
            session: session,
            queryItems: [
                URLQueryItem(name: "select", value: Self.bideSelect),
                URLQueryItem(name: "order", value: "created_at.desc"),
            ]
        )

        return try decode(try await performExpectingSuccess(request))
    }

    public func leaveBide(bideID: UUID) async throws(APIError) {
        let session = try await requireSession()

        let request = try makeRequest(
            method: "DELETE",
            path: "/rest/v1/participants",
            session: session,
            queryItems: [
                URLQueryItem(name: "bide_id", value: "eq.\(bideID.uuidString)"),
                URLQueryItem(name: "user_id", value: "eq.\(session.userID.uuidString)"),
            ],
            prefer: "return=minimal"
        )

        _ = try await performExpectingSuccess(request)
    }

    public func updateDisplayName(_ name: String) async throws(APIError) {
        let session = try await requireSession()

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = try encode(["display_name": trimmed.isEmpty ? .null : .string(trimmed)])

        // Every row at once: a name belongs to the person, not to one meetup,
        // and the update policy limits this to rows that are already theirs.
        let request = try makeRequest(
            method: "PATCH",
            path: "/rest/v1/participants",
            session: session,
            queryItems: [URLQueryItem(name: "user_id", value: "eq.\(session.userID.uuidString)")],
            body: body,
            prefer: "return=minimal"
        )

        _ = try await performExpectingSuccess(request)
    }

    // MARK: Plumbing

    private func requireSession() async throws(APIError) -> BideSession {
        try await sessionProvider.currentSession()
    }

    private func makeRequest(
        method: String,
        path: String,
        session: BideSession,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        prefer: String? = nil
    ) throws(APIError) -> URLRequest {
        guard var components = URLComponents(url: configuration.projectURL, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidConfiguration("project URL is not a valid URL: \(configuration.projectURL)")
        }
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components.url else {
            throw APIError.invalidConfiguration("could not build an endpoint for \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let prefer {
            request.setValue(prefer, forHTTPHeaderField: "Prefer")
        }
        return request
    }

    private func performExpectingSuccess(_ request: URLRequest) async throws(APIError) -> Data {
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.send(request)
        } catch let error as APIError {
            throw error
        } catch let error as URLError {
            throw APIError.transport(error)
        } catch is CancellationError {
            throw APIError.transport(URLError(.cancelled))
        } catch {
            throw APIError.invalidResponse(String(describing: error))
        }

        guard (200..<300).contains(response.statusCode) else {
            throw Self.mapFailure(status: response.statusCode, data: data, response: response)
        }
        return data
    }

    /// Turns a failed response into the most specific ``APIError`` the body
    /// supports.
    private static func mapFailure(status: Int, data: Data, response: HTTPURLResponse) -> APIError {
        let failure = try? JSONDecoder().decode(PostgRESTError.self, from: data)
        let message = failure?.message

        // Postgres SQLSTATEs carry more than the HTTP status does.
        switch failure?.code {
        case "42501":
            // insufficient_privilege — a row-level security refusal.
            return .notPermitted
        case "23503":
            // foreign_key_violation — joining a bide that doesn't exist.
            return .notFound
        case "23505":
            return .conflict
        default:
            break
        }

        switch status {
        case 401:
            return .notAuthenticated
        case 403:
            return .notPermitted
        case 404:
            return .notFound
        case 409:
            return .conflict
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retryAfter)
        default:
            return .serverError(status: status, message: message)
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws(APIError) -> T {
        do {
            return try Self.makeDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decodingFailed("\(T.self): \(error)")
        }
    }

    private func encode(_ object: [String: JSONValue]) throws(APIError) -> Data {
        do {
            return try JSONEncoder().encode(object)
        } catch {
            throw APIError.encodingFailed(String(describing: error))
        }
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = PostgresTimestamp.date(from: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "not a Postgres timestamptz: \(raw)"
                )
            }
            return date
        }
        return decoder
    }
}

// MARK: - Timestamps

/// Postgres renders `timestamptz` as ISO 8601 with a variable number of
/// fractional-second digits — none at all when the value lands on a whole
/// second, six when it doesn't. `ISO8601DateFormatter` handles one case or the
/// other depending on `.withFractionalSeconds`, never both, so parsing takes
/// two attempts.
enum PostgresTimestamp {

    private static func formatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    static func string(from date: Date) -> String {
        formatter(fractionalSeconds: true).string(from: date)
    }

    static func date(from string: String) -> Date? {
        formatter(fractionalSeconds: true).date(from: string)
            ?? formatter(fractionalSeconds: false).date(from: string)
    }
}

// MARK: - Request bodies

/// A small closed set of JSON values, so request bodies are built without
/// `Any` and without a bespoke `Encodable` type per endpoint.
enum JSONValue: Encodable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
