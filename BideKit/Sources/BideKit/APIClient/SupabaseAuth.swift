import Foundation

/// Where the refresh token lives between launches.
///
/// An anonymous identity *is* the refresh token: lose it and the user loses
/// every bide they were part of, because there is no email or Apple ID to
/// recover the account from.
public protocol AuthTokenStore: Sendable {
    func loadRefreshToken() -> String?
    func save(refreshToken: String?)
}

/// Keychain-backed store. The default, because a refresh token that grants a
/// permanent identity does not belong in `UserDefaults`.
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
        // Available after first unlock so a push-triggered launch can refresh,
        // but never synced to another device — the identity is this install's.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(insert as CFDictionary, nil)
    }
}

/// Non-persistent store, for tests and previews.
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

/// Holds the user's identity and keeps the access token fresh.
///
/// Two ways in, both producing a real `auth.uid()` that every row-level
/// security policy is written against:
///
/// - **Anonymous**, the default. Nobody is asked to make an account before
///   they've seen the app work. The identity lives in the keychain, which
///   outlives not just relaunches but *deleting the app* — iOS does not clear
///   keychain items on uninstall. So a reinstall resumes the same user and the
///   same bides come back down from the server, which is the answer to "why is
///   last week's meetup still here after I wiped the build". `signOut()` is
///   the only thing that forgets it.
/// - **Sign in with Apple**, via ``signInWithApple(idToken:nonce:)``, which is
///   the same identity on every device the user owns.
///
/// An actor so that concurrent callers can't race into signing in twice.
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

    /// Renew this far ahead of expiry, so a token can't lapse mid-request.
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
                // The token was genuinely rejected, so this identity is gone
                // and a new one is the only way forward. Any other failure —
                // offline, timeout, 500 — must NOT land here: silently minting
                // a new identity would strand the user's existing bides.
                clearStoredIdentity()
            }
        }

        return try await signInAnonymously()
    }

    /// Exchanges an Apple identity token for a Bide session.
    ///
    /// This is the native flow: `ASAuthorizationAppleIDProvider` produces the
    /// token on-device and Supabase verifies it against Apple's public keys,
    /// so nothing secret is needed in the app. The only server-side setup is
    /// enabling Apple as a provider and listing this app's bundle ID as an
    /// authorised client — see `docs/apple-sign-in-setup.md`.
    ///
    /// - Parameter nonce: The *raw* nonce whose SHA-256 hash was handed to
    ///   `ASAuthorizationAppleIDRequest`. Apple echoes the hash inside the
    ///   token and Supabase checks the two against each other, which is what
    ///   stops a stolen token being replayed.
    ///
    /// Any bides created while anonymous stay with the anonymous identity —
    /// this signs in *as* the Apple user rather than merging the two. Linking
    /// them is a later job, and a visible one, so it isn't done quietly here.
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

    /// Drops the cached and stored identity. The next call signs in afresh.
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

    /// What a 400/401/403 from `/auth/v1` *means*, which depends entirely on
    /// what was sent.
    private enum AuthFailure {
        /// A refresh token the server no longer recognises. There is nothing
        /// to explain and nothing the user can do: the identity is gone, and
        /// ``currentSession()`` catches ``APIError/notAuthenticated`` to mint a
        /// new one.
        case identityLost
        /// A token the server was just handed and refused — and it says why:
        /// "Provider is not enabled", "Unacceptable audience in id_token".
        /// Those name their own fix, so they must survive the mapping. Folding
        /// them into `notAuthenticated` was the difference between a sign-in
        /// failure that tells you the Apple provider is switched off and one
        /// that says "try again" forever.
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
            isAnonymous: token.user.isAnonymous ?? true
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
            // A refresh token the server no longer recognises is the only one
            // of these that means "signed out". The rest are the server
            // explaining what it wants, and the explanation is the whole value
            // of the response.
            guard case .explained = failure, let message else { return .notAuthenticated }
            return .serverError(status: status, message: message)
        case 422:
            // The most likely one during setup: anonymous sign-ins are turned
            // off in the project's auth settings.
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
        let id: String
        /// Absent on older GoTrue builds, where every session this app could
        /// have was anonymous anyway.
        let isAnonymous: Bool?

        enum CodingKeys: String, CodingKey {
            case id
            case isAnonymous = "is_anonymous"
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

/// GoTrue reports errors under `msg` or `error_description`, not the `message`
/// PostgREST uses.
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
