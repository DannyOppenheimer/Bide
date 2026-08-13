import SwiftUI
import BideKit
import BideUI

/// The extension's root. One model, four screens, and one layout across both
/// of the heights Messages hands out.
struct ExtensionRootView: View {

    @Bindable var model: MessagesModel
    /// Messages tells us which of its two heights we're in. The drawer shows
    /// the top of the same screen the full height shows, rather than a
    /// summary of it.
    let isExpanded: Bool

    var body: some View {
        // Anchored to the top by an overlay on a flexible base, not by a frame
        // alignment. A `.frame(maxHeight: .infinity, alignment: .topLeading)`
        // only aligns a child *smaller* than the frame; one that is taller
        // gets centred, and the drawer then showed a band out of the middle of
        // the form — no mark, no "Where are we going?", no search field, no
        // Send — which read as an empty grey tray. An overlay's alignment
        // holds whether the content fits or not, so the top stays the top and
        // everything past the drawer's height goes off the bottom.
        Color.clear
            .overlay(alignment: .topLeading) { screen }
            .clipped()
            .bideBackground()
            .preferredColorScheme(.dark)
            .animation(.easeOut(duration: 0.2), value: model.screen)
    }

    private var screen: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Always horizontal. The mark used to unfold from the vertical
            // form as Messages changed heights, which announced the drawer as
            // a different screen instead of the top of this one.
            BideMark(.horizontal, dotDiameter: 9)

            switch model.screen {
            case .compose:
                expandable("Set up a Bide") {
                    BidePlanForm(
                        draft: $model.draft,
                        style: .send,
                        search: model.search,
                        isBusy: model.isWorking
                    ) {
                        model.compose()
                    }
                }

            case .signInRequired:
                SignInRequiredScreen { model.onNeedsAccount?() }

            case .respond(let tile):
                expandable("Answer this Bide") {
                    RespondScreen(model: model, tile: tile)
                }

            case .status(let tile, let role):
                StatusScreen(tile: tile, role: role)
            }
        }
        .padding(BideMetrics.gutter)
        // The drawer shows as much of the screen as it has room for; the rest
        // is over the edge rather than squeezed into view. Laying out at the
        // height the screen wants — rather than the height Messages offered —
        // is what makes that "over the edge" instead of "compressed".
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// A screen that needs the taller presentation, shown at full size in the
    /// drawer and cut off at the bottom.
    ///
    /// The compact state used to be its own small design — a title, a line of
    /// explanation, and "tap to set up a Bide" — which read as a different
    /// screen that then became this one. Showing the real thing, clipped, says
    /// what tapping gets you by simply being it.
    ///
    /// **One view, in both heights.** This used to branch on `isExpanded` and
    /// return two different trees, which is what made tapping the drawer
    /// cross-fade while swiping it slid: an `if`/`else` gives SwiftUI two
    /// identities, so changing which branch is live is a remove and an insert,
    /// and the default transition for that is opacity. Swiping hid it, because
    /// Messages was dragging the sheet at the same time. Everything that varies
    /// with height is now a modifier *value* on one view, so there is nothing
    /// to fade between and both gestures move the same content.
    private func expandable<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        // Laying out at the size it wants is `screen`'s job, which proposes no
        // height to anything in here — so the form keeps its own and the drawer
        // crops it, rather than the preview being squashed until it stops
        // resembling the thing it previews.
        content()
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // Inert in the drawer, and covered by one target that asks for the
            // room. Half a date picker is not something to let anyone press.
            .allowsHitTesting(isExpanded)
            .overlay {
                // Invisible either way, so its coming and going is not a
                // transition anyone can see.
                if !isExpanded {
                    Button { model.onNeedsRoom?() } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(label)
                }
            }
    }
}

/// The drawer for somebody who hasn't got an account yet.
///
/// Sending a tile is the one thing an anonymous identity may not do. The
/// person on the other end is relying on the sender's ETA for as long as the
/// meetup lasts, and an identity that can't survive a reinstall can't carry
/// that. Answering a tile is unaffected — that only commits this device.
struct SignInRequiredScreen: View {

    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to send a Bide")
                .font(BideFont.cardTitle)
                .foregroundStyle(BideColor.primaryText)

            Text("Sending needs an account, so the people you send to keep seeing your ETA. You can still accept a Bide someone sends you.")
                .font(BideFont.body)
                .foregroundStyle(BideColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Button("Open Bide", action: action)
                .buttonStyle(.bidePrimary)
        }
    }
}

/// The expanded tile a recipient answers — `ios-message-thread-expanded`.
struct RespondScreen: View {

    @Bindable var model: MessagesModel
    let tile: BideTileMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How are you getting there?")
                .font(BideFont.prompt)
                .foregroundStyle(BideColor.secondaryText)

            TravelModeRow(selection: $model.replyMode)
                .onChange(of: model.replyMode) { _, _ in
                    model.startPreview(for: tile.invite.destination)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(BideFormat.schedule(tile.invite.scheduledFor))
                    .font(BideFont.body)
                    .foregroundStyle(BideColor.primaryText)
                Text(travelLine)
                    .font(BideFont.body)
                    .foregroundStyle(BideColor.primaryText)
            }

            HStack(spacing: 12) {
                Button("Accept") { model.accept(tile) }
                    .buttonStyle(.bidePrimary)
                Button("Decline") { model.decline(tile) }
                    .buttonStyle(.bideSecondary)
            }
            .disabled(model.isWorking)
        }
    }

    /// "36 minutes to Nats Park from this location" — or an honest substitute
    /// when there's no location to measure from.
    private var travelLine: String {
        if let preview = model.preview {
            return "\(BideFormat.duration(preview.travelTime)) to \(tile.invite.destinationName) from this location"
        }
        if model.previewFailed {
            return "Heading to \(tile.invite.destinationName)"
        }
        return "Working out how long it takes…"
    }
}

/// A tile with nothing left to answer: your own, or one you've already
/// replied to.
struct StatusScreen: View {

    let tile: BideTileMessage
    let role: ParticipantRole

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline)
                .font(BideFont.cardTitle)
                .foregroundStyle(BideColor.primaryText)
            Text(detail)
                .font(BideFont.body)
                .foregroundStyle(BideColor.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headline: String {
        switch tile.answer {
        case .declined: "You denied this request"
        case .accepted, .arrived: "You're going to \(tile.invite.destinationName)"
        case .invited, .none:
            role.isWaitingOnOtherParticipant
                ? "Waiting for a reply"
                : "Meet at \(tile.invite.destinationName)"
        }
    }

    private var detail: String {
        switch tile.answer {
        case .declined:
            "They'll see that you can't make it."
        case .accepted, .arrived:
            tile.leaveAt.map { "Leave at \(BideFormat.time($0)). Bide is tracking your ETA." }
                ?? "Bide is tracking your ETA."
        case .invited, .none:
            BideFormat.schedule(tile.invite.scheduledFor)
        }
    }
}

/// The bubble in the thread. Rendered by Messages in the transcript, where
/// nothing is interactive and nothing may be fetched.
struct TranscriptView: View {

    let tile: BideTileMessage
    let senderName: String?
    let role: ParticipantRole
    let localAnswer: LocalAnswer?

    var body: some View {
        BideTileView.transcript(
            invite: tile.invite,
            senderName: senderName,
            role: role,
            answer: localAnswer?.status ?? tile.answer,
            leaveAt: localAnswer?.leaveAt ?? tile.leaveAt,
            mode: localAnswer?.mode
        )
        .padding(.horizontal, 2)
        .preferredColorScheme(.dark)
    }
}
