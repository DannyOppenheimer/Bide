import Foundation

/// Every user-visible time string Bide produces.
///
/// Centralised because the same phrase appears in three places that can't
/// share a view — the tile in the transcript, the app, and the Live Activity —
/// and three drifting copies of "Leave in 10 minutes" would be obvious.
public enum BideFormat {

    // MARK: - Dates

    /// "May 7th" — or "Today" / "Tomorrow" when it's one of those.
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

    /// "3:30 PM", in the user's own 12/24-hour setting.
    public static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// The tile's second line: "May 7th · 3:30 pm", or "As soon as everyone
    /// can" when no time was set.
    public static func schedule(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "As soon as everyone can" }
        return "\(day(date, now: now)) · \(time(date))"
    }

    // MARK: - Durations

    /// "45 minutes", "1 hr 5 min", "Under a minute".
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

    /// What the countdown says: "Leave now", "Leave in 10 minutes", or —
    /// once it's far enough out that a countdown is useless — "Leave tomorrow
    /// at 3:00 PM".
    public static func leavePhrase(at departure: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let interval = departure.timeIntervalSince(now)

        if interval <= 60 { return "Leave now" }
        if interval < 60 * 60 { return "Leave in \(duration(interval))" }

        let dayPart = day(departure, now: now, calendar: calendar).lowercased()
        return "Leave \(dayPart) at \(time(departure))"
    }

    /// How a person's own line reads in the roster: their ETA, or that they
    /// haven't set off.
    public static func participantStatus(_ participant: Participant, now: Date = Date()) -> String {
        switch participant.status {
        case .invited: "Waiting..."
        case .declined: "Not coming"
        case .arrived: "Arrived"
        case .accepted:
            participant.etaTimestamp.map { duration($0.timeIntervalSince(now)) } ?? "Waiting..."
        }
    }

    // MARK: - Names

    /// What to call someone who never set a name. Used rather than inventing
    /// one, and rather than showing a raw identifier.
    public static let anonymousName = "Someone"

    /// What to call the person reading the screen. Wins over their own display
    /// name: a roster is read to find out where everyone *else* has got to, and
    /// "You" is what makes your own row skimmable.
    public static let selfName = "You"

    /// - Parameter me: The local user's id, when the caller knows it. Anywhere
    ///   the reader could be in the list — a roster, the Live Activity — pass
    ///   it, or an anonymous user sees themselves as "Someone".
    public static func name(_ participant: Participant, me: UUID? = nil) -> String {
        if participant.userID == me { return selfName }
        let trimmed = participant.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false ? trimmed : nil) ?? anonymousName
    }

    /// The single letter in the avatar circle.
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
