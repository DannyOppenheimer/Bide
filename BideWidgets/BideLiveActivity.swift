import ActivityKit
import SwiftUI
import WidgetKit
import BideKit
import BideUI

/// Renders Live Activity state prepared by the container app.
struct BideLiveActivity: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BideActivityAttributes.self) { context in
            LockScreenView(
                destinationName: context.attributes.destinationName,
                scheduledFor: context.attributes.scheduledFor,
                state: context.state
            )
            .activityBackgroundTint(BideColor.background)
            .activitySystemActionForegroundColor(BideColor.primaryText)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 10) {
                        headline(for: context.state)
                        // Display the destination beside the timing instruction.
                        Text(context.attributes.destinationName)
                            .font(BideFont.caption)
                            .foregroundStyle(BideColor.secondaryText)
                            .lineLimit(1)
                        roster(
                            for: context.state,
                            scheduledFor: context.attributes.scheduledFor,
                            avatarSize: 40
                        )
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                BideMark(.horizontal, dotDiameter: 4)
            } compactTrailing: {
                // Show the most relevant compact value: departure, "Now", or arrival.
                // Intrinsic width preserves the system margins.
                Group {
                    if let leaveAt = departureAhead(in: context.state) {
                        // System-managed departure countdown.
                        Text(leaveAt, style: .timer)
                            .monospacedDigit()
                    } else if context.state.leaveAt != nil, !context.state.isComplete {
                        // Avoid `.timer` after departure because it would count upward.
                        Text("Now")
                    } else if let arrival = arrivalAhead(in: context.state) {
                        // After departure, show remaining travel time.
                        Text(arrival, style: .timer)
                            .monospacedDigit()
                    }
                }
                .font(BideFont.caption)
                .foregroundStyle(BideColor.primaryText)
            } minimal: {
                // Nudge the narrow vertical mark off the edge. Kept small because
                // the offset does not grow the frame, so a large shift shows the
                // mark outside the region the system sized for it and it clips.
                BideMark(.vertical, dotDiameter: 4)
                    .offset(x: 2)
            }
            .keylineTint(BideColor.live)
        }
    }

    @ViewBuilder
    private func headline(for state: BideActivityAttributes.ContentState) -> some View {
        Group {
            if let leaveAt = departureAhead(in: state) {
                Text("Leave in \(Text(leaveAt, style: .relative))")
            } else {
                Text(state.headline)
            }
        }
        .font(BideFont.cardTitle)
        .foregroundStyle(BideColor.primaryText)
    }

    private func roster(
        for state: BideActivityAttributes.ContentState,
        scheduledFor: Date?,
        avatarSize: CGFloat
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(state.participants.prefix(4)) { participant in
                ParticipantTile(
                    participant: participant,
                    scheduledArrival: scheduledFor,
                    // The shared schedule is displayed once above this compact roster.
                    showsSchedule: false,
                    avatarSize: avatarSize
                )
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Returns a departure more than one minute ahead. Past dates are excluded
    /// because relative text would switch to an upward-counting stopwatch.
    private func departureAhead(in state: BideActivityAttributes.ContentState) -> Date? {
        guard let leaveAt = state.leaveAt, !state.isComplete else { return nil }
        return leaveAt.timeIntervalSinceNow > 60 ? leaveAt : nil
    }

    /// Returns a future arrival only after the local user has departed.
    private func arrivalAhead(in state: BideActivityAttributes.ContentState) -> Date? {
        guard state.hasDeparted, !state.isComplete, let arrival = state.myArrival else { return nil }
        return arrival.timeIntervalSinceNow > 0 ? arrival : nil
    }

    /// Lock Screen and notification-banner layout.
    private struct LockScreenView: View {

        let destinationName: String
        let scheduledFor: Date?
        let state: BideActivityAttributes.ContentState

        var body: some View {
            // Fill the fixed-height system box exactly; flexible spacers yield to Dynamic Type.
            VStack(spacing: 0) {
                header
                Spacer(minLength: 6)
                headline
                Spacer(minLength: 6)
                // Use smaller avatars to fit richer participant tiles in the fixed box.
                roster(avatarSize: 34)
            }
            .padding(.horizontal, BideMetrics.cardPadding)
            .padding(.vertical, 10)
            .frame(
                maxWidth: .infinity,
                maxHeight: BideMetrics.liveActivityMaxHeight
            )
        }

        /// Compact row containing branding, destination, schedule, and live state.
        private var header: some View {
            HStack(spacing: 8) {
                BideMark(.horizontal, dotDiameter: 5)
                // Display the shared schedule once rather than under every participant.
                Text(scheduledFor.map { "\(destinationName) · \(BideFormat.time($0))" } ?? destinationName)
                    .font(BideFont.caption)
                    .foregroundStyle(BideColor.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                LivePill()
            }
        }

        /// Uses the same future-departure rule as the Dynamic Island.
        @ViewBuilder
        private var headline: some View {
            Group {
                if let leaveAt = state.leaveAt, !state.isComplete, leaveAt.timeIntervalSinceNow > 60 {
                    Text("Leave in \(Text(leaveAt, style: .relative))")
                } else {
                    Text(state.headline)
                }
            }
            .font(BideFont.cardTitle)
            .foregroundStyle(BideColor.primaryText)
            .lineLimit(1)
            // Scale after spacers collapse to avoid clipping larger text.
            .minimumScaleFactor(0.7)
        }

        private func roster(avatarSize: CGFloat) -> some View {
            HStack(alignment: .top, spacing: 16) {
                ForEach(state.participants.prefix(4)) { participant in
                    ParticipantTile(
                        participant: participant,
                        scheduledArrival: scheduledFor,
                        // The header already displays the shared schedule.
                        showsSchedule: false,
                        avatarSize: avatarSize
                    )
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
}
