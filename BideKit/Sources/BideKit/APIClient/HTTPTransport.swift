import Foundation

/// The seam between ``SupabaseAPIClient`` and the network, so the client can be
/// tested against canned responses instead of a live project.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The real one.
public struct URLSessionTransport: HTTPTransport {

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse("expected an HTTP response, got \(type(of: response))")
        }
        return (data, httpResponse)
    }
}

/// Where the Supabase project lives and the public key used to reach it.
public struct SupabaseConfiguration: Equatable, Sendable {

    public let projectURL: URL
    /// The publishable anon key. Every request is still authorised by the
    /// caller's own JWT on top of this; the anon key alone opens nothing,
    /// because `anon` has no privileges on any Bide table.
    public let anonKey: String

    public init(projectURL: URL, anonKey: String) {
        self.projectURL = projectURL
        self.anonKey = anonKey
    }

    /// Fails rather than trapping on a malformed URL string.
    public init?(projectURL: String, anonKey: String) {
        guard let url = URL(string: projectURL), url.scheme != nil, url.host() != nil else {
            return nil
        }
        self.init(projectURL: url, anonKey: anonKey)
    }
}

/// A signed-in user.
public struct BideSession: Equatable, Sendable {

    public let userID: UUID
    public let accessToken: String
    /// Whether this identity exists only on this device. An anonymous user is
    /// a real `auth.uid()` with real rows, but nothing can recover it if the
    /// app is deleted — which is what the settings screen warns about, and
    /// what Sign in with Apple fixes.
    public let isAnonymous: Bool

    public init(userID: UUID, accessToken: String, isAnonymous: Bool = true) {
        self.userID = userID
        self.accessToken = accessToken
        self.isAnonymous = isAnonymous
    }
}

/// Supplies the current session, refreshing it if needed.
///
/// Throws rather than returning an optional so that "signed out"
/// (``APIError/notAuthenticated``) stays distinguishable from "couldn't reach
/// the auth server" (``APIError/transport(_:)``). Collapsing those into `nil`
/// would tell a user on a plane to sign in again.
public protocol BideSessionProvider: Sendable {
    func currentSession() async throws(APIError) -> BideSession
}
