import SwiftUI
import BideKit

/// Shared active-session card used in the app and on the Lock Screen.
public struct BideSessionCard: View {

    private let headline: String
    /// Destination displayed separately from the timing headline.
    private let destination: String?
    /// Note shown when other sessions share this journey, such as
    /// "1 of 2 groups going here".
    private let companionNote: String?
    private let participants: [Participant]
    /// Local user identifier used to label their roster entry as "You".
    private let me: UUID?
    /// Shared scheduled arrival, or `nil` for an ASAP bide.
    private let scheduledArrival: Date?
    private let isLive: Bool
    private let showsBadge: Bool
    /// Whether the local user is following rather than attending.
    private let isWatching: Bool
    private let now: Date
    /// Optional tap action; the containing Live Activity handles taps itself.
    private let onTap: (() -> Void)?
    /// Optional share action for a solo bide.
    private let onShare: (() -> Void)?

    public init(
        headline: String,
        destination: String? = nil,
        companionNote: String? = nil,
        participants: [Participant],
        me: UUID? = nil,
        scheduledArrival: Date? = nil,
        isLive: Bool = false,
        showsBadge: Bool = true,
        isWatching: Bool = false,
        now: Date = Date(),
        onTap: (() -> Void)? = nil,
        onShare: (() -> Void)? = nil
    ) {
        self.headline = headline
        self.destination = destination
        self.companionNote = companionNote
        self.participants = participants
        self.me = me
        self.scheduledArrival = scheduledArrival
        self.isLive = isLive
        self.showsBadge = showsBadge
        self.isWatching = isWatching
        self.now = now
        self.onTap = onTap
        self.onShare = onShare
    }

    public init(
        state: BideState,
        me: UUID? = nil,
        leaveAt: Date?,
        now: Date = Date(),
        onTap: (() -> Void)? = nil
    ) {
        self.init(
            headline: Self.headline(for: state, leaveAt: leaveAt, now: now),
            destination: state.destinationName,
            companionNote: nil,
            participants: state.roster,
            me: me,
            scheduledArrival: state.scheduledFor,
            // Mark the session live only after a traveller has departed.
            isLive: state.travellers.contains(where: \.hasLeft),
            now: now,
            onTap: onTap
        )
    }

    public var body: some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { onTap?() }
            .accessibilityElement(children: .contain)
    }

    private var content: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                heading
                Text(headline)
                    .font(BideFont.cardTitle)
                    .foregroundStyle(BideColor.primaryText)
                    .multilineTextAlignment(.center)
                if let destination, !destination.isEmpty {
                    Text(destination)
                        .font(BideFont.caption)
                        .foregroundStyle(BideColor.secondaryText)
                        .multilineTextAlignment(.center)
                }
                if let companionNote, !companionNote.isEmpty {
                    Text(companionNote)
                        .font(BideFont.caption)
                        .foregroundStyle(BideColor.secondaryText.opacity(0.75))
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)

            if !participants.isEmpty {
                roster
            }
        }
        .bideCard()
        // Reinforce watcher state with a subtle, non-warning border.
        .overlay {
            if isWatching {
                RoundedRectangle(cornerRadius: BideMetrics.cardRadius, style: .continuous)
                    .strokeBorder(BideColor.watching.opacity(0.55), lineWidth: 1.5)
            }
        }
    }

    /// The mark, with the badge and share control beside it.
    ///
    /// One row rather than an overlay: floating the badge over the centred stack
    /// let a headline that wrapped run underneath it, and a short card had no
    /// spare height for it to run into. Laid out as a row, the badge sets the
    /// row's height and the headline always begins below it.
    private var heading: some View {
        ZStack {
            BideMark(.horizontal, dotDiameter: 7)

            if showsBadge {
                // The watcher badge takes priority over the movement badge.
                Group {
                    if isWatching {
                        WatchingPill()
                    } else if isLive {
                        LivePill()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let onShare {
                Button(action: onShare) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(BideColor.secondaryText)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share this Bide so someone can track it")
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// Displays up to three participant tiles per row to keep ETA labels legible.
    private var roster: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 12),
                count: min(max(participants.count, 1), 3)
            ),
            spacing: 14
        ) {
            ForEach(participants) { participant in
                ParticipantTile(
                    participant: participant,
                    me: me,
                    scheduledArrival: scheduledArrival,
                    now: now
                )
            }
        }
    }

    /// Builds a reduced headline for surfaces that do not run ``BidePlanner``.
    /// - Parameter leaveAt: The local user's future departure time, if available.
    static func headline(for state: BideState, leaveAt: Date?, now: Date) -> String {
        if state.isComplete { return "Everyone's here" }
        if let leaveAt { return BideFormat.leavePhrase(at: leaveAt, now: now) }
        if state.isAwaitingAnswers { return "Waiting for everyone to answer" }
        return "Nobody has set off yet"
    }
}

#Preview {
    let participants = [
        Participant(userID: UUID(), displayName: "Sarah", mode: .driving, status: .accepted),
        Participant(userID: UUID(), displayName: "John", mode: .driving, status: .accepted),
        Participant(
            userID: UUID(),
            displayName: "Michael",
            mode: .transit,
            etaTimestamp: Date().addingTimeInterval(45 * 60),
            baselineETA: Date().addingTimeInterval(40 * 60),
            travelTime: 45 * 60,
            leftAt: Date().addingTimeInterval(-5 * 60),
            status: .accepted
        ),
    ]

    return VStack(spacing: 16) {
        BideSessionCard(
            headline: "Leave in 10 minutes",
            destination: "Nats Park",
            participants: participants,
            scheduledArrival: Date().addingTimeInterval(50 * 60),
            isLive: true
        )
        BideSessionCard(
            headline: "Leave tomorrow at 3:00 PM",
            destination: "Union Market",
            participants: Array(participants.prefix(2)),
            isLive: false
        )
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .bideBackground()
}
