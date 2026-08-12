import ActivityKit
import SwiftUI
import WidgetKit
import BideKit
import BideUI

/// The Live Activity — `notifications-screen`, and the surface the design
/// brief treats as the main event.
///
/// It renders from `ContentState` alone. Everything it needs was decided by
/// the container app, which is the only place that can compute an ETA, so
/// there is no logic here beyond layout.
struct BideLiveActivity: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BideActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(BideColor.background)
                .activitySystemActionForegroundColor(BideColor.primaryText)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 12) {
                        headline(for: context.state)
                        roster(for: context.state, avatarSize: 44)
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                BideMark(.horizontal, dotDiameter: 4)
            } compactTrailing: {
                if let leaveAt = context.state.leaveAt {
                    Text(leaveAt, style: .timer)
                        .font(BideFont.caption)
                        .foregroundStyle(BideColor.primaryText)
                        .frame(maxWidth: 52)
                }
            } minimal: {
                BideMark(.vertical, dotDiameter: 4)
            }
            .keylineTint(BideColor.live)
        }
    }

    @ViewBuilder
    private func headline(for state: BideActivityAttributes.ContentState) -> some View {
        if let leaveAt = state.leaveAt, !state.isComplete {
            // A self-updating countdown, so the lock screen stays right
            // between pushes rather than going stale between them.
            Text("Leave \(Text(leaveAt, style: .relative))")
                .font(BideFont.cardTitle)
                .foregroundStyle(BideColor.primaryText)
        } else {
            Text(state.headline)
                .font(BideFont.cardTitle)
                .foregroundStyle(BideColor.primaryText)
        }
    }

    private func roster(
        for state: BideActivityAttributes.ContentState,
        avatarSize: CGFloat
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(state.participants.prefix(4)) { participant in
                ParticipantTile(participant: participant, avatarSize: avatarSize)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// The lock-screen and banner presentation.
    private struct LockScreenView: View {

        let state: BideActivityAttributes.ContentState

        var body: some View {
            VStack(spacing: 14) {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 4) {
                        BideMark(.horizontal, dotDiameter: 6)
                        Text("BIDE")
                            .font(BideFont.badge)
                            .kerning(1.2)
                            .foregroundStyle(BideColor.secondaryText)
                    }
                    .frame(maxWidth: .infinity)

                    LivePill()
                }

                if let leaveAt = state.leaveAt, !state.isComplete {
                    Text("Leave \(Text(leaveAt, style: .relative))")
                        .font(BideFont.cardTitle)
                        .foregroundStyle(BideColor.primaryText)
                } else {
                    Text(state.headline)
                        .font(BideFont.cardTitle)
                        .foregroundStyle(BideColor.primaryText)
                }

                HStack(alignment: .top, spacing: 16) {
                    ForEach(state.participants.prefix(4)) { participant in
                        ParticipantTile(participant: participant)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(BideMetrics.cardPadding)
        }
    }
}
