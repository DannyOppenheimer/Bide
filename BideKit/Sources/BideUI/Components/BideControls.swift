import SwiftUI
import BideKit

/// Primary full-width pill button used for form actions.
public struct BidePrimaryButtonStyle: ButtonStyle {

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BideFont.button)
            .foregroundStyle(BideColor.inverseText)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(BideColor.primaryText, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Secondary outlined pill button.
public struct BideSecondaryButtonStyle: ButtonStyle {

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BideFont.button)
            .foregroundStyle(BideColor.primaryText)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Capsule().stroke(BideColor.border, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == BidePrimaryButtonStyle {
    public static var bidePrimary: BidePrimaryButtonStyle { BidePrimaryButtonStyle() }
}

extension ButtonStyle where Self == BideSecondaryButtonStyle {
    public static var bideSecondary: BideSecondaryButtonStyle { BideSecondaryButtonStyle() }
}

/// Visual emphasis options for value chips.
public enum BideChipEmphasis: Sendable {
    /// Light fill with dark text.
    case solid
    /// Dark fill with light text.
    case subtle
}

/// Compact rounded button for date, time, and arrival-style values.
public struct BideChip<Label: View>: View {

    private let emphasis: BideChipEmphasis
    private let action: () -> Void
    private let label: Label

    public init(
        emphasis: BideChipEmphasis = .solid,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.emphasis = emphasis
        self.action = action
        self.label = label()
    }

    public var body: some View {
        Button(action: action) {
            label
                .font(BideFont.cardTitle)
                .foregroundStyle(emphasis == .solid ? BideColor.inverseText : BideColor.primaryText)
                .padding(.horizontal, 16)
                .frame(height: 36)
                .background(
                    emphasis == .solid ? BideColor.primaryText : BideColor.control,
                    in: RoundedRectangle(cornerRadius: BideMetrics.controlRadius, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }
}

/// Label displayed above a form field.
public struct BideFieldLabel: View {

    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(BideFont.label)
            .foregroundStyle(BideColor.secondaryText)
    }
}

/// Live-status badge for an active session.
public struct LivePill: View {

    public init() {}

    public var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(BideColor.primaryText)
                .frame(width: 6, height: 6)
            Text("LIVE")
                .font(BideFont.badge)
                .foregroundStyle(BideColor.primaryText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(BideColor.live, in: Capsule())
        .accessibilityLabel("Live")
    }
}

/// Badge for a journey the local user is following rather than attending.
public struct WatchingPill: View {

    public init() {}

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "eye.fill")
                .font(.system(size: 8, weight: .bold))
            Text("TRACKING")
                .font(BideFont.badge)
        }
        .foregroundStyle(BideColor.primaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(BideColor.watching, in: Capsule())
        .accessibilityLabel("Tracking someone else's trip")
    }
}

/// Participant avatar with a travel-mode badge.
public struct ParticipantAvatar: View {

    private let initial: String
    private let mode: TravelMode
    private let size: CGFloat

    public init(initial: String, mode: TravelMode, size: CGFloat = BideMetrics.avatarSize) {
        self.initial = initial
        self.mode = mode
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(BideColor.avatar)
            .frame(width: size, height: size)
            .overlay {
                Text(initial)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(BideColor.primaryText)
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: mode.symbolName)
                    .font(.system(size: size * 0.24, weight: .semibold))
                    .foregroundStyle(BideColor.primaryText)
                    .frame(width: size * 0.42, height: size * 0.42)
                    .background(BideColor.background, in: Circle())
                    .offset(x: size * 0.04, y: size * 0.04)
            }
            .accessibilityHidden(true)
    }
}

/// Roster tile showing a participant's identity and journey state.
public struct ParticipantTile: View {

    private let name: String
    private let initial: String
    private let mode: TravelMode
    private let status: String
    /// Latest journey duration, if the participant has an active journey.
    private let travelTime: TimeInterval?
    /// Expected arrival, counted down only after departure.
    private let arrival: Date?
    private let hasDeparted: Bool
    /// Shared scheduled arrival, omitted for ASAP bides.
    private let scheduledArrival: Date?
    /// Whether the tile has room to repeat the scheduled arrival.
    private let showsSchedule: Bool
    private let grade: DelayGrade?
    private let now: Date
    private let avatarSize: CGFloat

    public init(
        name: String,
        initial: String,
        mode: TravelMode,
        status: String,
        travelTime: TimeInterval? = nil,
        arrival: Date? = nil,
        hasDeparted: Bool = false,
        scheduledArrival: Date? = nil,
        showsSchedule: Bool = true,
        grade: DelayGrade? = nil,
        now: Date = Date(),
        avatarSize: CGFloat = BideMetrics.avatarSize
    ) {
        self.name = name
        self.initial = initial
        self.mode = mode
        self.status = status
        self.travelTime = travelTime
        self.arrival = arrival
        self.hasDeparted = hasDeparted
        self.scheduledArrival = scheduledArrival
        self.showsSchedule = showsSchedule
        self.grade = grade
        self.now = now
        self.avatarSize = avatarSize
    }

    /// - Parameter me: Local user identifier used to label their tile as "You".
    public init(
        participant: Participant,
        me: UUID? = nil,
        scheduledArrival: Date? = nil,
        showsSchedule: Bool = true,
        now: Date = Date(),
        avatarSize: CGFloat = BideMetrics.avatarSize
    ) {
        self.init(
            name: BideFormat.name(participant, me: me),
            initial: BideFormat.initial(participant, me: me),
            mode: participant.mode,
            status: BideFormat.participantStatus(participant, now: now),
            travelTime: participant.remainingTravel(now: now),
            arrival: participant.arrival(now: now),
            hasDeparted: participant.hasLeft,
            scheduledArrival: scheduledArrival,
            showsSchedule: showsSchedule,
            grade: participant.delayGrade,
            now: now,
            avatarSize: avatarSize
        )
    }

    /// Creates a tile from display-ready Live Activity data.
    public init(
        participant: ActivityParticipant,
        scheduledArrival: Date? = nil,
        showsSchedule: Bool = true,
        now: Date = Date(),
        avatarSize: CGFloat = BideMetrics.avatarSize
    ) {
        self.init(
            name: participant.name,
            initial: participant.initial,
            mode: participant.mode,
            status: participant.line,
            travelTime: participant.travelTime,
            arrival: participant.eta,
            hasDeparted: participant.hasDeparted,
            scheduledArrival: scheduledArrival,
            showsSchedule: showsSchedule,
            grade: participant.grade,
            now: now,
            avatarSize: avatarSize
        )
    }

    public var body: some View {
        VStack(spacing: 6) {
            ParticipantAvatar(initial: initial, mode: mode, size: avatarSize)
            Text(name)
                .font(BideFont.personName)
                .foregroundStyle(BideColor.primaryText)
            journey
                .foregroundStyle(grade.map(BideColor.delay) ?? BideColor.secondaryText)
        }
        .lineLimit(1)
        // Allow long schedule labels to fit when four tiles share the width.
        .minimumScaleFactor(0.6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(status)")
    }

    /// Shows a fixed journey duration before departure and a live countdown
    /// afterward. Participants without a journey display their status text.
    @ViewBuilder
    private var journey: some View {
        if let travelTime {
            let arrival = arrival ?? now.addingTimeInterval(travelTime)
            VStack(spacing: 2) {
                Group {
                    if hasDeparted, arrival > now {
                        Text(arrival, style: .relative)
                    } else {
                        Text(BideFormat.shortDuration(travelTime))
                    }
                }
                .font(BideFont.etaValue)
                .monospacedDigit()

                VStack(spacing: 0) {
                    if showsSchedule, let scheduledArrival {
                        Text(BideFormat.scheduledLine(scheduledArrival))
                            .foregroundStyle(BideColor.secondaryText)
                    }
                    // Before departure, update the moving "now + duration" arrival each minute.
                    if hasDeparted {
                        Text(BideFormat.arrivalLine(arrival, comparedTo: scheduledArrival))
                    } else {
                        TimelineView(.periodic(from: now, by: 60)) { context in
                            Text(
                                BideFormat.arrivalLine(
                                    context.date.addingTimeInterval(travelTime),
                                    comparedTo: scheduledArrival
                                )
                            )
                        }
                    }
                }
                .font(BideFont.caption)
            }
        } else {
            Text(status)
                .font(BideFont.caption)
        }
    }
}

#Preview("Controls") {
    VStack(spacing: 20) {
        LivePill()
        HStack(spacing: 12) {
            BideChip(action: {}) { Text("Today") }
            BideChip(emphasis: .subtle, action: {}) { Text("3:00 PM") }
        }
        HStack(spacing: 16) {
            ParticipantTile(name: "Sarah", initial: "S", mode: .driving, status: "Waiting...")
            ParticipantTile(
                name: "Michael",
                initial: "M",
                mode: .transit,
                status: "45 minutes",
                travelTime: 45 * 60,
                arrival: Date().addingTimeInterval(45 * 60),
                hasDeparted: true,
                scheduledArrival: Date().addingTimeInterval(35 * 60),
                grade: .slipping
            )
        }
        Button("Accept") {}.buttonStyle(.bidePrimary)
        Button("Decline") {}.buttonStyle(.bideSecondary)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .bideBackground()
}
