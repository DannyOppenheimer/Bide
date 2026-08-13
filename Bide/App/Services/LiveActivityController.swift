import ActivityKit
import Foundation
import BideKit

/// Manages local Live Activities from the container app.
/// Remote starts and updates are not configured.
@MainActor
final class LiveActivityController {

    private var activities: [UUID: Activity<BideActivityAttributes>] = [:]

    /// Maximum time before departure for starting a Live Activity.
    private static let leadTime: TimeInterval = 2 * 60 * 60

    /// Content freshness limit, longer than the slowest normal ETA refresh cadence.
    private static let contentLifetime: TimeInterval = 15 * 60

    /// - Parameter me: Local user identifier used to label their row as "You".
    func start(state: BideState, plan: BidePlan, me: UUID? = nil, now: Date = Date()) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard activities[state.bideID] == nil else {
            update(state: state, plan: plan, me: me, now: now)
            return
        }

        // Do not start activities before the configured lead time.
        if let departure = plan.departure, departure.timeIntervalSince(now) > Self.leadTime {
            return
        }

        do {
            activities[state.bideID] = try Activity.request(
                attributes: BideActivityAttributes(
                    bideID: state.bideID,
                    destinationName: state.destinationName,
                    scheduledFor: state.scheduledFor
                ),
                content: ActivityContent(
                    state: content(for: state, plan: plan, me: me, now: now),
                    staleDate: now.addingTimeInterval(Self.contentLifetime)
                ),
                pushType: nil
            )
        } catch {
            // Activity denial or capacity does not prevent the rest of the app from working.
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
            participants: state.roster
                .map { ActivityParticipant(participant: $0, me: me, now: now) },
            // Stop showing a departure countdown after travel begins.
            leaveAt: plan.isHeldBack || plan.hasDeparted ? nil : plan.departure,
            myTravelTime: plan.travelTime,
            myArrival: plan.arrival,
            hasDeparted: plan.hasDeparted,
            isComplete: state.isComplete
        )
    }
}
