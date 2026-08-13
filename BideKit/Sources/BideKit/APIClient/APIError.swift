import Foundation

/// Typed failures returned by ``BideAPI``.
public enum APIError: Error, Equatable, Sendable {

    /// The session is missing or was rejected with HTTP 401.
    case notAuthenticated

    /// Row-level security rejected the request with HTTP 403.
    case notPermitted

    /// The bide does not exist or is hidden by row-level security.
    case notFound

    /// The write collided with an existing row (409).
    case conflict

    /// HTTP 429, with the server's optional retry hint.
    case rateLimited(retryAfter: TimeInterval?)

    /// The server failed or returned an unsupported response.
    case serverError(status: Int, message: String?)

    /// The request did not complete because of a network-layer failure.
    case transport(URLError)

    /// The server returned an unexpected response.
    case invalidResponse(String)

    /// A response body did not match its expected model.
    case decodingFailed(String)

    /// A request body could not be encoded.
    case encodingFailed(String)

    /// The client configuration cannot produce a valid request.
    case invalidConfiguration(String)
}

extension APIError: LocalizedError {

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            "You're signed out. Sign in to keep sharing your ETA."
        case .notPermitted:
            "You don't have access to this meetup."
        case .notFound:
            "That meetup is no longer available."
        case .conflict:
            "That meetup was already updated somewhere else."
        case .rateLimited:
            "Too many updates at once. Try again in a moment."
        case .serverError:
            "Bide's server had a problem. Try again shortly."
        case .transport:
            "Couldn't reach Bide. Check your connection."
        case .invalidResponse, .decodingFailed, .encodingFailed, .invalidConfiguration:
            "Something went wrong talking to Bide."
        }
    }

    /// Whether the request was intentionally cancelled by its caller.
    public var isCancellation: Bool {
        guard case .transport(let error) = self else { return false }
        return error.code == .cancelled
    }

    /// Whether retrying the same request might succeed.
    public var isRetryable: Bool {
        switch self {
        case .transport, .rateLimited, .serverError:
            true
        case .notAuthenticated, .notPermitted, .notFound, .conflict,
             .invalidResponse, .decodingFailed, .encodingFailed, .invalidConfiguration:
            false
        }
    }
}

/// Error payload returned by PostgREST.
struct PostgRESTError: Decodable, Equatable {
    let code: String?
    let message: String?
    let details: String?
    let hint: String?
}
