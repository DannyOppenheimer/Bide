import XCTest
@testable import BideKit

/// Fails the first few requests with a chosen `URLError`, then answers 200.
///
/// A `URLProtocol` rather than a stub transport on purpose: the behaviour under
/// test lives *inside* ``URLSessionTransport``, so the seam has to be below it.
private final class FlakyURLProtocol: URLProtocol {

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0
        private var failuresLeft = 0
        private var error = URLError(.networkConnectionLost)

        func reset(failures: Int, error: URLError) {
            lock.withLock {
                attempts = 0
                failuresLeft = failures
                self.error = error
            }
        }

        /// How this attempt should end: an error, or nil to succeed.
        func next() -> URLError? {
            lock.withLock {
                attempts += 1
                guard failuresLeft > 0 else { return nil }
                failuresLeft -= 1
                return error
            }
        }

        var attemptCount: Int { lock.withLock { attempts } }
    }

    static let state = State()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let error = Self.state.next() {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        guard
            let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class URLSessionTransportTests: XCTestCase {

    private var request: URLRequest {
        URLRequest(url: URL(string: "https://example.invalid/auth/v1/token")!)
    }

    private func makeTransport() -> URLSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FlakyURLProtocol.self]
        return URLSessionTransport(session: URLSession(configuration: configuration))
    }

    /// The reported bug. URLSession keeps connections pooled and hands one
    /// back after the far end has quietly closed it; the request fails with
    /// -1005 before anything is written, and the user — who was never offline
    /// — is told to check their connection.
    func testReplaysARequestWhoseConnectionWasAlreadyDead() async throws {
        FlakyURLProtocol.state.reset(failures: 1, error: URLError(.networkConnectionLost))

        let (_, response) = try await makeTransport().send(request)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(FlakyURLProtocol.state.attemptCount, 2, "the dead connection should have been retried")
    }

    /// Once, not forever. A connection that dies twice running is a real
    /// failure, and hiding it behind retries only delays saying so.
    func testGivesUpAfterASingleReplay() async {
        FlakyURLProtocol.state.reset(failures: 2, error: URLError(.networkConnectionLost))

        do {
            _ = try await makeTransport().send(request)
            XCTFail("expected the second failure to propagate")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
        XCTAssertEqual(FlakyURLProtocol.state.attemptCount, 2)
    }

    /// A genuine outage is reported straight away. Retrying it would only make
    /// "you're offline" arrive twice as slowly, and it is the honest answer.
    func testDoesNotReplayAGenuineOutage() async {
        FlakyURLProtocol.state.reset(failures: 1, error: URLError(.notConnectedToInternet))

        do {
            _ = try await makeTransport().send(request)
            XCTFail("expected the offline failure to propagate")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        XCTAssertEqual(FlakyURLProtocol.state.attemptCount, 1)
    }
}
