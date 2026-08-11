import Foundation

/// Talks to the Bide server. Only ever transmits an arrival TIMESTAMP,
/// never a location — see the privacy commitment in the project README.
public protocol APIClient {
    func submitArrival(timestamp: Date, forTileID id: UUID) async throws
}

/// Placeholder implementation with no networking wired up yet.
public final class PlaceholderAPIClient: APIClient {
    public init() {}

    public func submitArrival(timestamp: Date, forTileID id: UUID) async throws {
        // TODO: wire up to the real backend.
    }
}
