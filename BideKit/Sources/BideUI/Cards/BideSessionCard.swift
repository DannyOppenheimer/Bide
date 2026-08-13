import SwiftUI
import BideKit

/// An active bide, as it appears in the app's session list and — the same
/// component, deliberately — on the lock screen.
///
/// The design brief asks for the in-app feed to "copy the live activity feed",
/// so the two are one view rather than two that drift.
public struct BideSessionCard: View {

    private let headline: String
    /// Where the bide is going. The headline is about *time* — "Leave in 10
    /// minutes" — and on its own it leaves the reader to remember what for, so
    /// the place gets a line of its own rather than being implied.
    private let destination: String?
    private let participants: [Participant]
    /// The local user's id, so their own place in the roster reads "You".
    private let me: UUID?
    private let isLive: Bool
    private let showsBadge: Bool
    private let now: Date
    /// Nil in the Live Activity, where the whole card is the tap target.
    private let onTap: (() -> Void)?

    public init(
        headline: String,
        destination: String? = nil,
        participants: [Participant],
        me: UUID? = nil,
        isLive: Bool = false,
        showsBadge: Bool = true,
        now: Date = Date(),
        onTap: (() -> Void)? = nil
    ) {
        self.headline = headline
        self.destination = destination
        self.participants = participants
        self.me = me
        self.isLive = isLive
        self.showsBadge = showsBadge
        self.now = now
        self.onTap = onTap
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
            participants: state.participants.filter { $0.status != .declined },
            me: me,
            isLive: state.travellers.contains { $0.etaTimestamp != nil },
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
            ZStack(alignment: .topLeading) {
                VStack(spacing: 6) {
                    BideMark(.horizontal, dotDiameter: 7)
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
                }
                .frame(maxWidth: .infinity)

                if showsBadge && isLive {
                    LivePill()
                }
            }

            if !participants.isEmpty {
                roster
            }
        }
        .bideCard()
    }

    /// Up to four across; more than that wraps, which is the honest answer to
    /// a group bide until the "how do we handle large groups" question in the
    /// design notes is settled.
    private var roster: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 12),
                count: min(max(participants.count, 1), 4)
            ),
            spacing: 14
        ) {
            ForEach(participants) { participant in
                ParticipantTile(participant: participant, me: me, now: now)
            }
        }
    }

    /// "Leave in 10 minutes" / "Leave tomorrow at 3:00 PM" / "Waiting for
    /// everyone to answer". Never the destination — that has its own line now,
    /// so naming it here would only say it twice.
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
            status: .accepted
        ),
    ]

    return VStack(spacing: 16) {
        BideSessionCard(
            headline: "Leave in 10 minutes",
            destination: "Nats Park",
            participants: participants,
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
