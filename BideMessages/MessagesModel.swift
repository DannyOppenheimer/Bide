import Foundation
import Observation
import BideKit

/// What the extension is showing, and everything the screens can change.
///
/// The view controller owns the Messages framework — conversations, messages,
/// presentation styles — and this owns the state those screens read and write.
/// Actions are closures rather than direct calls so the SwiftUI side never
/// imports `Messages` and can be previewed on its own.
@MainActor
@Observable
final class MessagesModel {

    enum Screen: Equatable {
        /// Nothing selected: offer to start one.
        case compose
        /// Someone else's tile, unanswered.
        case respond(BideTileMessage)
        /// A tile there's nothing to do about here — your own, or one you've
        /// already answered.
        case status(BideTileMessage, ParticipantRole)
    }

    var screen: Screen = .compose
    var draft = BidePlanDraft(scheduledFor: BidePlanDraft.defaultTime())
    /// The recipient's own travel mode on the respond screen, which is a
    /// different choice from the sender's in ``draft``.
    var replyMode: TravelMode = .walking

    /// "36 minutes to Nats Park from this location", when location allows it.
    private(set) var preview: ETAReading?
    private(set) var previewFailed = false
    private(set) var isWorking = false

    let search = PlaceSearchService()

    @ObservationIgnored private let eta: any ETAEngine
    @ObservationIgnored private let store: LocalBideStore
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    /// Insert a tile into the conversation. The user still taps send — an
    /// extension may stage a message, never send one on someone's behalf.
    @ObservationIgnored var onCompose: ((BidePlanDraft) -> Void)?
    /// Accepting needs the container app: location, MKDirections and the
    /// user's real identity all live there.
    @ObservationIgnored var onAccept: ((BideTileMessage, TravelMode, Date?) -> Void)?
    @ObservationIgnored var onDecline: ((BideTileMessage) -> Void)?
    /// Ask Messages for the taller presentation, which the forms need.
    @ObservationIgnored var onNeedsRoom: (() -> Void)?

    init(eta: any ETAEngine, store: LocalBideStore = LocalBideStore()) {
        self.eta = eta
        self.store = store
    }

    // MARK: - Screen

    /// Decides what to show for whatever tile Messages handed us.
    func present(tile: BideTileMessage?, role: ParticipantRole) {
        previewTask?.cancel()
        preview = nil
        previewFailed = false

        guard let tile else {
            screen = .compose
            return
        }

        // A tile this device has already answered has nothing left to ask.
        if let answered = store.answer(for: tile.invite.bideID) {
            screen = .status(BideTileMessage(invite: tile.invite, answer: answered.status, leaveAt: answered.leaveAt), role)
            return
        }

        switch role {
        case .recipient:
            screen = .respond(tile)
            replyMode = .walking
            startPreview(for: tile.invite.destination)
        case .sender, .indeterminate:
            screen = .status(tile, role)
        }
    }

    /// The travel-time line on the respond screen. Best-effort: it needs a
    /// location fix, and the tile still works without one.
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
        onCompose?(draft)
    }

    func accept(_ tile: BideTileMessage) {
        isWorking = true
        defer { isWorking = false }

        // The departure time is worked out here, while a fresh ETA is in hand,
        // so the tile in the transcript can count down on its own afterwards.
        let leaveAt = departure(for: tile)
        store.record(
            LocalAnswer(status: .accepted, mode: replyMode, leaveAt: leaveAt),
            for: tile.invite.bideID
        )
        onAccept?(tile, replyMode, leaveAt)
        screen = .status(BideTileMessage(invite: tile.invite, answer: .accepted, leaveAt: leaveAt), .sender)
    }

    func decline(_ tile: BideTileMessage) {
        store.record(LocalAnswer(status: .declined, mode: replyMode), for: tile.invite.bideID)
        onDecline?(tile)
        screen = .status(BideTileMessage(invite: tile.invite, answer: .declined), .sender)
    }

    /// When this person has to set off: the agreed time minus their journey,
    /// or right now for an asap bide.
    private func departure(for tile: BideTileMessage) -> Date? {
        guard let travelTime = preview?.travelTime else { return nil }
        guard let scheduled = tile.invite.scheduledFor else { return Date() }
        return scheduled.addingTimeInterval(-travelTime)
    }
}
