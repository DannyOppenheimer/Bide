import Foundation
import Observation
import BideKit

/// Coordinates server state, on-device ETA tracking, and Live Activity updates.
@MainActor
@Observable
final class BideStore {

    /// A schedule conflict requiring user confirmation.
    struct ConflictPrompt: Identifiable {
        let id = UUID()
        let message: String
        /// IDs of bides the user will leave if they continue.
        let losing: [UUID]
        /// Work to run after confirmation.
        let proceed: () async -> Void
    }

    private(set) var bides: [BideState] = []
    private(set) var errorMessage: String?
    /// Bides served by the active ETA route. Same-destination bides share one reading.
    private(set) var trackedBideIDs: Set<UUID> = []
    /// The bide the engine is anchored on: the soonest of ``trackedBideIDs``,
    /// whose destination and travel mode define the measured route.
    private(set) var trackedBideID: UUID?
    var conflict: ConflictPrompt?

    /// Foreground polling interval while realtime and remote push updates are unavailable.
    private static let refreshInterval: Duration = .seconds(30)

    private let api: any BideAPI
    private let eta: any ETAEngine
    private let activities: LiveActivityController
    private let profile: BideProfileStore
    private let answers: LocalBideStore
    private let pending: PendingInviteStore
    private let sent: SentInviteStore

    /// Local user identifier, set by ``start(userID:)``.
    private(set) var userID: UUID?
    private var refreshTask: Task<Void, Never>?
    /// Initial arrival estimates used to grade later delays.
    private var baseline: [UUID: Date] = [:]
    /// Latest local ETA reading for each bide, which may be newer than server state.
    private var readings: [UUID: ETAReading] = [:]
    /// First recorded departure time for each bide; never reset during a journey.
    private var departures: [UUID: Date] = [:]

    /// Immutable plan values used to detect edits that require tracking restart.
    private struct TrackingPlan: Equatable {
        let destination: Destination
        let scheduledFor: Date?
        let mode: TravelMode
    }

    private var trackedPlan: TrackingPlan?

    /// `activities` is optional because default arguments are evaluated outside actor isolation.
    init(
        api: any BideAPI,
        eta: any ETAEngine,
        activities: LiveActivityController? = nil,
        profile: BideProfileStore = BideProfileStore(),
        answers: LocalBideStore = LocalBideStore(defaults: .bideShared),
        pending: PendingInviteStore = PendingInviteStore(),
        sent: SentInviteStore = SentInviteStore()
    ) {
        self.api = api
        self.eta = eta
        self.activities = activities ?? LiveActivityController()
        self.profile = profile
        self.answers = answers
        self.pending = pending
        self.sent = sent
    }

    // MARK: - Session

    func start(userID: UUID) {
        self.userID = userID
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        eta.stopTracking()
        trackedBideID = nil
        trackedBideIDs = []
        trackedPlan = nil
    }

    // MARK: - Reading

    func refresh() async {
        guard userID != nil else { return }

        await applyRevocations()

        do {
            // Retire bides either through explicit completion or time-based expiry.
            let now = Date()
            bides = try await api.fetchMyBides().filter { !$0.isComplete && !$0.isExpired(now: now) }
            adoptRecordedDepartures()
            await restoreTravellers()
            errorMessage = nil
            reconcileTracking()
        } catch let error as APIError {
            // Internal cancellation should not be presented as a network failure.
            if !error.isCancellation { errorMessage = error.errorDescription }
        } catch is CancellationError {
            // Task cancellation is expected during teardown.
        } catch {
            errorMessage = "Couldn't reach Bide."
        }

        await claimPendingInvites()
    }

    /// Calculates the local user's current plan for a bide.
    func plan(for state: BideState, now: Date = Date()) -> BidePlan {
        guard let userID else {
            return BidePlan(targetArrival: state.scheduledFor, departure: nil)
        }

        // Prefer current local measurements and fall back to server state.
        let reading = readings[state.bideID]
        let mine = state.participant(userID)
        let myTravelTime = reading?.travelTime ?? mine?.journey
        let hasDeparted = reading?.hasDeparted == true || departures[state.bideID] != nil

        return BidePlanner.plan(
            for: state,
            me: userID,
            myTravelTime: myTravelTime,
            hasDeparted: hasDeparted,
            now: now
        )
    }

    func headline(for state: BideState, now: Date = Date()) -> String {
        guard !state.isWatching(userID) else {
            return BidePlanner.watcherHeadline(for: state, now: now)
        }
        return BidePlanner.headline(for: plan(for: state, now: now), state: state, now: now)
    }

    // MARK: - Writing

    /// Creates a bide from an in-app or calendar draft.
    func create(_ draft: BidePlanDraft, isSolo: Bool) async {
        guard let invite = draft.invite() else { return }
        await withConflictCheck(for: invite, mode: draft.mode) { [weak self] in
            guard let self else { return }
            await perform {
                let state = try await self.api.createBide(invite, mode: draft.mode, isSolo: isSolo)
                try await self.nameMyselfIfNeeded()
                self.merge(state)
                self.reconcileTracking()
            }
        }
    }

    /// Accepts a tile handed off by the Messages extension.
    func accept(_ tile: BideTileMessage, mode: TravelMode) async {
        await withConflictCheck(for: tile.invite, mode: mode) { [weak self] in
            guard let self else { return }
            await perform {
                // Repeated acceptance safely updates the travel mode.
                let state = try await self.join(tile.invite, mode: mode)
                try await self.nameMyselfIfNeeded()
                self.merge(state)
                self.reconcileTracking()
            }
        }
    }

    /// Saves the display name in shared storage and participant rows.
    func updateDisplayName(_ name: String) async {
        profile.displayName = name
        await perform {
            try await self.api.updateDisplayName(name)
            await self.refresh()
        }
    }

    /// Joins an existing bide or creates it from the invitation if no participant has yet.
    private func join(_ invite: BideInvite, mode: TravelMode) async throws(APIError) -> BideState {
        do {
            return try await api.joinBide(bideID: invite.bideID, mode: mode, status: .accepted)
        } catch APIError.notFound {
            // `create_bide` atomically creates the bide and accepts for the caller.
            return try await api.createBide(invite, mode: mode, isSolo: false)
        }
    }

    /// Whether the local user may edit the plan under the server's ownership rules.
    func canEdit(_ state: BideState) -> Bool {
        guard let userID, !state.isWatching(userID) else { return false }
        return state.isSolo ? state.createdBy == userID : true
    }

    /// Whether the local user follows this bide without attending.
    func isWatching(_ state: BideState) -> Bool { state.isWatching(userID) }

    /// Whether the local user can share their own solo journey for tracking.
    func canShare(_ state: BideState) -> Bool {
        guard let userID else { return false }
        return state.isSolo && state.createdBy == userID
    }

    /// Builds a URL that joins the recipient as a watcher.
    func trackingLink(for state: BideState) -> URL {
        BideTileMessage(
            invite: state.invite,
            senderName: profile.displayName,
            isTrackingInvite: true
        ).webURL()
    }

    /// Returns the removal label appropriate to watcher, solo-owner, or attendee state.
    func leaveTitle(for state: BideState) -> String {
        if isWatching(state) { return "Stop tracking" }
        if state.isSolo, state.createdBy == userID { return "Delete this Bide" }
        return "Leave this Bide"
    }

    /// Updates shared plan fields and the local participant's travel mode.
    func edit(
        _ bideID: UUID,
        destination: Destination,
        scheduledFor: Date?,
        mode: TravelMode
    ) async {
        guard let existing = bides.first(where: { $0.bideID == bideID }) else { return }
        let me = userID.flatMap { existing.participant($0) }
        let myStatus = me?.status ?? .accepted

        await perform {
            var state = existing

            if destination != existing.destination || scheduledFor != existing.scheduledFor {
                state = try await self.api.updateBide(
                    bideID: bideID,
                    destination: destination,
                    scheduledFor: scheduledFor
                )
            }

            if mode != me?.mode {
                // Update mode through the idempotent join path without clearing ETA fields.
                state = try await self.api.joinBide(bideID: bideID, mode: mode, status: myStatus)
            }

            self.forgetJourney(for: bideID)
            self.merge(state)
            self.reconcileTracking()
        }
    }

    /// Clears route-dependent readings after a plan edit while preserving departure state.
    private func forgetJourney(for bideID: UUID) {
        baseline[bideID] = nil
        readings[bideID] = nil

        // Clear tracking identity so reconciliation starts a route for the new plan.
        guard trackedBideID == bideID else { return }
        eta.stopTracking()
        activities.end(bideID: bideID)
        trackedBideID = nil
        trackedPlan = nil
    }

    /// Joins another participant's trip as a watcher without starting an ETA.
    func watch(_ tile: BideTileMessage) async {
        let bideID = tile.invite.bideID

        // Nobody follows their own trip. A tracking link is a normal URL: the
        // person who shared it can open it on this device or another, and doing
        // so must not turn the traveller into their own audience — a solo bide
        // whose creator is watching has nobody left going on it, which is what
        // "Nobody is going any more" was reporting.
        //
        // Asked of the server rather than the local list, because opening a link
        // can be what launches the app, before any bide has been fetched.
        if let existing = try? await api.fetchBideState(bideID: bideID), isMine(existing) {
            merge(existing)
            await restoreTravellers()
            reconcileTracking()
            return
        }

        await perform {
            let state = try await self.api.joinBide(
                bideID: bideID,
                mode: .walking,
                status: .watching
            )
            self.merge(state)
            // Ensure the newly watched bide does not replace the active journey.
            self.reconcileTracking()
        }
    }

    /// Whether this is a bide the local user is going on rather than following.
    private func isMine(_ state: BideState) -> Bool {
        guard let userID else { return false }
        return state.createdBy == userID || state.participant(userID)?.status.isTravelling == true
    }

    /// Puts the creator of a solo bide back on their own trip.
    ///
    /// Repairs bides already left watching themselves. That row is the only
    /// thing holding the journey, so while it says `watching` the bide has no
    /// traveller, publishes no ETA, and reads as though everyone dropped out.
    /// Nothing may create this state any more, so this is only ever a repair.
    private func restoreTravellers() async {
        guard let userID else { return }

        for state in bides where state.isSolo && state.createdBy == userID {
            guard let mine = state.participant(userID), mine.status.isWatching else { continue }
            await perform {
                let restored = try await self.api.joinBide(
                    bideID: state.bideID,
                    mode: mine.mode,
                    status: .accepted
                )
                self.merge(restored)
            }
        }
    }

    /// Deletes a caller-owned solo bide, or removes only the caller from any other bide.
    func leave(_ bideID: UUID) async {
        let mine = bides.first { $0.bideID == bideID }
        let isMySoloBide = mine.map { $0.isSolo && $0.createdBy == userID } ?? false

        await perform {
            if isMySoloBide {
                try await self.api.deleteBide(bideID: bideID)
            } else {
                try await self.api.leaveBide(bideID: bideID)
            }
            self.forget(bideID)
            self.reconcileTracking()
        }
    }

    /// Drops every local trace of a bide that is no longer this user's.
    private func forget(_ bideID: UUID) {
        bides.removeAll { $0.bideID == bideID }
        answers.clear(bideID)
        sent.forget(bideID)
        activities.end(bideID: bideID)
        baseline[bideID] = nil
        readings[bideID] = nil
        departures[bideID] = nil
        trackedBideIDs.remove(bideID)
        if trackedBideID == bideID {
            eta.stopTracking()
            trackedBideID = nil
            trackedPlan = nil
        }
    }

    /// Processes deletion requests staged when the extension replaces a tile.
    /// Unaccepted invitations have no server state; existing solo bides are deleted,
    /// while shared bides are left according to server policy.
    private func applyRevocations() async {
        for bideID in sent.revoked() {
            pending.remove(bideID)

            let mine = bides.first { $0.bideID == bideID }
            let isMySoloBide = mine.map { $0.isSolo && $0.createdBy == userID } ?? false

            do {
                if isMySoloBide {
                    try await api.deleteBide(bideID: bideID)
                } else {
                    // This is a no-op when the invitation never created a participant row.
                    try await api.leaveBide(bideID: bideID)
                }
            } catch APIError.notFound {
                // The bide is already gone or was never created.
            } catch APIError.notPermitted {
                // Refused by policy; repeating it would only fail again.
            } catch {
                // Offline or cancelled. Keep the request and retry on the next
                // refresh rather than dropping a deletion the sender asked for.
                return
            }

            forget(bideID)
            sent.clearRevocation(bideID)
        }
    }

    /// Routes custom-scheme and Universal Link invitation actions.
    func handle(url: URL) async {
        guard let tile = BideTileMessage(url: url) else { return }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let mode = items.first { $0.name == "mode" }?.value
            .flatMap(TravelMode.init(rawValue:)) ?? .walking

        let action = items.first(where: { $0.name == "action" })?.value

        // Support both extension-only action parameters and durable tile flags.
        if action == "track" || tile.isTrackingInvite {
            await watch(tile)
        } else if action == "create" {
            // Preserve legacy `create` links and require a durable sender identity.
            guard profile.isSignedInWithApple else {
                errorMessage = "Sign in with Apple to send a Bide to someone."
                return
            }
            pending.add(PendingInvite(invite: tile.invite, mode: mode))
            await claimPendingInvites()
        } else {
            await accept(tile, mode: mode)
        }
    }

    // MARK: - Invitations waiting on an answer

    /// Reconciles pending invitations after a recipient creates server state.
    private func claimPendingInvites() async {
        guard userID != nil, !pending.isEmpty else { return }

        for staged in pending.all() {
            do {
                let state = try await api.joinBide(
                    bideID: staged.invite.bideID,
                    mode: staged.mode,
                    status: .accepted
                )
                pending.remove(staged.id)
                merge(state)
                reconcileTracking()
                // Synchronize the name opportunistically after joining the session.
                try? await nameMyselfIfNeeded()
                warnIfClashing(with: state)
            } catch APIError.notFound {
                // The recipient has not accepted yet; retry on the next refresh.
            } catch {
                // Preserve remaining invitations and retry after connectivity recovers.
                return
            }
        }
    }

    // MARK: - Conflicts

    /// Prompts for conflicts when a pending invitation becomes an active session.
    /// Cancelling keeps both commitments; continuing leaves the older conflicts.
    private func warnIfClashing(with state: BideState) {
        guard let userID, let proposed = state.travelWindow(for: userID) else { return }

        let existing = bides
            .filter { $0.bideID != state.bideID }
            .compactMap { other -> ScheduleConflict.Candidate? in
                guard let window = other.travelWindow(for: userID) else { return nil }
                return ScheduleConflict.Candidate(
                    id: other.bideID,
                    destination: other.destination,
                    window: window
                )
            }

        let clashes = ScheduleConflict.conflicts(
            with: proposed,
            goingTo: state.destination,
            proposedID: state.bideID,
            among: existing
        )
        guard let message = ScheduleConflict.warning(for: clashes) else { return }

        conflict = ConflictPrompt(message: message, losing: clashes.map(\.id)) { [weak self] in
            guard let self else { return }
            for bideID in clashes.map(\.id) {
                await leave(bideID)
            }
        }
    }

    /// Checks a proposed commitment before replacing overlapping bides.
    private func withConflictCheck(
        for invite: BideInvite,
        mode: TravelMode,
        proceed: @escaping () async -> Void
    ) async {
        guard let userID else { return await proceed() }

        // Calculate the proposed travel window with an on-device estimate.
        let travelTime = try? await eta.estimate(to: invite.destination, mode: mode).travelTime
        let arrival = invite.scheduledFor ?? Date().addingTimeInterval(travelTime ?? 0)
        let proposed = TravelWindow(arriveAt: arrival, travelTime: travelTime ?? 0)

        let existing = bides.compactMap { state -> ScheduleConflict.Candidate? in
            guard let window = state.travelWindow(for: userID) else { return nil }
            return ScheduleConflict.Candidate(
                id: state.bideID,
                destination: state.destination,
                window: window
            )
        }

        let clashes = ScheduleConflict.conflicts(
            with: proposed,
            goingTo: invite.destination,
            proposedID: invite.bideID,
            among: existing
        )

        guard let message = ScheduleConflict.warning(for: clashes) else {
            return await proceed()
        }

        conflict = ConflictPrompt(message: message, losing: clashes.map(\.id)) { [weak self] in
            guard let self else { return }
            for bideID in clashes.map(\.id) {
                await leave(bideID)
            }
            await proceed()
        }
    }

    // MARK: - Tracking

    /// Bides the local user is travelling on, soonest first.
    private func travellingBides() -> [BideState] {
        guard let userID else { return [] }
        return bides
            .filter { $0.participant(userID)?.status.isTravelling == true }
            .sorted { lhs, rhs in
                (lhs.scheduledFor ?? lhs.createdAt) < (rhs.scheduledFor ?? rhs.createdAt)
            }
    }

    /// Active sessions in display order: soonest first, with bides sharing a
    /// destination kept together beneath the earliest of them.
    var sessions: [BideState] {
        func time(_ state: BideState) -> Date { state.scheduledFor ?? state.createdAt }

        var clusters: [[BideState]] = []
        for state in bides.sorted(by: { time($0) < time($1) }) {
            let existing = clusters.firstIndex {
                $0[0].destination.isSamePlace(as: state.destination)
            }
            if let existing {
                clusters[existing].append(state)
            } else {
                clusters.append([state])
            }
        }
        return clusters.flatMap { $0 }
    }

    /// Other active bides heading to the same place as `state`.
    func companions(of state: BideState) -> [BideState] {
        bides.filter { $0.bideID != state.bideID && $0.destination.isSamePlace(as: state.destination) }
    }

    /// Caption for cards that share one journey to the same destination.
    func companionNote(for state: BideState) -> String? {
        let sharing = companions(of: state).count
        guard sharing > 0 else { return nil }
        return "One of \(sharing + 1) Bides going here"
    }

    /// Tracks the earliest active bide and same-destination companions with one ETA
    /// route, then updates a Live Activity for each session.
    private func reconcileTracking() {
        guard let userID else { return }

        let travelling = travellingBides()

        guard let anchor = travelling.first else {
            endActivities(except: [])
            eta.stopTracking()
            trackedBideID = nil
            trackedBideIDs = []
            trackedPlan = nil
            return
        }

        let group = travelling.filter { $0.destination.isSamePlace(as: anchor.destination) }
        let groupIDs = Set(group.map(\.bideID))
        endActivities(except: groupIDs)
        trackedBideIDs = groupIDs

        let mode = anchor.participant(userID)?.mode ?? .walking
        let anchorPlan = TrackingPlan(
            destination: anchor.destination,
            scheduledFor: anchor.scheduledFor,
            mode: mode
        )

        // Refresh content without restarting when immutable plan values are unchanged.
        if anchor.bideID == trackedBideID, anchorPlan == trackedPlan {
            let now = Date()
            for state in group {
                activities.update(state: state, plan: plan(for: state, now: now), me: userID, now: now)
            }
            return
        }

        // Restart tracking when an edit changes route or immutable activity attributes.
        if anchor.bideID == trackedBideID {
            forgetJourney(for: anchor.bideID)
        }

        // A previous anchor that is still in the group keeps its Live Activity;
        // one that has dropped out was ended above.
        trackedBideID = anchor.bideID
        trackedPlan = anchorPlan

        eta.startTracking(
            to: anchor.destination,
            mode: mode,
            scheduledArrival: anchor.scheduledFor
        ) { [weak self] result in
            Task { @MainActor in
                // Resolve the group at callback time so newly accepted companions
                // can join the active route without restarting the engine.
                guard let self else { return }
                await self.publish(result, for: self.trackedBideIDs)
            }
        }

        // Newest first: if the system refuses a request for capacity, the most
        // recently created session is the one that keeps its Live Activity.
        for state in group.sorted(by: { $0.createdAt > $1.createdAt }) {
            activities.start(state: state, plan: plan(for: state), me: userID)
        }
    }

    /// Ends Live Activities for tracked bides that are no longer in the group.
    private func endActivities(except keep: Set<UUID>) {
        for stale in trackedBideIDs.subtracting(keep) {
            activities.end(bideID: stale)
        }
    }

    /// Publishes one arrival reading to every bide sharing the active route.
    /// Each participant row retains its selected travel mode; no location is sent.
    private func publish(_ result: Result<ETAReading, ETAError>, for bideIDs: Set<UUID>) async {
        guard case .success(let reading) = result else {
            if case .failure(.locationUnavailable) = result {
                errorMessage = ETAError.locationUnavailable.errorDescription
            }
            return
        }

        for bideID in bideIDs {
            readings[bideID] = reading

            let baselineETA = baseline[bideID] ?? reading.arrival
            baseline[bideID] = baselineETA

            // Record departure once and preserve that timestamp across later readings.
            if reading.hasDeparted, departures[bideID] == nil {
                departures[bideID] = reading.anchoredAt
            }

            let mode = userID
                .flatMap { me in bides.first { $0.bideID == bideID }?.participant(me)?.mode }
                ?? reading.mode

            do {
                _ = try await api.updateMyETA(
                    bideID: bideID,
                    arrivingAt: reading.arrival,
                    baselineETA: baselineETA,
                    travelTime: reading.travelTime,
                    leftAt: departures[bideID],
                    mode: mode,
                    status: reading.hasArrived ? .arrived : .accepted
                )
            } catch let error as APIError {
                if !error.isCancellation { errorMessage = error.errorDescription }
            } catch {
                errorMessage = "Couldn't publish your ETA."
            }
        }

        await refresh()
    }

    /// Restores recorded departure times so relaunch does not reset a journey.
    private func adoptRecordedDepartures() {
        guard let userID else { return }
        for state in bides {
            guard let leftAt = state.participant(userID)?.leftAt else { continue }
            if departures[state.bideID] == nil { departures[state.bideID] = leftAt }
        }
    }

    // MARK: - Plumbing

    private func perform(_ work: @escaping () async throws -> Void) async {
        do {
            try await work()
            errorMessage = nil
        } catch let error as APIError {
            if !error.isCancellation { errorMessage = error.errorDescription }
        } catch is CancellationError {
            // Expected task cancellation during teardown.
        } catch {
            errorMessage = "Something went wrong."
        }
    }

    /// Pushes the local display name when first needed by a participant roster.
    private func nameMyselfIfNeeded() async throws {
        guard let name = profile.displayName else { return }
        try await api.updateDisplayName(name)
    }

    private func merge(_ state: BideState) {
        if let index = bides.firstIndex(where: { $0.bideID == state.bideID }) {
            bides[index] = state
        } else {
            bides.insert(state, at: 0)
        }
    }
}
