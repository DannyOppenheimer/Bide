import Foundation
import MapKit

/// One row in the location search results.
///
/// Not `Sendable`: it carries the `MKLocalSearchCompletion` it came from, and
/// that isn't. It doesn't need to be — suggestions are main-actor UI state
/// from the moment they exist until the moment they're resolved.
public struct PlaceSuggestion: Identifiable, Equatable {

    public let id: String
    /// "Nats Park".
    public let title: String
    /// "1500 South Capitol St SE, Washington, DC".
    public let subtitle: String

    /// The completion this came from, kept so it can be resolved to
    /// coordinates without re-running the search. Not `Sendable`, so this type
    /// stays main-actor-bound in practice — which it is, being UI state.
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

/// Where-are-we-going search, on Apple Maps' own index.
///
/// `MKLocalSearchCompleter` for the as-you-type list, then `MKLocalSearch` to
/// turn the chosen row into coordinates. Both the container app and the
/// Messages extension use this — searching for a place is one of the few
/// things an .appex is allowed to do.
@MainActor
@Observable
public final class PlaceSearchService: NSObject {

    /// What the user has typed. Assigning restarts the search.
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
        // Places and addresses only. `.query` would offer things like "coffee
        // near me", which can't be resolved to one destination.
        completer.resultTypes = [.pointOfInterest, .address]
        completer.delegate = self
    }

    /// Biases results towards where the user is, so "the park" means the one
    /// down the road. Optional — search works without it.
    public func focus(on coordinate: CLLocationCoordinate2D, radius: CLLocationDistance = 50_000) {
        completer.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: radius, longitudinalMeters: radius)
    }

    /// Turns a chosen row into a real destination with coordinates.
    public func resolve(_ suggestion: PlaceSuggestion) async throws -> Destination {
        guard let completion = suggestion.completion else {
            throw PlaceSearchError.notResolvable
        }

        let response = try await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
        guard let item = response.mapItems.first else {
            throw PlaceSearchError.notResolvable
        }

        // The completion's own title is what the user tapped, so it reads
        // better on a tile than whatever the map item is called internally.
        return Destination(name: suggestion.title, coordinate: item.placemark.coordinate)
    }

    public func clear() {
        query = ""
        suggestions = []
        failed = false
    }
}

public enum PlaceSearchError: Error, Sendable {
    /// The chosen row has no coordinates behind it.
    case notResolvable
}

// MARK: - MKLocalSearchCompleterDelegate

extension PlaceSearchService: MKLocalSearchCompleterDelegate {

    // The completer delivers on the queue it was created on, which is the main
    // queue — this class is main-actor bound. Both methods reach for
    // `self.completer` rather than the parameter, which is the same object but
    // would have to cross an isolation boundary to be used in here.
    nonisolated public func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            suggestions = self.completer.results.map(PlaceSuggestion.init(completion:))
            failed = false
        }
    }

    nonisolated public func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        // Every keystroke cancels the previous request; that isn't a failure
        // worth showing anyone.
        let throttled = (error as? MKError)?.code == .loadingThrottled
        MainActor.assumeIsolated {
            guard !throttled else { return }
            suggestions = []
            failed = true
        }
    }
}
