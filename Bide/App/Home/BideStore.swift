import Foundation
import Observation
import BideKit

/// The app's one piece of shared state, and the only place that decides what
/// Bide does next.
///
/// It owns the loop the whole product rests on: anchor an ETA on-device,
/// publish the arrival *timestamp*, refresh everyone else's, and keep the Live
/// Activity saying the right thing. Nothing else in the app talks to the ETA
/// engine or to the server.
@MainActor
@Observable
final class BideStore {

    /// A clash the user has to agree to before it happens.
    struct ConflictPrompt: Identifiable {
        let id = UUID()
        let message: String
        /// The bides they'd be dropped from.
        let losing: [UUID]
        /// What to do if they say yes.
        let proceed: () async -> Void
    }

    private(set) var bides: [BideState] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// The bide currently being tracked — at most one, because a person can
    /// only be going to one place at a time.
    private(set) var trackedBideID: UUID?
    var conflict: ConflictPrompt?

    /// How often the app re-reads everyone else's ETAs while it's open.
    ///
    /// Polling, not sockets: the backend has realtime off on purpose, and the
    /// push path that replaces this needs an APNs key that isn't wired up yet.
    /// Foreground-only, so it costs nothing when the app isn't on screen.
    private static let refreshInterval: Duration = .seconds(30)

    private let api: any BideAPI
    private let eta: any ETAEngine
    private let activities: LiveActivityController
    private let profile: BideProfileStore
    private let answers: LocalBideStore
    private let pending: PendingInviteStore

    /// Who the local user is, so a roster can tell their row from everyone
    /// else's. Nil until ``start(userID:)``.
    private(set) var userID: UUID?
    private var refreshTask: Task<Void, Never>?
    /// The ETA we first recorded for this bide, which every later one is
    /// graded against for the green/yellow/red colouring.
    private var baseline: [UUID: Date] = [:]

    /// `activities` is optional rather than defaulted: a default argument is
    /// evaluated outside the actor, and `LiveActivityController` is
    /// main-actor bound.
    init(
        api: any BideAPI,
        eta: any ETAEngine,
        activities: LiveActivityController? = nil,
        profile: BideProfileStore = BideProfileStore(),
        answers: LocalBideStore = LocalBideStore(defaults: .bideShared),
        pending: PendingInviteStore = PendingInviteStore()
    ) {
        self.api = api
        self.eta = eta
        self.activities = activities ?? LiveActivityController()
        self.profile = profile
        self.answers = answers
        self.pending = pending
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
    }

    // MARK: - Reading

    func refresh() async {
        guard userID != nil else { return }
        isLoading = bides.isEmpty

        do {
            // Two endings, and a bide needs only one of them. `isComplete` is
            // the tidy one and most bides never reach it, because it takes
            // everybody's app being open at the far end; `isExpired` is the
            // clock running out, which is what actually retires them. Filtered
            // here rather than in the query so the rule is one line of Swift
            // that the tests can read.
            let now = Date()
            bides = try await api.fetchMyBides().filter { !$0.isComplete && !$0.isExpired(now: now) }
            errorMessage = nil
            reconcileTracking()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Couldn't reach Bide."
        }

        await claimPendingInvites()
        isLoading = false
    }

    /// This person's plan for a bide: target arrival, when to leave, and
    /// whether they're being held back.
    func plan(for state: BideState, now: Date = Date()) -> BidePlan {
        guard let userID else {
            return BidePlan(targetArrival: state.scheduledFor, departure: nil)
        }
        let myTravelTime = state.participant(userID)?.etaTimestamp?.timeIntervalSince(now)
        return BidePlanner.plan(for: state, me: userID, myTravelTime: myTravelTime, now: now)
    }

    func headline(for state: BideState, now: Date = Date()) -> String {
        BidePlanner.headline(for: plan(for: state, now: now), state: state, now: now)
    }

    // MARK: - Writing

    /// Creates a bide from a draft — the app's own solo composer, or the
    /// calendar. A bide sent to other people goes through ``stage(_:mode:)``
    /// instead, and isn't created until somebody answers it.
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

    /// Accepting a tile handed over by the Messages extension.
    func accept(_ tile: BideTileMessage, mode: TravelMode) async {
        await withConflictCheck(for: tile.invite, mode: mode) { [weak self] in
            guard let self else { return }
            await perform {
                // Idempotent server-side: accepting twice refreshes the mode.
                let state = try await self.join(tile.invite, mode: mode)
                try await self.nameMyselfIfNeeded()
                self.merge(state)
                self.reconcileTracking()
            }
        }
    }

    /// Saves the name locally — the extension reads it from the App Group when
    /// composing a tile — and pushes it to every participant row.
    func updateDisplayName(_ name: String) async {
        profile.displayName = name
        await perform {
            try await self.api.updateDisplayName(name)
            await self.refresh()
        }
    }

    /// Joins a bide, creating it first if nobody has yet.
    ///
    /// The sender's tile is staged in Messages before their own app has had a
    /// chance to write the bide to the server — and they might never open it,
    /// or be offline when they do. The invite URL carries everything the row
    /// needs, so whoever reaches the server first materialises it. Without
    /// this, a recipient who is quick off the mark gets "that meetup is no
    /// longer available" for a tile they are looking at.
    private func join(_ invite: BideInvite, mode: TravelMode) async throws(APIError) -> BideState {
        do {
            return try await api.joinBide(bideID: invite.bideID, mode: mode, status: .accepted)
        } catch APIError.notFound {
            // `create_bide` adds the caller as an accepted participant, so
            // this both creates and joins.
            return try await api.createBide(invite, mode: mode, isSolo: false)
        }
    }

    func leave(_ bideID: UUID) async {
        await perform {
            try await self.api.leaveBide(bideID: bideID)
            self.bides.removeAll { $0.bideID == bideID }
            self.answers.clear(bideID)
            self.activities.end(bideID: bideID)
            if self.trackedBideID == bideID {
                self.eta.stopTracking()
                self.trackedBideID = nil
            }
            self.reconcileTracking()
        }
    }

    /// Handles the `bide://` hand-off from the Messages extension.
    func handle(url: URL) async {
        guard let tile = BideTileMessage(url: url) else { return }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let mode = items.first { $0.name == "mode" }?.value
            .flatMap(TravelMode.init(rawValue:)) ?? .walking

        switch items.first(where: { $0.name == "action" })?.value {
        case "create":
            // Nothing opens the app this way any more: the extension records
            // the invite in the App Group and stays in the thread. Kept so a
            // URL from an older build — or one arriving some other way — still
            // lands somewhere sensible instead of being mistaken for an
            // acceptance, which would create the bide on the spot.
            //
            // Sending a tile puts a bide in someone else's thread and has to
            // outlive this install, so it needs an account behind it. The
            // extension checks the same flag; this is the check that holds if
            // the URL arrives any other way.
            guard profile.isSignedInWithApple else {
                errorMessage = "Sign in with Apple to send a Bide to someone."
                return
            }
            pending.add(PendingInvite(invite: tile.invite, mode: mode))
            await claimPendingInvites()
        default:
            await accept(tile, mode: mode)
        }
    }

    // MARK: - Invitations waiting on an answer

    /// Turns sent tiles into real sessions, once somebody has accepted one.
    ///
    /// `join_bide` is the test as much as the action. The bide row does not
    /// exist until a recipient accepts — their app creates it on the way in —
    /// so a join that comes back ``APIError/notFound`` means nobody has
    /// answered yet, and one that succeeds means somebody has and the sender
    /// belongs in it now.
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
                // Best effort, and after the fact: a name that doesn't land
                // is a blank avatar, not a reason to lose the session.
                try? await nameMyselfIfNeeded()
                warnIfClashing(with: state)
            } catch APIError.notFound {
                // Still unanswered. Ask again on the next refresh.
            } catch {
                // Offline, or the server is unwell. Leave every remaining
                // invite staged and stop asking until the next refresh — the
                // rest would fail the same way.
                return
            }
        }
    }

    // MARK: - Conflicts

    /// A tile the user sent has just been answered, so it is a commitment now
    /// rather than a question — and this is the first moment it can be weighed
    /// against the rest of their day, because until somebody accepted there was
    /// no bide to weigh.
    ///
    /// This check used to happen at send time, in the container app, which is
    /// why sending a tile threw the user out of Messages every time — to be
    /// asked, nine times in ten, nothing at all. Worse, it asked them to give
    /// up a real session for a hypothetical one that might never be answered.
    ///
    /// "Continue" drops the bides it clashes with, as before. "Cancel" now
    /// keeps both, which is the honest option here and wasn't at send time:
    /// somebody has already accepted this one, so quietly walking out of it
    /// would strand them.
    private func warnIfClashing(with state: BideState) {
        guard let userID, let proposed = state.travelWindow(for: userID) else { return }

        let existing = bides
            .filter { $0.bideID != state.bideID }
            .compactMap { other -> ScheduleConflict.Candidate? in
                guard let window = other.travelWindow(for: userID) else { return nil }
                return ScheduleConflict.Candidate(
                    id: other.bideID,
                    destinationName: other.destinationName,
                    window: window
                )
            }

        let clashes = ScheduleConflict.conflicts(
            with: proposed,
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

    /// The design's rule: a new commitment that overlaps an existing one wins,
    /// and you're told before it does.
    private func withConflictCheck(
        for invite: BideInvite,
        mode: TravelMode,
        proceed: @escaping () async -> Void
    ) async {
        guard let userID else { return await proceed() }

        // The proposed window needs this person's travel time, which is a
        // question only the on-device engine can answer.
        let travelTime = try? await eta.estimate(to: invite.destination, mode: mode).travelTime
        let arrival = invite.scheduledFor ?? Date().addingTimeInterval(travelTime ?? 0)
        let proposed = TravelWindow(arriveAt: arrival, travelTime: travelTime ?? 0)

        let existing = bides.compactMap { state -> ScheduleConflict.Candidate? in
            guard let window = state.travelWindow(for: userID) else { return nil }
            return ScheduleConflict.Candidate(
                id: state.bideID,
                destinationName: state.destinationName,
                window: window
            )
        }

        let clashes = ScheduleConflict.conflicts(
            with: proposed,
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

    /// Picks the bide worth tracking — the soonest one still ahead — and
    /// starts the engine on it. Called after anything that could change which
    /// that is.
    private func reconcileTracking() {
        guard let userID else { return }

        let candidate = bides
            .filter { $0.participant(userID)?.status.isTravelling == true }
            .min { lhs, rhs in
                let lhsTime = lhs.scheduledFor ?? lhs.createdAt
                let rhsTime = rhs.scheduledFor ?? rhs.createdAt
                return lhsTime < rhsTime
            }

        guard let candidate else {
            if let trackedBideID {
                activities.end(bideID: trackedBideID)
            }
            eta.stopTracking()
            trackedBideID = nil
            return
        }

        // Already on it: just refresh what's on the lock screen.
        guard candidate.bideID != trackedBideID else {
            activities.update(state: candidate, plan: plan(for: candidate), me: userID, now: Date())
            return
        }

        if let trackedBideID {
            activities.end(bideID: trackedBideID)
        }
        trackedBideID = candidate.bideID

        let mode = candidate.participant(userID)?.mode ?? .walking
        eta.startTracking(to: candidate.destination, mode: mode) { [weak self] result in
            Task { @MainActor in
                await self?.publish(result, for: candidate.bideID, mode: mode)
            }
        }
        activities.start(state: candidate, plan: plan(for: candidate), me: userID)
    }

    /// Sends one anchored reading to the server — an arrival timestamp and
    /// nothing else — and refreshes the lock screen with it.
    private func publish(_ result: Result<ETAReading, ETAError>, for bideID: UUID, mode: TravelMode) async {
        guard case .success(let reading) = result else {
            if case .failure(.locationUnavailable) = result {
                errorMessage = ETAError.locationUnavailable.errorDescription
            }
            return
        }

        let baselineETA = baseline[bideID] ?? reading.arrival
        baseline[bideID] = baselineETA

        do {
            _ = try await api.updateMyETA(
                bideID: bideID,
                arrivingAt: reading.arrival,
                baselineETA: baselineETA,
                mode: mode,
                status: reading.hasArrived ? .arrived : .accepted
            )
            await refresh()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Couldn't publish your ETA."
        }
    }

    // MARK: - Plumbing

    private func perform(_ work: @escaping () async throws -> Void) async {
        do {
            try await work()
            errorMessage = nil
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Something went wrong."
        }
    }

    /// Pushes the local display name to the server the first time it's needed,
    /// so other people see a name rather than a blank avatar.
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
