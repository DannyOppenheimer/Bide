import Foundation
import MapKit

/// One place-search result. It remains main-actor state because its MapKit
/// completion is not `Sendable`.
public struct PlaceSuggestion: Identifiable, Equatable {

    public let id: String
    /// "Nats Park".
    public let title: String
    /// "1500 South Capitol St SE, Washington, DC".
    public let subtitle: String

    /// Original completion retained for coordinate resolution.
    let completion: MKLocalSearchCompletion?

    init(completion: MKLocalSearchCompletion) {
        self.id = completion.title + "|" + completion.subtitle
        self.title = completion.title
        self.subtitle = completion.subtitle
        self.completion = completion
    }

    /// For previews and tests.
    public init(id: String = UUID().uuidString, title: String, subtitle: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.completion = nil
    }

    public static func == (lhs: PlaceSuggestion, rhs: PlaceSuggestion) -> Bool {
        lhs.id == rhs.id
    }
}

/// Uses MapKit completion for suggestions and local search for coordinate resolution.
@MainActor
@Observable
public final class PlaceSearchService: NSObject {

    /// Current query; assigning it refreshes suggestions.
    public var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                suggestions = []
                completer.cancel()
            } else {
                completer.queryFragment = trimmed
            }
        }
    }

    public private(set) var suggestions: [PlaceSuggestion] = []
    public private(set) var failed = false

    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    public override init() {
        super.init()
        // Restrict results to entries that resolve to one destination.
        completer.resultTypes = [.pointOfInterest, .address]
        completer.delegate = self
    }

    /// Optionally biases results toward a coordinate.
    public func focus(on coordinate: CLLocationCoordinate2D, radius: CLLocationDistance = 50_000) {
        completer.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: radius, longitudinalMeters: radius)
    }

    /// Resolves a suggestion to a destination with coordinates.
    public func resolve(_ suggestion: PlaceSuggestion) async throws -> Destination {
        guard let completion = suggestion.completion else {
            throw PlaceSearchError.notResolvable
        }

        let response = try await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
        guard let item = response.mapItems.first else {
            throw PlaceSearchError.notResolvable
        }

        // Preserve the title selected by the user.
        return Destination(name: suggestion.title, coordinate: item.placemark.coordinate)
    }

    public func clear() {
        query = ""
        suggestions = []
        failed = false
    }
}

public enum PlaceSearchError: Error, Sendable {
    /// The selected suggestion could not be resolved to coordinates.
    case notResolvable
}

// MARK: - MKLocalSearchCompleterDelegate

extension PlaceSearchService: MKLocalSearchCompleterDelegate {

    // The main actor creates the completer, so its delegate callbacks run on the
    // main queue. Use the isolated property instead of crossing the parameter.
    nonisolated public func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            suggestions = self.completer.results.map(PlaceSuggestion.init(completion:))
            failed = false
        }
    }

    nonisolated public func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        // Query replacement commonly triggers throttling and should not show an error.
        let throttled = (error as? MKError)?.code == .loadingThrottled
        MainActor.assumeIsolated {
            guard !throttled else { return }
            suggestions = []
            failed = true
        }
    }
}
