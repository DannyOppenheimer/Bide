import SwiftUI
import BideKit
import BideUI

/// Root view shared by compact and expanded Messages presentations.
struct ExtensionRootView: View {

    @Bindable var model: MessagesModel
    /// Whether Messages has provided its expanded presentation height.
    let isExpanded: Bool

    var body: some View {
        // An aligned overlay keeps oversized compact content anchored to the top.
        Color.clear
            .overlay(alignment: .topLeading) { screen }
            .clipped()
            .bideBackground()
            .preferredColorScheme(.dark)
            .animation(.easeOut(duration: 0.2), value: model.screen)
    }

    private var screen: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Keep the same mark across presentation heights.
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

            case .occupied(let occupying):
                OccupiedConversationScreen(
                    occupying: occupying,
                    openApp: { model.onNeedsApp?() },
                    end: { model.endOccupyingBide(occupying) }
                )

            case .respond(let tile):
                expandable("Answer this Bide") {
                    RespondScreen(model: model, tile: tile)
                }

            case .track(let tile):
                expandable("Track this Bide") {
                    TrackScreen(model: model, tile: tile)
                }

            case .status(let tile, let role):
                StatusScreen(tile: tile, role: role)
            }
        }
        .padding(BideMetrics.gutter)
        // Preserve the screen's intrinsic height and clip compact overflow.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Uses one view identity at both heights, clipping and disabling the compact
    /// presentation instead of swapping view trees.
    private func expandable<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        // Let the form retain its natural height before the drawer clips it.
        content()
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // Compact content is one target that requests expansion.
            .allowsHitTesting(isExpanded)
            .overlay {
                // The transparent expansion target has no visible transition.
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

/// Prompts anonymous users to create a durable account before sending.
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

/// Confirms replacement when the conversation already contains an active Bide.
/// Only one tile may be active per conversation.
struct OccupiedConversationScreen: View {

    let occupying: SentInvite
    let openApp: () -> Void
    let end: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This chat already has a Bide")
                .font(BideFont.cardTitle)
                .foregroundStyle(BideColor.primaryText)

            Text(occupying.destinationName)
                .font(BideFont.body)
                .foregroundStyle(BideColor.primaryText)

            Text(BideFormat.schedule(occupying.scheduledFor))
                .font(BideFont.caption)
                .foregroundStyle(BideColor.secondaryText)

            Text("Change where or when in the app, or end it here to send a new one. Ending removes everyone who joined or is tracking it.")
                .font(BideFont.body)
                .foregroundStyle(BideColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Button("Edit it in Bide", action: openApp)
                .buttonStyle(.bidePrimary)

            Button("End it and start a new one", action: end)
                .buttonStyle(.bideSecondary)
        }
    }
}

/// Expanded response screen for an invitation recipient.
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

    /// Travel preview text with loading and unavailable fallbacks.
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

/// Screen for following another participant's solo journey.
struct TrackScreen: View {

    @Bindable var model: MessagesModel
    let tile: BideTileMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(who) is going to \(tile.invite.destinationName)")
                .font(BideFont.prompt)
                .foregroundStyle(BideColor.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            Text(BideFormat.soloSchedule(tile.invite.scheduledFor))
                .font(BideFont.body)
                .foregroundStyle(BideColor.primaryText)

            // Clarify that tracking does not create or publish the viewer's journey.
            Text("You'll see their ETA in your Bides. You're not going along, so nothing of yours is tracked or shared.")
                .font(BideFont.caption)
                .foregroundStyle(BideColor.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Button("Start tracking") { model.track(tile) }
                .buttonStyle(.bidePrimary)
                .disabled(model.isWorking)
        }
    }

    private var who: String { tile.senderName ?? BideFormat.anonymousName }
}

/// Status for the local user's tile or an invitation already answered.
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
        case .watching: "You're tracking \(tile.senderName ?? BideFormat.anonymousName)"
        case .accepted, .arrived: "You're going to \(tile.invite.destinationName)"
        case .invited, .none:
            if tile.isTrackingInvite {
                "You're going to \(tile.invite.destinationName)"
            } else {
                role.isWaitingOnOtherParticipant
                    ? "Waiting for a reply"
                    : "Meet at \(tile.invite.destinationName)"
            }
        }
    }

    private var detail: String {
        switch tile.answer {
        case .declined:
            "They'll see that you can't make it."
        case .watching:
            "Their ETA to \(tile.invite.destinationName) is in your Bides. Nothing of yours is shared."
        case .accepted, .arrived:
            tile.leaveAt.map { "Leave at \(BideFormat.time($0)). Bide is tracking your ETA." }
                ?? "Bide is tracking your ETA."
        case .invited, .none:
            tile.isTrackingInvite
                ? BideFormat.soloSchedule(tile.invite.scheduledFor)
                : BideFormat.schedule(tile.invite.scheduledFor)
        }
    }
}

/// Static transcript bubble rendered by Messages without external requests.
struct TranscriptView: View {

    let tile: BideTileMessage
    let senderName: String?
    let role: ParticipantRole
    let localAnswer: LocalAnswer?

    var body: some View {
        // Redraw only at departure and schedule boundaries so transcript text expires correctly.
        TimelineView(.explicit(redraws)) { context in
            BideTileView.transcript(
                invite: tile.invite,
                senderName: senderName,
                role: role,
                answer: localAnswer?.status ?? tile.answer,
                leaveAt: localAnswer?.leaveAt ?? tile.leaveAt,
                mode: localAnswer?.mode,
                isTrackingInvite: tile.isTrackingInvite,
                now: context.date
            )
        }
        .padding(.horizontal, 2)
        .preferredColorScheme(.dark)
    }

    /// Explicit redraw dates beginning with now, followed by future departure
    /// and schedule boundaries.
    private var redraws: [Date] {
        let now = Date()
        let ahead = [
            localAnswer?.leaveAt ?? tile.leaveAt,
            tile.invite.scheduledFor,
            // Redraw at expiry so the tile switches to its collapsed state.
            tile.invite.endsAt,
        ]
            .compactMap { $0 }
            .filter { $0 > now }
            .sorted()
        return [now] + ahead
    }
}
