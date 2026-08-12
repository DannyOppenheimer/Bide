import SwiftUI
import BideKit

/// The tile as it appears in a Messages thread.
///
/// One layout carries every state in the reference screens — a glyph on the
/// left, one or two centred lines beside it — because they are the same tile
/// at different moments, and a bubble that changes shape as its status changes
/// reads as a different message rather than the same one.
public struct BideTileView: View {

    /// What sits on the left: the vertical wordmark, or the travel mode once
    /// there's a journey to describe.
    public enum Glyph: Equatable {
        case mark
        case mode(TravelMode)
    }

    private let glyph: Glyph
    private let title: String
    private let subtitle: String?
    /// A live countdown, when the tile has one — rendered with the system's
    /// self-updating relative text so it stays honest in the transcript,
    /// where nothing else is running.
    private let countdownTo: Date?

    public init(glyph: Glyph = .mark, title: String, subtitle: String? = nil, countdownTo: Date? = nil) {
        self.glyph = glyph
        self.title = title
        self.subtitle = subtitle
        self.countdownTo = countdownTo
    }

    public var body: some View {
        HStack(spacing: 14) {
            leading
                .frame(width: 26, alignment: .leading)

            VStack(spacing: 2) {
                Group {
                    if let countdownTo {
                        // "Leave in 5 minutes", kept current by the system.
                        Text("Leave \(Text(countdownTo, style: .relative))")
                    } else {
                        Text(title)
                    }
                }
                .font(BideFont.cardTitle)
                .foregroundStyle(BideColor.primaryText)

                if let subtitle {
                    Text(subtitle)
                        .font(BideFont.caption)
                        .foregroundStyle(BideColor.secondaryText)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(BideColor.background, in: RoundedRectangle(cornerRadius: BideMetrics.tileRadius, style: .continuous))
    }

    @ViewBuilder
    private var leading: some View {
        switch glyph {
        case .mark:
            BideMark(.vertical, dotDiameter: 7)
        case .mode(let mode):
            Image(systemName: mode.symbolName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(BideColor.primaryText)
        }
    }
}

extension BideTileView {

    /// Builds the tile for a bide, from what the transcript can actually know:
    /// the invite in the message URL, who sent it, and whatever answer this
    /// device has given. There is no server call here — a transcript view is
    /// rendered by Messages, not by us, and must be cheap.
    public static func transcript(
        invite: BideInvite,
        senderName: String?,
        role: ParticipantRole,
        answer: ParticipantStatus?,
        leaveAt: Date? = nil,
        now: Date = Date()
    ) -> BideTileView {
        let schedule = BideFormat.schedule(invite.scheduledFor, now: now)

        switch answer {
        case .declined:
            return BideTileView(title: "You denied this request")

        case .accepted, .arrived:
            if let leaveAt, leaveAt > now {
                return BideTileView(
                    glyph: .mode(.driving),
                    title: "",
                    subtitle: invite.destinationName,
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
