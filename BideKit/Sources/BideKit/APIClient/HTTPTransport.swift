import Foundation

/// Abstracts HTTP requests so API behavior can be tested without a live server.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// URLSession-backed transport used in production.
public struct URLSessionTransport: HTTPTransport {

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Retries once when a pooled connection was closed before the request completed.
    /// Client-generated identifiers make writes safe to replay without duplication.
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await perform(request)
        } catch let error as URLError where error.code == .networkConnectionLost {
            return try await perform(request)
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse("expected an HTTP response, got \(type(of: response))")
        }
        return (data, httpResponse)
    }
}

/// Supabase project endpoint and public API key.
public struct SupabaseConfiguration: Equatable, Sendable {

    public let projectURL: URL
    /// Publishable key sent alongside the caller's JWT.
    public let anonKey: String

    public init(projectURL: URL, anonKey: String) {
        self.projectURL = projectURL
        self.anonKey = anonKey
    }

    /// Returns `nil` for a malformed project URL.
    public init?(projectURL: String, anonKey: String) {
        guard let url = URL(string: projectURL), url.scheme != nil, url.host() != nil else {
            return nil
        }
        self.init(projectURL: url, anonKey: anonKey)
    }
}

/// An authenticated Bide session.
public struct BideSession: Equatable, Sendable {

    public let userID: UUID
    public let accessToken: String
    /// Whether the identity is recoverable only from this device's keychain.
    public let isAnonymous: Bool
    /// Account display name, persisted because Apple provides it only on first authorization.
    public let displayName: String?

    public init(
        userID: UUID,
        accessToken: String,
        isAnonymous: Bool = true,
        displayName: String? = nil
    ) {
        self.userID = userID
        self.accessToken = accessToken
        self.isAnonymous = isAnonymous
        self.displayName = displayName
    }
}

/// Supplies a valid session, refreshing it when necessary.
/// Errors distinguish authentication failure from network unavailability.
public protocol BideSessionProvider: Sendable {
    func currentSession() async throws(APIError) -> BideSession
}
