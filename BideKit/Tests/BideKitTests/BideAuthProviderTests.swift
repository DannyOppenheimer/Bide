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

        clock.advance(by: 3000)
        let stillValid = try await provider.currentSession()
        XCTAssertEqual(stillValid.accessToken, "at-1")

        clock.advance(by: 570)
        let renewed = try await provider.currentSession()
        XCTAssertEqual(renewed.accessToken, "at-2")
    }

    // MARK: Credential refresh failure

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

    func testDisplayNameCanBeSetAndCleared() async throws {
        let transport = ScriptedTransport([
            .init(json: tokenJSON(accessToken: "at-1", refreshToken: "rt-1")),
            .init(json: "{}"),
            .init(json: "{}"),
        ])
        let provider = BideAuthProvider(
            configuration: configuration,
            transport: transport,
            store: InMemoryTokenStore()
        )

        _ = try await provider.currentSession()
        try await provider.record(displayName: "Danny")
        let namedSession = try await provider.currentSession()
        XCTAssertEqual(namedSession.displayName, "Danny")

        try await provider.record(displayName: nil)
        let clearedSession = try await provider.currentSession()
        XCTAssertNil(clearedSession.displayName)

        let requests = await transport.received
        XCTAssertEqual(requests.map { $0.url?.path() }, [
            "/auth/v1/signup", "/auth/v1/user", "/auth/v1/user",
        ])

        let setBody = try XCTUnwrap(requests[1].httpBody)
        let setJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: setBody) as? [String: Any]
        )
        let setMetadata = try XCTUnwrap(setJSON["data"] as? [String: Any])
        XCTAssertEqual(setMetadata["full_name"] as? String, "Danny")

        let clearBody = try XCTUnwrap(requests[2].httpBody)
        let clearJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: clearBody) as? [String: Any]
        )
        let clearMetadata = try XCTUnwrap(clearJSON["data"] as? [String: Any])
        XCTAssertTrue(clearMetadata["full_name"] is NSNull)
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

        let fresh = try await provider.currentSession()
        XCTAssertEqual(fresh.accessToken, "at-2")
        let requests = await transport.received
        XCTAssertEqual(requests.map { $0.url?.path() }, ["/auth/v1/signup", "/auth/v1/signup"])
    }
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date) { current = start }

    var now: Date { lock.withLock { current } }

    func advance(by interval: TimeInterval) {
        lock.withLock { current += interval }
    }
}
