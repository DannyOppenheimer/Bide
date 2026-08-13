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

    /// Sends the request, replaying it once if the connection turned out to be
    /// dead before anything was written to it.
    ///
    /// `URLSession` pools connections and keeps handing them back after the
    /// far end has quietly closed one — Supabase sits behind a proxy that
    /// reaps idle connections, so this shows up as `-1005 "The network
    /// connection was lost"` on the *first* request after the app has been
    /// sitting still, most visibly the token refresh on launch. The user was
    /// never offline, so telling them to check their connection is simply
    /// wrong; the fix is to let URLSession discard the dead connection and try
    /// again on a fresh one.
    ///
    /// One replay, and only for that one error code. A genuine outage still
    /// surfaces as ``APIError/transport(_:)`` on the first attempt, and every
    /// write this transport carries is safe to repeat: the ids are generated
    /// by the client, so a request that did land the first time collides
    /// rather than duplicating.
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
    /// a real `auth.uid()` with real rows, but it lives and dies with one
    /// keychain entry: it survives deleting the app, and nothing recovers it
    /// from another device or an erased one. That's what the settings screen
    /// warns about, and what Sign in with Apple fixes.
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
