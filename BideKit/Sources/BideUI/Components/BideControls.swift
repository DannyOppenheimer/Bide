import SwiftUI
import BideKit

/// The white pill that ends every Bide form — Send, Save, Accept.
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

/// The outlined pill that sits beside it — Decline.
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

/// The two chip looks the reference screens use: white on the Messages
/// compose sheet, grey on the app's own card.
public enum BideChipEmphasis: Sendable {
    /// White fill, dark text.
    case solid
    /// Grey fill, white text.
    case subtle
}

/// A small rounded value button — the date, the time, the arrival style.
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

/// A label above a field — "Date", "Time", "Arrival Style".
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

/// The red LIVE badge on an active session.
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

/// Someone's circle in the roster, with their travel mode tucked into the
/// corner exactly as the reference screens show it.
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

/// One person in the roster: avatar, name, and their line — "Waiting..." until
/// they set off, then a live ETA coloured by how far behind they are.
public struct ParticipantTile: View {

    private let name: String
    private let initial: String
    private let mode: TravelMode
    private let status: String
    private let grade: DelayGrade?
    private let avatarSize: CGFloat

    public init(
        name: String,
        initial: String,
        mode: TravelMode,
        status: String,
        grade: DelayGrade? = nil,
        avatarSize: CGFloat = BideMetrics.avatarSize
    ) {
        self.name = name
        self.initial = initial
        self.mode = mode
        self.status = status
        self.grade = grade
        self.avatarSize = avatarSize
    }

    public init(participant: Participant, now: Date = Date(), avatarSize: CGFloat = BideMetrics.avatarSize) {
        self.init(
            name: BideFormat.name(participant),
            initial: BideFormat.initial(participant),
            mode: participant.mode,
            status: BideFormat.participantStatus(participant, now: now),
            grade: participant.delayGrade,
            avatarSize: avatarSize
        )
    }

    /// The Live Activity's flattened form, which arrives ready to draw.
    public init(participant: ActivityParticipant, avatarSize: CGFloat = BideMetrics.avatarSize) {
        self.init(
            name: participant.name,
            initial: participant.initial,
            mode: participant.mode,
            status: participant.line,
            grade: participant.grade,
            avatarSize: avatarSize
        )
    }

    public var body: some View {
        VStack(spacing: 6) {
            ParticipantAvatar(initial: initial, mode: mode, size: avatarSize)
            Text(name)
                .font(BideFont.personName)
                .foregroundStyle(BideColor.primaryText)
            Text(status)
                .font(BideFont.caption)
                .foregroundStyle(grade.map(BideColor.delay) ?? BideColor.secondaryText)
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(status)")
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
            ParticipantTile(name: "Michael", initial: "M", mode: .transit, status: "45 minutes", grade: .slipping)
        }
        Button("Accept") {}.buttonStyle(.bidePrimary)
        Button("Decline") {}.buttonStyle(.bideSecondary)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .bideBackground()
}
