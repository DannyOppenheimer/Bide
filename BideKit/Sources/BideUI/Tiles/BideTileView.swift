import SwiftUI
import BideKit

/// A Messages transcript tile that preserves one layout across invitation states.
public struct BideTileView: View {

    private let title: String
    private let subtitle: String?
    /// Travel mode displayed beside an active countdown.
    private let mode: TravelMode?
    /// Departure date rendered with system-updating relative text.
    private let countdownTo: Date?
    /// Whether the meetup is over and the tile is drawn collapsed.
    private let isSpent: Bool

    public init(
        title: String,
        subtitle: String? = nil,
        mode: TravelMode? = nil,
        countdownTo: Date? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.mode = mode
        self.countdownTo = countdownTo
        self.isSpent = false
    }

    /// Builds a compact expired tile because Messages cannot remove sent bubbles.
    public init(spent title: String) {
        self.title = title
        self.subtitle = nil
        self.mode = nil
        self.countdownTo = nil
        self.isSpent = true
    }

    public var body: some View {
        if isSpent { spent } else { full }
    }

    private var spent: some View {
        Text(title)
            .font(BideFont.caption)
            .foregroundStyle(BideColor.secondaryText.opacity(0.7))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            // Preserve top clearance for Messages' app badge.
            .padding(.top, 8 + BideMetrics.tileBadgeClearance)
            .padding(.bottom, 8)
            .background(
                BideColor.background,
                in: RoundedRectangle(cornerRadius: BideMetrics.tileRadius, style: .continuous)
            )
    }

    private var full: some View {
        VStack(spacing: 10) {
            // Use the same horizontal mark for every tile state.
            BideMark(.horizontal, dotDiameter: 6)

            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    if let mode {
                        Image(systemName: mode.symbolName)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(BideColor.primaryText)
                    }

                    Group {
                        if let countdownTo {
                            // The system keeps the relative departure text current.
                            Text("Leave \(Text(countdownTo, style: .relative))")
                        } else {
                            Text(title)
                        }
                    }
                    .font(BideFont.cardTitle)
                    .foregroundStyle(BideColor.primaryText)
                }

                if let subtitle {
                    Text(subtitle)
                        .font(BideFont.caption)
                        .foregroundStyle(BideColor.secondaryText)
                }
            }
            .multilineTextAlignment(.center)
            // Allow narrow Messages bubbles to wrap instead of truncating status text.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 18)
        // Extra top padding clears Messages' app badge.
        .padding(.top, 16 + BideMetrics.tileBadgeClearance)
        .padding(.bottom, 16)
        .background(BideColor.background, in: RoundedRectangle(cornerRadius: BideMetrics.tileRadius, style: .continuous))
    }
}

extension BideTileView {

    /// Builds a transcript tile entirely from URL and local state, without server access.
    /// - Parameter mode: Local travel mode, shown beside a countdown when available.
    /// - Parameter isTrackingInvite: Whether the tile offers journey tracking instead of attendance.
    public static func transcript(
        invite: BideInvite,
        senderName: String?,
        role: ParticipantRole,
        answer: ParticipantStatus?,
        leaveAt: Date? = nil,
        mode: TravelMode? = nil,
        isTrackingInvite: Bool = false,
        now: Date = Date()
    ) -> BideTileView {
        // Collapse expired invitations regardless of their previous state.
        if invite.hasEnded(now: now) {
            return BideTileView(spent: "Bide ended · \(invite.destinationName)")
        }

        let schedule = isTrackingInvite
            ? BideFormat.soloSchedule(invite.scheduledFor, now: now)
            : BideFormat.schedule(invite.scheduledFor, now: now)

        if isTrackingInvite {
            return tracking(
                invite: invite,
                senderName: senderName,
                role: role,
                answer: answer,
                schedule: schedule
            )
        }

        switch answer {
        case .declined:
            return BideTileView(title: "You denied this request")

        case .watching:
            // Handle malformed or legacy payloads that attach watching to a regular invite.
            return BideTileView(
                title: "You're tracking this Bide",
                subtitle: schedule
            )

        case .accepted, .arrived:
            if let leaveAt, leaveAt > now {
                return BideTileView(
                    title: "",
                    subtitle: invite.destinationName,
                    mode: mode,
                    countdownTo: leaveAt
                )
            }
            return BideTileView(
                title: "You're going to \(invite.destinationName)",
                subtitle: schedule
            )

        case .invited, .none:
            switch role {
            case .recipient:
                let who = senderName.map { "\($0) wants" } ?? "Someone wants"
                return BideTileView(
                    title: "\(who) to go to \(invite.destinationName)",
                    subtitle: "\(schedule) • Tap to accept"
                )
            case .sender, .indeterminate:
                return BideTileView(
                    title: "Meet at \(invite.destinationName)",
                    subtitle: "\(schedule) • Waiting for replies"
                )
            }
        }
    }

    /// Builds a tile offering another participant's solo journey for tracking.
    private static func tracking(
        invite: BideInvite,
        senderName: String?,
        role: ParticipantRole,
        answer: ParticipantStatus?,
        schedule: String
    ) -> BideTileView {
        let who = senderName ?? BideFormat.anonymousName

        if answer?.isWatching == true {
            return BideTileView(
                title: "You're tracking \(who)",
                subtitle: "\(schedule) • Their ETA is in your Bides"
            )
        }

        switch role {
        case .recipient:
            return BideTileView(
                title: "\(who) is going to \(invite.destinationName)",
                subtitle: "\(schedule) • Tap to track"
            )
        case .sender, .indeterminate:
            return BideTileView(
                title: "You're going to \(invite.destinationName)",
                subtitle: "\(schedule) • Shared so they can follow along"
            )
        }
    }
}

#Preview("Tile states") {
    let invite = BideInvite(
        destinationName: "Nats Park",
        lat: 38.873,
        lng: -77.007,
        scheduledFor: Date().addingTimeInterval(3 * 3600)
    )

    return VStack(spacing: 16) {
        BideTileView.transcript(invite: invite, senderName: "John", role: .recipient, answer: nil)
        BideTileView.transcript(invite: invite, senderName: "John", role: .sender, answer: nil)
        BideTileView.transcript(
            invite: invite,
            senderName: "John",
            role: .recipient,
            answer: .accepted,
            leaveAt: Date().addingTimeInterval(300)
        )
        BideTileView.transcript(invite: invite, senderName: "John", role: .recipient, answer: .declined)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(white: 0.95))
}
