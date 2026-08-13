import CoreLocation
import EventKit
import Foundation
import BideKit

/// Converts opted-in calendar events with locations into solo-bide drafts.
@MainActor
final class CalendarScanner {

    /// Future calendar window scanned for candidate events.
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

    /// Requests full event access because EventKit offers no read-only query grant.
    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Returns unconverted upcoming events whose locations can be resolved.
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

    /// Marks an event as converted so later scans skip it.
    func markConverted(_ eventID: String) {
        defaults.set(Array(converted.union([eventID])), forKey: Self.convertedKey)
    }

    private var converted: Set<String> {
        Set(defaults.stringArray(forKey: Self.convertedKey) ?? [])
    }

    /// Uses EventKit coordinates when present, otherwise geocodes the location text.
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
