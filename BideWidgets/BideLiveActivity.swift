import ActivityKit
import SwiftUI
import WidgetKit
import BideKit
import BideUI

/// The Live Activity — `notifications-screen`, and the surface the design
/// brief treats as the main event.
///
/// It renders from `ContentState` and the attributes alone. Everything it needs
/// was decided by the container app, which is the only place that can compute
/// an ETA, so there is no logic here beyond layout.
struct BideLiveActivity: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BideActivityAttributes.self) { context in
            LockScreenView(
                destinationName: context.attributes.destinationName,
                state: context.state
            )
            .activityBackgroundTint(BideColor.background)
            .activitySystemActionForegroundColor(BideColor.primaryText)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 10) {
                        headline(for: context.state)
                        // Where they're going is half the message. Without it
                        // the island says when to leave and leaves the reader
                        // to remember what for.
                        Text(context.attributes.destinationName)
                            .font(BideFont.caption)
                            .foregroundStyle(BideColor.secondaryText)
                            .lineLimit(1)
                        roster(for: context.state, avatarSize: 44)
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                BideMark(.horizontal, dotDiameter: 4)
            } compactTrailing: {
                // No `frame(maxWidth:)`. It reserved 52pt for a timer that
                // renders at about 30, and centred the digits in it — so the
                // gap between the digits and the edge of the island was the
                // leftover padding, visibly wider than the flush margin the
                // mark gets on the other side. Sized to its content, both
                // sides get the same margin from the system.
                //
                // Monospaced so the width doesn't twitch as the digits change,
                // which would move that margin once a second.
                Group {
                    if let leaveAt = departureAhead(in: context.state) {
                        Text(leaveAt, style: .timer)
                            .monospacedDigit()
                    } else if context.state.leaveAt != nil, !context.state.isComplete {
                        // The departure is here. `.timer` would start counting
                        // up, turning "go now" into elapsed time.
                        Text("now")
                    }
                }
                .font(BideFont.caption)
                .foregroundStyle(BideColor.primaryText)
            } minimal: {
                BideMark(.vertical, dotDiameter: 4)
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
        avatarSize: CGFloat
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(state.participants.prefix(4)) { participant in
                ParticipantTile(participant: participant, avatarSize: avatarSize)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// The user's departure, but only while it is still ahead of them.
    ///
    /// Everything about the headline turns on this. `Text(_, style: .relative)`
    /// renders the *distance* to a date and counts **upwards** once the date is
    /// behind it, so a departure that has passed becomes a stopwatch — which is
    /// how "Leave now" turned into "Leave 28 minutes" and climbing. For an asap
    /// bide the departure is `now` by definition, so it is behind the moment it
    /// is written and that was the normal case, not an edge one.
    ///
    /// Nil hands the line back to ``ContentState/headline``, which the app
    /// computed with `BidePlanner` and which has the right words for every
    /// other case — "Leave now", "Waiting for Sarah to leave", "Everyone's
    /// here". The old code reached past that string whenever a departure
    /// existed at all, which is why the lock screen and the app could describe
    /// the same plan differently.
    ///
    /// The minute of margin keeps the countdown from being handed a value it
    /// would render as a few seconds and then immediately invert.
    private func departureAhead(in state: BideActivityAttributes.ContentState) -> Date? {
        guard let leaveAt = state.leaveAt, !state.isComplete else { return nil }
        return leaveAt.timeIntervalSinceNow > 60 ? leaveAt : nil
    }

    /// The lock-screen and banner presentation.
    private struct LockScreenView: View {

        let destinationName: String
        let state: BideActivityAttributes.ContentState

        var body: some View {
            // iOS draws this in a box of a fixed height —
            // ``BideMetrics/liveActivityMaxHeight`` — and neither grows nor
            // shrinks it to suit. Content taller than the box is *clipped*,
            // from both ends: the layout this replaced measured 202pt and lost
            // the mark off the top and the ETAs off the bottom. Content shorter
            // than the box leaves a band of empty background under it.
            //
            // So the job is to be exactly that height, not merely under it.
            // The spacers are what do it: they take up whatever is left after
            // the header, the headline and the roster have had what they need,
            // and they collapse to `minLength` first when Dynamic Type wants
            // the room back. That makes the same layout right at any box height
            // from about 150pt up, which matters because 160 is Apple's
            // documented figure rather than one this code can measure.
            VStack(spacing: 0) {
                header
                Spacer(minLength: 6)
                headline
                Spacer(minLength: 6)
                roster(avatarSize: 40)
            }
            .padding(.horizontal, BideMetrics.cardPadding)
            .padding(.vertical, 10)
            .frame(
                maxWidth: .infinity,
                maxHeight: BideMetrics.liveActivityMaxHeight
            )
        }

        /// The mark, where the bide is going, and whether it's live — one row,
        /// because three stacked lines of chrome is what pushed the ETAs off
        /// the bottom of the screen.
        private var header: some View {
            HStack(spacing: 8) {
                BideMark(.horizontal, dotDiameter: 5)
                Text(destinationName)
                    .font(BideFont.caption)
                    .foregroundStyle(BideColor.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                LivePill()
            }
        }

        /// See `BideLiveActivity.departureAhead(in:)` — same rule, same reason.
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
            // Once the spacers have collapsed there is nowhere left for large
            // type to go but over the edge, so the text gives way instead.
            .minimumScaleFactor(0.7)
        }

        private func roster(avatarSize: CGFloat) -> some View {
            HStack(alignment: .top, spacing: 16) {
                ForEach(state.participants.prefix(4)) { participant in
                    ParticipantTile(participant: participant, avatarSize: avatarSize)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}
