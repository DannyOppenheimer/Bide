import SwiftUI
import BideKit
import BideUI

/// The extension's root. One model, three screens, and the logo morph that
/// ties the compact and expanded states together.
struct ExtensionRootView: View {

    @Bindable var model: MessagesModel
    /// Messages tells us which of its two heights we're in; the mark's form
    /// follows, and animates between them.
    let isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            BideMark(isExpanded ? .horizontal : .vertical, dotDiameter: 9)
                .animation(.spring(response: 0.55, dampingFraction: 0.8), value: isExpanded)

            switch model.screen {
            case .compose:
                if isExpanded {
                    BidePlanForm(
                        draft: $model.draft,
                        style: .send,
                        search: model.search,
                        isBusy: model.isWorking
                    ) {
                        model.compose()
                    }
                } else {
                    CompactPromptView(title: "Where are we going?", detail: "Tap to set up a Bide") {
                        model.onNeedsRoom?()
                    }
                }

            case .respond(let tile):
                if isExpanded {
                    RespondScreen(model: model, tile: tile)
                } else {
                    CompactPromptView(
                        title: tile.invite.destinationName,
                        detail: BideFormat.schedule(tile.invite.scheduledFor) + " • Tap to answer"
                    ) {
                        model.onNeedsRoom?()
                    }
                }

            case .status(let tile, let role):
                StatusScreen(tile: tile, role: role)
            }

            Spacer(minLength: 0)
        }
        .padding(BideMetrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .bideBackground()
        .preferredColorScheme(.dark)
        .animation(.easeOut(duration: 0.2), value: model.screen)
    }
}

/// What the drawer shows before Messages gives us the full height. Tapping
/// asks for it.
private struct CompactPromptView: View {

    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(BideFont.prompt)
                    .foregroundStyle(BideColor.primaryText)
                Text(detail)
                    .font(BideFont.caption)
                    .foregroundStyle(BideColor.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            leaveAt: localAnswer?.leaveAt ?? tile.leaveAt
        )
        .padding(.horizontal, 2)
        .preferredColorScheme(.dark)
    }
}
