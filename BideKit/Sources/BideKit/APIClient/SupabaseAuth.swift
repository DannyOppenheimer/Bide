import Foundation

/// Persists the refresh token that identifies a session between launches.
public protocol AuthTokenStore: Sendable {
    func loadRefreshToken() -> String?
    func save(refreshToken: String?)
}

/// Keychain-backed token storage used in production.
public struct KeychainTokenStore: AuthTokenStore {

    private let service: String
    private let account: String

    public init(service: String = "app.trybide.auth", account: String = "refresh-token") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func loadRefreshToken() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard
            SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }

        return String(data: data, encoding: .utf8)
    }

    public func save(refreshToken: String?) {
        guard let refreshToken, let data = refreshToken.data(using: .utf8) else {
            SecItemDelete(baseQuery as CFDictionary)
            return
        }

        let updated = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard updated != errSecSuccess else { return }

        var insert = baseQuery
        insert[kSecValueData as String] = data
        // Permit background refresh after first unlock without syncing the token.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(insert as CFDictionary, nil)
    }
}

/// In-memory token storage for tests and previews.
public final class InMemoryTokenStore: AuthTokenStore, @unchecked Sendable {

    private let lock = NSLock()
    private var token: String?

    public init(refreshToken: String? = nil) {
        token = refreshToken
    }

    public func loadRefreshToken() -> String? {
        lock.withLock { token }
    }

    public func save(refreshToken: String?) {
        lock.withLock { token = refreshToken }
    }
}

// MARK: - Session provider

/// Manages anonymous or Apple-backed identities and refreshes access tokens.
/// Actor isolation prevents concurrent authentication and refresh races.
public actor BideAuthProvider: BideSessionProvider {

    private struct CachedSession {
        let session: BideSession
        let refreshToken: String
        let expiresAt: Date
    }

    private let configuration: SupabaseConfiguration
    private let transport: any HTTPTransport
    private let store: any AuthTokenStore
    private let now: @Sendable () -> Date

    private var cached: CachedSession?

    /// Refresh margin that prevents a token from expiring during a request.
    private static let refreshMargin: TimeInterval = 60

    public init(
        configuration: SupabaseConfiguration,
        transport: any HTTPTransport = URLSessionTransport(),
        store: any AuthTokenStore = KeychainTokenStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.store = store
        self.now = now
    }

    public func currentSession() async throws(APIError) -> BideSession {
        if let cached, cached.expiresAt > now().addingTimeInterval(Self.refreshMargin) {
            return cached.session
        }

        if let refreshToken = cached?.refreshToken ?? store.loadRefreshToken() {
            do {
                return try await exchange(refreshToken: refreshToken)
            } catch APIError.notAuthenticated {
                // Replace the identity only when the refresh token is explicitly rejected.
                clearStoredIdentity()
            }
        }

        return try await signInAnonymously()
    }

    /// Exchanges an Apple identity token for a Bide session without merging an
    /// existing anonymous account. See `docs/apple-sign-in-setup.md`.
    /// - Parameter nonce: Raw nonce whose SHA-256 hash was sent to Apple.
    public func signInWithApple(idToken: String, nonce: String) async throws(APIError) -> BideSession {
        let body: Data
        do {
            body = try JSONEncoder().encode([
                "provider": "apple",
                "id_token": idToken,
                "nonce": nonce,
            ])
        } catch {
            throw APIError.encodingFailed(String(describing: error))
        }

        return try await authenticate(
            path: "/auth/v1/token",
            query: [URLQueryItem(name: "grant_type", value: "id_token")],
            body: body,
            failure: .explained
        )
    }

    /// Persists the display name in account metadata so it survives new sessions.
    public func record(displayName: String?) async throws(APIError) {
        let session = try await currentSession()

        let body: Data
        do {
            body = try JSONEncoder().encode(DisplayNameUpdate(displayName: displayName))
        } catch {
            throw APIError.encodingFailed(String(describing: error))
        }

        guard var components = URLComponents(url: configuration.projectURL, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidConfiguration("project URL is not a valid URL: \(configuration.projectURL)")
        }
        components.path = "/auth/v1/user"
        guard let url = components.url else {
            throw APIError.invalidConfiguration("could not build an endpoint for /auth/v1/user")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = body
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response: HTTPURLResponse
        do {
            (_, response) = try await transport.send(request)
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
            throw APIError.serverError(status: response.statusCode, message: nil)
        }

        // Keep the cached session consistent with the updated metadata.
        if let cached {
            self.cached = CachedSession(
                session: BideSession(
                    userID: cached.session.userID,
                    accessToken: cached.session.accessToken,
                    isAnonymous: cached.session.isAnonymous,
                    displayName: displayName
                ),
                refreshToken: cached.refreshToken,
                expiresAt: cached.expiresAt
            )
        }
    }

    /// Clears the identity so the next request creates a new session.
    public func signOut() {
        cached = nil
        store.save(refreshToken: nil)
    }

    private func clearStoredIdentity() {
        cached = nil
        store.save(refreshToken: nil)
    }

    // MARK: Requests

    private func signInAnonymously() async throws(APIError) -> BideSession {
        try await authenticate(
            path: "/auth/v1/signup",
            query: [],
            body: Data("{}".utf8),
            failure: .explained
        )
    }

    private func exchange(refreshToken: String) async throws(APIError) -> BideSession {
        let body: Data
        do {
            body = try JSONEncoder().encode(["refresh_token": refreshToken])
        } catch {
            throw APIError.encodingFailed(String(describing: error))
        }

        return try await authenticate(
            path: "/auth/v1/token",
            query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
            body: body,
            failure: .identityLost
        )
    }

    /// Controls how authentication failures are interpreted for each credential type.
    private enum AuthFailure {
        /// A rejected refresh token means the stored identity is no longer valid.
        case identityLost
        /// A rejected new credential should preserve the server's explanation.
        case explained
    }

    private func authenticate(
        path: String,
        query: [URLQueryItem],
        body: Data,
        failure: AuthFailure
    ) async throws(APIError) -> BideSession {
        guard var components = URLComponents(url: configuration.projectURL, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidConfiguration("project URL is not a valid URL: \(configuration.projectURL)")
        }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query

        guard let url = components.url else {
            throw APIError.invalidConfiguration("could not build an endpoint for \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

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
            throw Self.mapAuthFailure(status: response.statusCode, data: data, failure: failure)
        }

        let token: TokenResponse
        do {
            token = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw APIError.decodingFailed("TokenResponse: \(error)")
        }

        guard let userID = UUID(uuidString: token.user.id) else {
            throw APIError.decodingFailed("auth returned a user id that isn't a UUID: \(token.user.id)")
        }

        let session = BideSession(
            userID: userID,
            accessToken: token.accessToken,
            isAnonymous: token.user.isAnonymous ?? true,
            displayName: token.user.metadata?.displayName
        )
        cached = CachedSession(
            session: session,
            refreshToken: token.refreshToken,
            expiresAt: now().addingTimeInterval(TimeInterval(token.expiresIn))
        )
        store.save(refreshToken: token.refreshToken)
        return session
    }

    private static func mapAuthFailure(status: Int, data: Data, failure: AuthFailure) -> APIError {
        let body = try? JSONDecoder().decode(GoTrueError.self, from: data)
        let message = body?.errorDescription ?? body?.msg ?? body?.message

        switch status {
        case 400, 401, 403:
            // Only a rejected refresh token maps to a lost identity.
            guard case .explained = failure, let message else { return .notAuthenticated }
            return .serverError(status: status, message: message)
        case 422:
            // Often indicates disabled anonymous sign-in during project setup.
            return .serverError(status: status, message: message)
        case 429:
            return .rateLimited(retryAfter: nil)
        default:
            return .serverError(status: status, message: message)
        }
    }
}

// MARK: - Wire types

private struct TokenResponse: Decodable {
    struct User: Decodable {
        /// Account metadata returned by GoTrue on each sign-in.
        struct Metadata: Decodable {
            let fullName: String?
            let name: String?

            enum CodingKeys: String, CodingKey {
                case fullName = "full_name"
                case name
            }

            /// First nonempty name component used in compact roster layouts.
            var displayName: String? {
                let raw = (fullName ?? name)?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let raw, !raw.isEmpty else { return nil }
                return raw.split(separator: " ").first.map(String.init) ?? raw
            }
        }

        let id: String
        /// Optional for compatibility with older GoTrue responses.
        let isAnonymous: Bool?
        let metadata: Metadata?

        enum CodingKeys: String, CodingKey {
            case id
            case isAnonymous = "is_anonymous"
            case metadata = "user_metadata"
        }
    }

    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let user: User

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case user
    }
}

/// Encodes GoTrue metadata under `data`, using JSON null to clear `full_name`.
private struct DisplayNameUpdate: Encodable {
    let displayName: String?

    private enum CodingKeys: String, CodingKey { case data }
    private enum MetadataKeys: String, CodingKey { case fullName = "full_name" }

    func encode(to encoder: Encoder) throws {
        var root = encoder.container(keyedBy: CodingKeys.self)
        var data = root.nestedContainer(keyedBy: MetadataKeys.self, forKey: .data)
        if let displayName {
            try data.encode(displayName, forKey: .fullName)
        } else {
            try data.encodeNil(forKey: .fullName)
        }
    }
}

/// Error payload returned by GoTrue across its supported field names.
private struct GoTrueError: Decodable {
    let msg: String?
    let message: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case msg
        case message
        case errorDescription = "error_description"
    }
}
