import ActivityKit
import Foundation
import BideKit

/// Starts, updates, and ends the Live Activity.
///
/// Lives in the container app because it has to: the Messages extension can't
/// touch ActivityKit at all. Everything here is local — the app updates its own
/// activity while it's running. Push-to-start and push updates need an APNs key
/// that isn't wired up yet; when it is, this is the one file that changes.
@MainActor
final class LiveActivityController {

    private var activities: [UUID: Activity<BideActivityAttributes>] = [:]

    /// How far ahead of leaving to put a bide on the lock screen. Any earlier
    /// and it's clutter; any later and it isn't a warning.
    private static let leadTime: TimeInterval = 2 * 60 * 60

    /// How long the numbers on the lock screen are worth believing.
    ///
    /// Everything in the content is an estimate anchored at the moment it was
    /// pushed. Other people's ETAs in particular only move when this app is
    /// running and polling, so a phone in a pocket for half an hour leaves a
    /// lock screen quietly asserting where everyone was half an hour ago —
    /// with no way for the reader to tell. `staleDate` is how the system is
    /// told that: past it, iOS dims the activity and marks it out of date, so
    /// old numbers look old instead of looking current.
    ///
    /// Fifteen minutes: comfortably more than the ETA engine's slowest
    /// re-anchor cadence (10 minutes, walking), so a bide that is being
    /// tracked normally never trips it.
    private static let contentLifetime: TimeInterval = 15 * 60

    /// - Parameter me: The local user's id, so their own row on the lock
    ///   screen reads "You" rather than their name or a placeholder.
    func start(state: BideState, plan: BidePlan, me: UUID? = nil, now: Date = Date()) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard activities[state.bideID] == nil else {
            update(state: state, plan: plan, me: me, now: now)
            return
        }

        // Don't take over someone's lock screen for a meetup that's tomorrow.
        if let departure = plan.departure, departure.timeIntervalSince(now) > Self.leadTime {
            return
        }

        do {
            activities[state.bideID] = try Activity.request(
                attributes: BideActivityAttributes(
                    bideID: state.bideID,
                    destinationName: state.destinationName
                ),
                content: ActivityContent(
                    state: content(for: state, plan: plan, me: me, now: now),
                    staleDate: now.addingTimeInterval(Self.contentLifetime)
                ),
                pushType: nil
            )
        } catch {
            // Denied, or too many activities already. Not fatal: the app and
            // the tile still work, so this stays quiet rather than throwing.
        }
    }

    func update(state: BideState, plan: BidePlan, me: UUID? = nil, now: Date = Date()) {
        guard let activity = activities[state.bideID] else {
            start(state: state, plan: plan, me: me, now: now)
            return
        }

        let content = content(for: state, plan: plan, me: me, now: now)
        Task {
            await activity.update(
                ActivityContent(
                    state: content,
                    staleDate: now.addingTimeInterval(Self.contentLifetime)
                )
            )
            if content.isComplete {
                await activity.end(nil, dismissalPolicy: .default)
                activities[state.bideID] = nil
            }
        }
    }

    func end(bideID: UUID) {
        guard let activity = activities.removeValue(forKey: bideID) else { return }
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private func content(
        for state: BideState,
        plan: BidePlan,
        me: UUID?,
        now: Date
    ) -> BideActivityAttributes.ContentState {
        BideActivityAttributes.ContentState(
            headline: BidePlanner.headline(for: plan, state: state, now: now),
            participants: state.participants
                .filter { $0.status != .declined }
                .map { ActivityParticipant(participant: $0, me: me, now: now) },
            leaveAt: plan.isHeldBack ? nil : plan.departure,
            isComplete: state.isComplete
        )
    }
}
