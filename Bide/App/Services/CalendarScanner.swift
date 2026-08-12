import CoreLocation
import EventKit
import Foundation
import BideKit

/// Turns calendar events that have a location into solo bides.
///
/// Opt-in, and off by default: this reads someone's calendar, so it happens
/// only after they ask for it in Settings. Events without a location are
/// ignored — there's nothing to route to — and each event is converted at most
/// once.
@MainActor
final class CalendarScanner {

    /// How far ahead to look. A day is enough for "when do I leave?" and short
    /// enough that the list stays relevant.
    private static let horizon: TimeInterval = 24 * 60 * 60
    private static let convertedKey = "bide.calendar.converted"

    private let store = EKEventStore()
    private let geocoder = CLGeocoder()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Asks for calendar access. Read-only would be ideal, but EventKit's
    /// only read grant for querying events is full access.
    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Upcoming events with a location, as drafts ready to become solo bides.
    /// Geocoding is what turns an event's free-text location into somewhere
    /// routable, and anything that can't be geocoded is skipped rather than
    /// guessed at.
    func upcomingDrafts(now: Date = Date(), limit: Int = 5) async -> [(eventID: String, draft: BidePlanDraft)] {
        guard isAuthorized else { return [] }

        let predicate = store.predicateForEvents(
            withStart: now,
            end: now.addingTimeInterval(Self.horizon),
            calendars: nil
        )

        var drafts: [(String, BidePlanDraft)] = []
        for event in store.events(matching: predicate).sorted(by: { $0.startDate < $1.startDate }) {
            guard drafts.count < limit else { break }
            guard
                let identifier = event.eventIdentifier,
                !converted.contains(identifier),
                let destination = await destination(for: event)
            else { continue }

            drafts.append((
                identifier,
                BidePlanDraft(destination: destination, mode: .driving, scheduledFor: event.startDate)
            ))
        }
        return drafts
    }

    /// Records that an event has become a bide, so a later scan doesn't make
    /// a second one.
    func markConverted(_ eventID: String) {
        defaults.set(Array(converted.union([eventID])), forKey: Self.convertedKey)
    }

    private var converted: Set<String> {
        Set(defaults.stringArray(forKey: Self.convertedKey) ?? [])
    }

    /// Prefers the coordinates EventKit already has; falls back to geocoding
    /// the location text.
    private func destination(for event: EKEvent) async -> Destination? {
        let name = event.structuredLocation?.title ?? event.location
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        if let coordinate = event.structuredLocation?.geoLocation?.coordinate {
            return Destination(name: name, coordinate: coordinate)
        }

        guard let placemark = try? await geocoder.geocodeAddressString(name).first,
              let coordinate = placemark.location?.coordinate
        else { return nil }

        return Destination(name: name, coordinate: coordinate)
    }
}
