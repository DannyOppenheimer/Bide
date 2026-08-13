import XCTest
@testable import BideKit

private actor ScriptedTransport: HTTPTransport {

    struct Stub {
        var status: Int = 200
        var json: String
    }

    private var remaining: [Stub]
    private(set) var received: [URLRequest] = []

    init(_ stubs: [Stub]) {
        remaining = stubs
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        received.append(request)
        guard !remaining.isEmpty else {
            throw APIError.invalidResponse("scripted transport ran out of responses")
        }
        let stub = remaining.removeFirst()
        guard
            let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            throw APIError.invalidResponse("could not build a stub response")
        }
        return (Data(stub.json.utf8), response)
    }
}

private struct AlwaysFailingTransport: HTTPTransport {
    let error: any Error
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw error }
}

final class BideAuthProviderTests: XCTestCase {

    private let userID = "77777777-7777-7777-7777-777777777777"

    private var configuration: SupabaseConfiguration {
        guard let configuration = SupabaseConfiguration(
            projectURL: "https://uglncucsqhqtvzkconpq.supabase.co",
            anonKey: "publishable-key"
        ) else {
            preconditionFailure("test configuration should be valid")
        }
        return configuration
    }

    private func tokenJSON(accessToken: String, refreshToken: String, expiresIn: Int = 3600) -> String {
        """
        {"access_token":"\(accessToken)","token_type":"bearer","expires_in":\(expiresIn),
         "refresh_token":"\(refreshToken)","user":{"id":"\(userID)"}}
        """
    }

    // MARK: Signing in

    func testSignsInAnonymouslyAndKeepsTheRefreshToken() async throws {
        let transport = ScriptedTransport([.init(json: tokenJSON(accessToken: "at-1", refreshToken: "rt-1"))])
        let store = InMemoryTokenStore()
        let provider = BideAuthProvider(
            configuration: configuration,
            transport: transport,
            store: store
        )

        let session = try await provider.currentSession()
        XCTAssertEqual(session.userID.uuidString, userID)
        XCTAssertEqual(session.accessToken, "at-1")
        // Persisted, because losing it means losing the identity entirely.
        XCTAssertEqual(store.loadRefreshToken(), "rt-1")

        let requests = await transport.received
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path(), "/auth/v1/signup")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "publishable-key")
    }

    func testReusesTheCachedSessionRatherThanSigningInAgain() async throws {
        let transport = ScriptedTransport([.init(json: tokenJSON(accessToken: "at-1", refreshToken: "rt-1"))])
        let provider = BideAuthProvider(
            configuration: configuration,
            transport: transport,
            store: InMemoryTokenStore()
        )

        let first = try await provider.currentSession()
        let second = try await provider.currentSession()

        XCTAssertEqual(first, second)
        let requests = await transport.received
        XCTAssertEqual(requests.count, 1, "a valid token should not be re-fetched")
    }

    /// A stored token from a previous launch is exchanged, not thrown away.
    func testResumesAStoredIdentityOnLaunch() async throws {
        let transport = ScriptedTransport([.init(json: tokenJSON(accessToken: "at-2", refreshToken: "rt-2"))])
        let provider = BideAuthProvider(
            configuration: configuration,
            transport: transport,
            store: InMemoryTokenStore(refreshToken: "rt-from-last-launch")
        )

        let session = try await provider.currentSession()
        XCTAssertEqual(session.accessToken, "at-2")

        let requests = await transport.received
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path(), "/auth/v1/token")
        XCTAssertEqual(request.url?.query(), "grant_type=refresh_token")

        let body = try XCTUnwrap(request.httpBody)
        let decoded = try JSONDecoder().decode([String: String].self, from: body)
        XCTAssertEqual(decoded["refresh_token"], "rt-from-last-launch")
    }

    // MARK: Expiry

    func testRefreshesShortlyBeforeExpiry() async throws {
        let transport = ScriptedTransport([
            .init(json: tokenJSON(accessToken: "at-1", refreshToken: "rt-1", expiresIn: 3600)),
            .init(json: tokenJSON(accessToken: "at-2", refreshToken: "rt-2", expiresIn: 3600)),
        ])
        let clock = MutableClock(start: Date(timeIntervalSince1970: 1_000_000))
        let provider = BideAuthProvider(
            configuration: configuration,
            transport: transport,
            store: InMemoryTokenStore(),
            now: { clock.now }
        )

        let first = try await provider.currentSession()
        XCTAssertEqual(first.accessToken, "at-1")

        // Still comfortably valid.
        clock.advance(by: 3000)
        let stillValid = try await provider.currentSession()
        XCTAssertEqual(stillValid.accessToken, "at-1")

        // Inside the renewal margin: swap it out before it can lapse mid-request.
        clock.advance(by: 570)
        let renewed = try await provider.currentSession()
        XCTAssertEqual(renewed.accessToken, "at-2")
    }

    // MARK: The failure that would lose someone's bides

    /// If the refresh token is genuinely rejected the identity is gone, so a
    /// fresh anonymous sign-in is the only way forward.
    func testRejectedRefreshTokenFallsBackToANewIdentity() async throws {
        let transport = ScriptedTransport([
            .init(status: 400, json: #"{"error":"invalid_grant","error_description":"Refresh Token Not Found"}"#),
            .init(json: tokenJSON(accessToken: "at-new", refreshToken: "rt-new")),
        ])
        let store = InMemoryTokenStore(refreshToken: "rt-stale")
        let provider = BideAuthProvider(
            configuration: configuration,
            transport: transport,
            store: store
        )

        let session = try await provider.currentSession()
        XCTAssertEqual(session.accessToken, "at-new")
        XCTAssertEqual(store.loadRefreshToken(), "rt-new")

        let requests = await transport.received
        XCTAssertEqual(requests.map { $0.url?.path() }, ["/auth/v1/token", "/auth/v1/signup"])
    }

    /// But a network failure must NOT do that. Minting a new anonymous identity
    /// because the user was offline would silently strand every bide they were
    /// part of, with no email or Apple ID to recover from.
    func testOfflineRefreshDoesNotDiscardTheIdentity() async {
        let store = InMemoryTokenStore(refreshToken: "rt-precious")
        let provider = BideAuthProvider(
            configuration: configuration,
            transport: AlwaysFailingTransport(error: URLError(.notConnectedToInternet)),
            store: store
        )

        do {
            _ = try await provider.currentSession()
            XCTFail("expected the offline failure to propagate")
        } catch {
            XCTAssertEqual(error, .transport(URLError(.notConnectedToInternet)))
        }
        XCTAssertEqual(store.loadRefreshToken(), "rt-precious", "the identity must survive being offline")
    }

    /// Same reasoning for a server fault.
    func testServerErrorOnRefreshDoesNotDiscardTheIdentity() async {
        let store = InMemoryTokenStore(refreshToken: "rt-precious")
        let provider = BideAuthProvider(
            configuration: configuration,
            transport: ScriptedTransport([.init(status: 500, json: #"{"msg":"boom"}"#)]),
            store: store
        )

        do {
            _ = try await provider.currentSession()
            XCTFail("expected the server failure to propagate")
        } catch {
            XCTAssertEqual(error, .serverError(status: 500, message: "boom"))
        }
        XCTAssertEqual(store.loadRefreshToken(), "rt-precious")
    }

    // MARK: Setup diagnostics

    /// The error you get from a project that hasn't had anonymous sign-ins
    /// switched on. Worth surfacing verbatim — it names the fix.
    func testAnonymousSignInsDisabledIsReportedClearly() async {
        let provider = BideAuthProvider(
            configuration: configuration,
            transport: ScriptedTransport([
                .init(status: 422, json: #"{"code":422,"msg":"Anonymous sign-ins are disabled"}"#),
            ]),
            store: InMemoryTokenStore()
        )

        do {
            _ = try await provider.currentSession()
            XCTFail("expected the 422 to propagate")
        } catch {
            XCTAssertEqual(error, .serverError(status: 422, message: "Anonymous sign-ins are disabled"))
        }
    }

    /// The one that cost a debugging session: Apple sign-in against a project
    /// where the Apple provider was never switched on. GoTrue says so, in as
    /// many words, with a 400 — and a 400 used to be flattened into
    /// ``APIError/notAuthenticated``, so the app said "try again" forever while
    /// the server was naming the toggle that had to be flipped.
    func testAppleProviderDisabledIsReportedClearly() async {
        let provider = BideAuthProvider(
            configuration: configuration,
            transport: ScriptedTransport([
                .init(
                    status: 400,
                    json: #"{"error":"invalid request","error_description":"Unsupported provider: Provider is not enabled"}"#
                ),
            ]),
            store: InMemoryTokenStore()
        )

        do {
            _ = try await provider.signInWithApple(idToken: "id-token", nonce: "nonce")
            XCTFail("expected the 400 to propagate")
        } catch {
            XCTAssertEqual(
                error,
                .serverError(status: 400, message: "Unsupported provider: Provider is not enabled")
            )
        }
    }

    /// The other one: the provider is on, but this bundle ID isn't in its
    /// Client IDs list, so the token's audience is refused.
    func testAppleAudienceRejectionIsReportedClearly() async {
        let provider = BideAuthProvider(
            configuration: configuration,
            transport: ScriptedTransport([
                .init(
                    status: 400,
                    json: #"{"code":400,"error_code":"validation_failed","msg":"Unacceptable audience in id_token"}"#
                ),
            ]),
            store: InMemoryTokenStore()
        )

        do {
            _ = try await provider.signInWithApple(idToken: "id-token", nonce: "nonce")
            XCTFail("expected the 400 to propagate")
        } catch {
            XCTAssertEqual(error, .serverError(status: 400, message: "Unacceptable audience in id_token"))
        }
    }

    /// A 400 with nothing to say still means "signed out", so the refresh path
    /// keeps its meaning even under the new mapping.
    func testUnexplained400StillReadsAsSignedOut() async {
        let provider = BideAuthProvider(
            configuration: configuration,
            transport: ScriptedTransport([.init(status: 400, json: "{}")]),
            store: InMemoryTokenStore()
        )

        do {
            _ = try await provider.signInWithApple(idToken: "id-token", nonce: "nonce")
            XCTFail("expected the 400 to propagate")
        } catch {
            XCTAssertEqual(error, .notAuthenticated)
        }
    }

    func testSignOutForgetsTheIdentity() async throws {
        let transport = ScriptedTransport([
            .init(json: tokenJSON(accessToken: "at-1", refreshToken: "rt-1")),
            .init(json: tokenJSON(accessToken: "at-2", refreshToken: "rt-2")),
        ])
        let store = InMemoryTokenStore()
        let provider = BideAuthProvider(
            configuration: configuration,
            transport: transport,
            store: store
        )

        _ = try await provider.currentSession()
        await provider.signOut()
        XCTAssertNil(store.loadRefreshToken())

        // The next call starts over with a brand new anonymous user.
        let fresh = try await provider.currentSession()
        XCTAssertEqual(fresh.accessToken, "at-2")
        let requests = await transport.received
        XCTAssertEqual(requests.map { $0.url?.path() }, ["/auth/v1/signup", "/auth/v1/signup"])
    }
}

/// A clock the test moves by hand.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date) { current = start }

    var now: Date { lock.withLock { current } }

    func advance(by interval: TimeInterval) {
        lock.withLock { current += interval }
    }
}
