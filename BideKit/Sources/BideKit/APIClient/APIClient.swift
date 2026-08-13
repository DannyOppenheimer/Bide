import Foundation

/// Server operations for bides and participants.
/// Participant updates send arrival timestamps and travel duration, never locations.
public protocol BideAPI: Sendable {

    /// Creates a bide and its creator participant in one transaction.
    func createBide(_ invite: BideInvite, mode: TravelMode, isSolo: Bool) async throws(APIError) -> BideState

    /// Joins a bide or updates the caller's existing response and travel mode.
    func joinBide(
        bideID: UUID,
        mode: TravelMode,
        status: ParticipantStatus
    ) async throws(APIError) -> BideState

    /// Updates the caller's participant row with journey state.
    ///
    /// - Parameters:
    ///   - travelTime: Most recent on-device journey duration.
    ///   - leftAt: First detected departure time, repeated unchanged after departure.
    func updateMyETA(
        bideID: UUID,
        arrivingAt: Date?,
        baselineETA: Date?,
        travelTime: TimeInterval?,
        leftAt: Date?,
        mode: TravelMode,
        status: ParticipantStatus
    ) async throws(APIError) -> Participant

    /// Updates the shared destination and arrival time. Travel mode remains per-participant.
    func updateBide(
        bideID: UUID,
        destination: Destination,
        scheduledFor: Date?
    ) async throws(APIError) -> BideState

    /// Fetches a bide and its participants.
    func fetchBideState(bideID: UUID) async throws(APIError) -> BideState

    /// Fetches bides visible to the caller through row-level security.
    func fetchMyBides() async throws(APIError) -> [BideState]

    /// Removes the caller from a bide.
    func leaveBide(bideID: UUID) async throws(APIError)

    /// Deletes a caller-owned solo bide and its watcher records.
    func deleteBide(bideID: UUID) async throws(APIError)

    /// Updates the caller's display name across their participant rows.
    func updateDisplayName(_ name: String) async throws(APIError)

    /// Deletes the authenticated account and all cascading data.
    func deleteMe() async throws(APIError)
}

extension BideAPI {

    /// Updates an accepted participant's ETA.
    public func updateMyETA(
        bideID: UUID,
        arrivingAt: Date,
        baselineETA: Date?,
        travelTime: TimeInterval? = nil,
        leftAt: Date? = nil,
        mode: TravelMode
    ) async throws(APIError) -> Participant {
        try await updateMyETA(
            bideID: bideID,
            arrivingAt: arrivingAt,
            baselineETA: baselineETA,
            travelTime: travelTime,
            leftAt: leftAt,
            mode: mode,
            status: .accepted
        )
    }

    /// Creates a shared bide.
    public func createBide(_ invite: BideInvite, mode: TravelMode) async throws(APIError) -> BideState {
        try await createBide(invite, mode: mode, isSolo: false)
    }

    /// Accepts an invitation.
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

    /// PostgREST selection for a bide with embedded participants.
    private static let bideSelect = """
        id,destination_name,lat,lng,scheduled_for,arrival_style,is_solo,created_at,created_by,\
        participants(user_id,display_name,mode,eta_timestamp,baseline_eta,travel_seconds,left_at,status,updated_at)
        """

    // MARK: Requests

    public func createBide(
        _ invite: BideInvite,
        mode: TravelMode,
        isSolo: Bool
    ) async throws(APIError) -> BideState {
        let session = try await requireSession()

        // The RPC creates the bide and creator participant atomically.
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

        // Fetch again because the RPC response does not embed participants.
        return try await fetchBideState(bideID: invite.bideID)
    }

    public func joinBide(
        bideID: UUID,
        mode: TravelMode,
        status: ParticipantStatus
    ) async throws(APIError) -> BideState {
        let session = try await requireSession()

        // The RPC handles new participants without exposing conflict rows through RLS.
        // It obtains the participant identity from `auth.uid()`.
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
        travelTime: TimeInterval?,
        leftAt: Date?,
        mode: TravelMode,
        status: ParticipantStatus
    ) async throws(APIError) -> Participant {
        let session = try await requireSession()

        // Departure detection stays on-device; this payload contains no location.
        let body = try encode([
            "eta_timestamp": arrivingAt.map { .string(PostgresTimestamp.string(from: $0)) } ?? .null,
            "baseline_eta": baselineETA.map { .string(PostgresTimestamp.string(from: $0)) } ?? .null,
            "travel_seconds": travelTime.map { .int(Int($0.rounded())) } ?? .null,
            "left_at": leftAt.map { .string(PostgresTimestamp.string(from: $0)) } ?? .null,
            "mode": .string(mode.rawValue),
            "status": .string(status.rawValue),
        ])

        // The explicit user filter complements RLS and makes an unexpected match fail closed.
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
            // The caller is not a participant or the bide does not exist.
            throw APIError.notFound
        }
        return participant
    }

    public func updateBide(
        bideID: UUID,
        destination: Destination,
        scheduledFor: Date?
    ) async throws(APIError) -> BideState {
        let session = try await requireSession()

        // Database grants restrict updates to these shared plan fields.
        // Coordinates describe the destination, never a participant.
        let body = try encode([
            "destination_name": .string(destination.name),
            "lat": .number(destination.latitude),
            "lng": .number(destination.longitude),
            "scheduled_for": scheduledFor.map { .string(PostgresTimestamp.string(from: $0)) } ?? .null,
        ])

        let request = try makeRequest(
            method: "PATCH",
            path: "/rest/v1/bides",
            session: session,
            queryItems: [URLQueryItem(name: "id", value: "eq.\(bideID.uuidString)")],
            body: body,
            prefer: "return=representation"
        )

        let data = try await performExpectingSuccess(request)
        let updated: [BideState] = try decode(data)
        guard updated.first != nil else {
            // The bide is missing or row-level security denied the update.
            throw APIError.notFound
        }

        // Fetch again because the PATCH response does not embed participants.
        return try await fetchBideState(bideID: bideID)
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

        // Row-level security limits results to bides visible to the caller.
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

    public func deleteBide(bideID: UUID) async throws(APIError) {
        let session = try await requireSession()

        // The delete policy enforces creator ownership and solo status.
        let request = try makeRequest(
            method: "DELETE",
            path: "/rest/v1/bides",
            session: session,
            queryItems: [URLQueryItem(name: "id", value: "eq.\(bideID.uuidString)")],
            prefer: "return=minimal"
        )

        _ = try await performExpectingSuccess(request)
    }

    public func updateDisplayName(_ name: String) async throws(APIError) {
        let session = try await requireSession()

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = try encode(["display_name": trimmed.isEmpty ? .null : .string(trimmed)])

        // Update every participant row owned by the caller.
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

    public func deleteMe() async throws(APIError) {
        let session = try await requireSession()

        // The security-definer RPC deletes `auth.uid()` and lets foreign keys cascade.
        let request = try makeRequest(
            method: "POST",
            path: "/rest/v1/rpc/delete_me",
            session: session,
            body: Data("{}".utf8),
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

    /// Maps an HTTP and PostgREST failure to the most specific ``APIError``.
    private static func mapFailure(status: Int, data: Data, response: HTTPURLResponse) -> APIError {
        let failure = try? JSONDecoder().decode(PostgRESTError.self, from: data)
        let message = failure?.message

        // Prefer specific PostgreSQL error codes over general HTTP status codes.
        switch failure?.code {
        case "42501":
            // insufficient_privilege
            return .notPermitted
        case "23503":
            // foreign_key_violation
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

/// Encodes PostgreSQL timestamps and accepts values with or without fractional seconds.
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

/// JSON values used to build typed request bodies without `Any`.
enum JSONValue: Encodable, Equatable {
    case string(String)
    case number(Double)
    /// An integer value that must not be encoded as a floating-point number.
    case int(Int)
    case bool(Bool)
    case null

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}
