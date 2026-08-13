import SwiftUI
import BideKit

/// The tile as it appears in a Messages thread.
///
/// One layout carries every state in the reference screens — a glyph on the
/// left, one or two centred lines beside it — because they are the same tile
/// at different moments, and a bubble that changes shape as its status changes
/// reads as a different message rather than the same one.
public struct BideTileView: View {

    private let title: String
    private let subtitle: String?
    /// The travel mode, once there is a journey to describe. Sits beside the
    /// countdown rather than in a column of its own — the mark has the top of
    /// the tile now, and a lone icon out to the left of centred text only made
    /// the tile look lopsided.
    private let mode: TravelMode?
    /// A live countdown, when the tile has one — rendered with the system's
    /// self-updating relative text so it stays honest in the transcript,
    /// where nothing else is running.
    private let countdownTo: Date?

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
    }

    public var body: some View {
        VStack(spacing: 10) {
            // The mark, horizontal, on every tile — sent, received, answered.
            // It used to be the vertical form down the left-hand side, which
            // existed only as the collapsed half of a morph between the two
            // forms. With that animation gone it was just a second logo, and
            // the worse one.
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
                            // "Leave in 5 minutes", kept current by the system.
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
            // Grow downwards rather than truncate. A bubble in the transcript
            // is laid out at whatever width Messages decides, which is narrow
            // enough that "Today · 3:30 PM • Waiting for replies" does not fit
            // on one line — and half a sentence is worse than two lines.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 18)
        // Messages stamps the app's badge over the tile's top-left corner. The
        // extra top padding is what keeps it off the mark instead of over it.
        .padding(.top, 16 + BideMetrics.tileBadgeClearance)
        .padding(.bottom, 16)
        .background(BideColor.background, in: RoundedRectangle(cornerRadius: BideMetrics.tileRadius, style: .continuous))
    }
}

extension BideTileView {

    /// Builds the tile for a bide, from what the transcript can actually know:
    /// the invite in the message URL, who sent it, and whatever answer this
    /// device has given. There is no server call here — a transcript view is
    /// rendered by Messages, not by us, and must be cheap.
    /// - Parameter mode: How this device said it would travel, when it has
    ///   said. Shown beside the countdown; nil simply leaves it off, which is
    ///   what the fallback snapshot and anyone else's tile get.
    public static func transcript(
        invite: BideInvite,
        senderName: String?,
        role: ParticipantRole,
        answer: ParticipantStatus?,
        leaveAt: Date? = nil,
        mode: TravelMode? = nil,
        now: Date = Date()
    ) -> BideTileView {
        let schedule = BideFormat.schedule(invite.scheduledFor, now: now)

        switch answer {
        case .declined:
            return BideTileView(title: "You denied this request")

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
