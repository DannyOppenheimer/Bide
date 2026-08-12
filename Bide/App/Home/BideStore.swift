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

    private var userID: UUID?
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
        answers: LocalBideStore = LocalBideStore(defaults: .bideShared)
    ) {
        self.api = api
        self.eta = eta
        self.activities = activities ?? LiveActivityController()
        self.profile = profile
        self.answers = answers
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
            bides = try await api.fetchMyBides().filter { !$0.isComplete }
            errorMessage = nil
            reconcileTracking()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Couldn't reach Bide."
        }

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

    /// Creates a bide from a draft — the app's own solo composer, or a tile
    /// the extension just staged.
    func create(_ draft: BidePlanDraft, isSolo: Bool, id: UUID? = nil) async {
        guard let invite = draft.invite(id: id ?? UUID()) else { return }
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
            // The extension staged the tile; this side makes it real.
            let draft = BidePlanDraft(
                destination: tile.invite.destination,
                mode: mode,
                scheduledFor: tile.invite.scheduledFor,
                arrivalStyle: tile.invite.arrivalStyle
            )
            await create(draft, isSolo: false, id: tile.invite.bideID)
        default:
            await accept(tile, mode: mode)
        }
    }

    // MARK: - Conflicts

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
            activities.update(state: candidate, plan: plan(for: candidate), now: Date())
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
        activities.start(state: candidate, plan: plan(for: candidate))
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
