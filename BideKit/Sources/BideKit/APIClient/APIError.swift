import Foundation

/// Everything ``BideAPI`` can fail with. Exhaustive on purpose: callers switch
/// over this to decide whether to retry, re-authenticate, or show the user
/// something, and a stringly-typed error makes that a guessing game.
public enum APIError: Error, Equatable, Sendable {

    /// No signed-in session, or the server rejected the one we sent (401).
    /// Refresh the session and retry.
    case notAuthenticated

    /// The request was refused by row-level security (403). Retrying without
    /// changing anything will fail the same way.
    case notPermitted

    /// No such bide, or one you can't see. Row-level security deliberately
    /// makes those two cases indistinguishable — a bide you aren't part of
    /// reads as absent rather than forbidden, which is the point.
    case notFound

    /// The write collided with an existing row (409).
    case conflict

    /// Too many requests (429), with the server's retry hint when it gave one.
    case rateLimited(retryAfter: TimeInterval?)

    /// The server failed or answered in a way we don't handle.
    case serverError(status: Int, message: String?)

    /// The request never completed: offline, timed out, cancelled, TLS failure.
    /// Generally worth retrying.
    case transport(URLError)

    /// The server answered, but not with what we expected.
    case invalidResponse(String)

    /// A response body didn't match the model we decode it into.
    case decodingFailed(String)

    /// A request body couldn't be encoded. A programming error, not a runtime
    /// condition.
    case encodingFailed(String)

    /// The client is misconfigured — a project URL that can't form a valid
    /// endpoint, for instance.
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

    /// Whether retrying the identical request could plausibly succeed.
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

/// The error shape PostgREST returns, used to sharpen a bare status code into
/// something specific.
struct PostgRESTError: Decodable, Equatable {
    let code: String?
    let message: String?
    let details: String?
    let hint: String?
}
