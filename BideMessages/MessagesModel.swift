import Foundation
import Observation
import BideKit

/// Presentation state and actions for the extension's SwiftUI screens.
/// Closure-based actions keep the views independent from the Messages framework.
@MainActor
@Observable
final class MessagesModel {

    enum Screen: Equatable {
        /// No selected message; show the compose form.
        case compose
        /// No selected message and no durable account for sending.
        case signInRequired
        /// An unanswered invitation from another participant.
        case respond(BideTileMessage)
        /// Another participant's journey offered for tracking.
        case track(BideTileMessage)
        /// The local user's tile or an invitation already answered on this device.
        case status(BideTileMessage, ParticipantRole)
        /// This conversation already holds an active Bide from this device.
        case occupied(SentInvite)
    }

    var screen: Screen = .compose
    var draft = BidePlanDraft()
    /// Recipient travel mode, independent from the compose draft's mode.
    var replyMode: TravelMode = .walking
    /// Opaque key for the open conversation, set by the view controller.
    @ObservationIgnored var conversationKey: String?

    /// Optional one-shot travel preview for the response screen.
    private(set) var preview: ETAReading?
    private(set) var previewFailed = false
    private(set) var isWorking = false

    let search = PlaceSearchService()

    @ObservationIgnored private let eta: any ETAEngine
    @ObservationIgnored private let store: LocalBideStore
    @ObservationIgnored private let profile: BideProfileStore
    @ObservationIgnored private let sent: SentInviteStore
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    /// Stages a tile in the conversation; the user still sends it manually.
    @ObservationIgnored var onCompose: ((BidePlanDraft) -> Void)?
    /// Hands acceptance to the container app for identity and continuous ETA work.
    @ObservationIgnored var onAccept: ((BideTileMessage, TravelMode, Date?) -> Void)?
    @ObservationIgnored var onDecline: ((BideTileMessage) -> Void)?
    /// Hands a tracking request to the container app without starting a local ETA.
    @ObservationIgnored var onTrack: ((BideTileMessage) -> Void)?
    /// Requests the expanded Messages presentation.
    @ObservationIgnored var onNeedsRoom: (() -> Void)?
    /// Opens the container app for account creation.
    @ObservationIgnored var onNeedsAccount: (() -> Void)?
    /// Opens the container app to manage existing sessions.
    @ObservationIgnored var onNeedsApp: (() -> Void)?

    init(
        eta: any ETAEngine,
        store: LocalBideStore = LocalBideStore(),
        profile: BideProfileStore = BideProfileStore(),
        sent: SentInviteStore = SentInviteStore()
    ) {
        self.eta = eta
        self.store = store
        self.profile = profile
        self.sent = sent
    }

    // MARK: - Screen

    /// Selects the screen for the current tile and participant role.
    func present(tile: BideTileMessage?, role: ParticipantRole) {
        previewTask?.cancel()
        preview = nil
        previewFailed = false

        guard let tile else {
            // Re-read shared auth state because the extension may survive an app round trip.
            guard profile.isSignedInWithApple else {
                screen = .signInRequired
                return
            }
            screen = composeScreen()
            return
        }

        // Show local status instead of presenting the same invitation again.
        if let answered = store.answer(for: tile.invite.bideID) {
            screen = .status(BideTileMessage(invite: tile.invite, answer: answered.status, leaveAt: answered.leaveAt), role)
            return
        }

        switch role {
        case .recipient:
            // Tracking does not need the recipient's mode or travel-time preview.
            if tile.isTrackingInvite {
                screen = .track(tile)
                return
            }
            screen = .respond(tile)
            replyMode = .walking
            startPreview(for: tile.invite.destination)
        case .sender, .indeterminate:
            screen = .status(tile, role)
        }
    }

    /// Starts a best-effort one-shot ETA preview for the response screen.
    func startPreview(for destination: Destination) {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let reading = try await eta.estimate(to: destination, mode: replyMode)
                guard !Task.isCancelled else { return }
                preview = reading
                previewFailed = false
            } catch {
                guard !Task.isCancelled else { return }
                preview = nil
                previewFailed = true
            }
        }
    }

    // MARK: - Actions

    func compose() {
        guard draft.isComplete else { return }
        // Enforce durable identity even if compose is invoked outside its normal screen.
        guard profile.isSignedInWithApple else {
            onNeedsAccount?()
            return
        }
        // One Bide per conversation, checked here as well because this is the
        // call that writes.
        if let occupying = sent.live(inConversation: conversationKey) {
            screen = .occupied(occupying)
            return
        }
        onCompose?(draft)
    }

    /// Ends the active Bide in this conversation and returns to the compose form.
    ///
    /// The container app performs the deletion; the conversation is released
    /// here so the replacement can be written without leaving Messages.
    func endOccupyingBide(_ occupying: SentInvite) {
        sent.revoke(occupying.bideID)
        store.clear(occupying.bideID)
        screen = composeScreen()
    }

    /// Compose, unless this conversation already holds an active Bide.
    private func composeScreen() -> Screen {
        guard let occupying = sent.live(inConversation: conversationKey) else { return .compose }
        return .occupied(occupying)
    }

    func accept(_ tile: BideTileMessage) {
        isWorking = true
        defer { isWorking = false }

        // Store the current departure estimate for a self-updating transcript countdown.
        let leaveAt = departure(for: tile)
        store.record(
            LocalAnswer(status: .accepted, mode: replyMode, leaveAt: leaveAt),
            for: tile.invite.bideID
        )
        onAccept?(tile, replyMode, leaveAt)
        screen = .status(BideTileMessage(invite: tile.invite, answer: .accepted, leaveAt: leaveAt), .sender)
    }

    /// Starts following another participant without recording a local journey.
    func track(_ tile: BideTileMessage) {
        isWorking = true
        defer { isWorking = false }

        onTrack?(tile)
        screen = .status(
            BideTileMessage(
                invite: tile.invite,
                answer: .watching,
                senderName: tile.senderName,
                isTrackingInvite: true
            ),
            .sender
        )
    }

    func decline(_ tile: BideTileMessage) {
        store.record(LocalAnswer(status: .declined, mode: replyMode), for: tile.invite.bideID)
        onDecline?(tile)
        screen = .status(BideTileMessage(invite: tile.invite, answer: .declined), .sender)
    }

    /// Calculates a local departure for fixed-time invitations.
    /// Arrive-together plans require roster state available only in the container app.
    private func departure(for tile: BideTileMessage) -> Date? {
        guard tile.invite.arrivalStyle != .together else { return nil }
        guard let travelTime = preview?.travelTime else { return nil }
        guard let scheduled = tile.invite.scheduledFor else { return Date() }
        return scheduled.addingTimeInterval(-travelTime)
    }
}
