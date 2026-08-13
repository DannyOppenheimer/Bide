import Foundation

/// Shared formatting for user-visible dates, durations, statuses, and names.
public enum BideFormat {

    // MARK: - Dates

    /// Formats a date as "Today", "Tomorrow", or a month and ordinal day.
    public static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow"
        }

        let month = date.formatted(.dateTime.month(.wide).locale(.current))
        let dayNumber = calendar.component(.day, from: date)
        return "\(month) \(ordinal(dayNumber))"
    }

    /// Formats a time using the user's locale and 12/24-hour preference.
    public static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Formats a group schedule, treating missing or past dates as soon as possible.
    public static func schedule(_ date: Date?, now: Date = Date()) -> String {
        guard let date, date > now else { return "As soon as everyone can" }
        return "\(day(date, now: now)) · \(time(date))"
    }

    /// Formats a solo-trip schedule from a watcher's perspective.
    public static func soloSchedule(_ date: Date?, now: Date = Date()) -> String {
        guard let date, date > now else { return "As soon as they can" }
        return "\(day(date, now: now)) · \(time(date))"
    }

    // MARK: - Durations

    /// Formats a duration for general display, such as "45 minutes".
    public static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, interval)
        if seconds < 60 { return "Under a minute" }

        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 {
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        }

        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
    }

    /// Formats a duration for the narrower roster layout, such as "14 min".
    public static func shortDuration(_ interval: TimeInterval) -> String {
        let seconds = max(0, interval)
        if seconds < 60 { return "Under a min" }

        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }

        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
    }

    /// Formats a duration for the compact Dynamic Island slot, such as "14m".
    public static func compactDuration(_ interval: TimeInterval) -> String {
        let minutes = Int((max(0, interval) / 60).rounded())
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }

    // MARK: - Participant status text

    /// Formats the scheduled arrival label.
    public static func scheduledLine(_ date: Date) -> String {
        "Scheduled ETA: \(time(date))"
    }

    /// Formats the current projected arrival label.
    public static func actualLine(_ date: Date) -> String {
        "Actual: \(time(date))"
    }

    /// Labels the projected arrival only when a scheduled time exists for comparison.
    /// - Parameter scheduled: The scheduled arrival time, or `nil` for an ASAP bide.
    public static func arrivalLine(_ date: Date, comparedTo scheduled: Date?) -> String {
        scheduled == nil ? time(date) : actualLine(date)
    }

    /// Formats a departure as an immediate instruction, countdown, or date and time.
    public static func leavePhrase(at departure: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let interval = departure.timeIntervalSince(now)

        if interval <= 60 { return "Leave now" }
        if interval < 60 * 60 { return "Leave in \(duration(interval))" }

        let dayPart = day(departure, now: now, calendar: calendar).lowercased()
        return "Leave \(dayPart) at \(time(departure))"
    }

    /// Formats a participant's journey state for the roster and accessibility labels.
    public static func participantStatus(_ participant: Participant, now: Date = Date()) -> String {
        switch participant.status {
        case .invited: "Waiting..."
        case .declined: "Not coming"
        case .arrived: "Arrived"
        // Watchers are normally absent from rosters but still need accessible text.
        case .watching: "Following along"
        case .accepted:
            participant.remainingTravel(now: now).map(duration) ?? "Waiting..."
        }
    }

    // MARK: - Names

    /// Display name used when a participant has no profile name.
    public static let anonymousName = "Someone"

    /// Display name used for the local participant.
    public static let selfName = "You"

    /// - Parameter me: The local user's identifier, when available.
    public static func name(_ participant: Participant, me: UUID? = nil) -> String {
        if participant.userID == me { return selfName }
        let trimmed = participant.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false ? trimmed : nil) ?? anonymousName
    }

    /// Returns the first display-name character for an avatar.
    public static func initial(_ participant: Participant, me: UUID? = nil) -> String {
        String(name(participant, me: me).prefix(1)).uppercased()
    }

    // MARK: - Private

    private static func ordinal(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
