import SwiftUI

/// One action revealed by a horizontal swipe.
public struct BideSwipeAction {

    let title: String
    let systemImage: String
    let tint: Color
    /// Whether a full swipe performs the action without a second tap.
    let allowsFullSwipe: Bool
    let perform: () -> Void

    public init(
        title: String,
        systemImage: String,
        tint: Color,
        allowsFullSwipe: Bool = true,
        perform: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.allowsFullSwipe = allowsFullSwipe
        self.perform = perform
    }
}

/// Provides List-style swipe actions for cards inside a `ScrollView`.
/// Callers must also expose these actions through an accessible visible control
/// or context menu because swipe gestures are not discoverable by everyone.
public struct BideSwipeActions<Content: View>: View {

    /// Resting width of one revealed action.
    private static var revealWidth: CGFloat { 92 }

    /// Row-width fraction that triggers a full-swipe action.
    private static var fullSwipeFraction: CGFloat { 0.52 }

    /// Minimum projected drag needed to leave the action open.
    private static var openThreshold: CGFloat { revealWidth * 0.55 }

    private let id: AnyHashable
    private let leading: BideSwipeAction?
    private let trailing: BideSwipeAction?
    private let cornerRadius: CGFloat
    private let content: Content

    /// Identifier of the open row, shared so only one row stays open.
    @Binding private var openRow: AnyHashable?

    /// Horizontal content offset; positive reveals leading and negative trailing.
    @State private var offset: CGFloat = 0
    /// Content offset at the start of the current drag.
    @State private var settled: CGFloat = 0
    /// Translation where the gesture first committed to horizontal movement.
    @State private var claimedAt: CGFloat?
    @State private var width: CGFloat = 0

    public init(
        id: AnyHashable,
        openRow: Binding<AnyHashable?>,
        leading: BideSwipeAction? = nil,
        trailing: BideSwipeAction? = nil,
        cornerRadius: CGFloat = BideMetrics.cardRadius,
        @ViewBuilder content: () -> Content
    ) {
        self.id = id
        self._openRow = openRow
        self.leading = leading
        self.trailing = trailing
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        content
            // Attach the dismiss overlay to moving content so it does not cover the action.
            .overlay {
                if offset != 0 {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { close() }
                }
            }
            .offset(x: offset)
            .background(alignment: .leading) { actionLayer }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background {
                GeometryReader { proxy in
                    Color.clear.onAppear { width = proxy.size.width }
                }
            }
            .gesture(drag)
            .onChange(of: openRow) { _, open in
                if open != id, offset != 0 { close() }
            }
    }

    // MARK: - Revealed actions

    /// Sizes each visible action to the current reveal distance.
    @ViewBuilder
    private var actionLayer: some View {
        HStack(spacing: 0) {
            if offset > 0, let leading {
                let reveal = max(0, offset)
                button(for: leading)
                    .frame(width: reveal)
                    // Clip the full-width label so it slides in without showing when closed.
                    .clipped()
                    // Extend the tint beneath the card's rounded corners.
                    .background(alignment: .leading) {
                        actionUnderlay(leading.tint, reveal: reveal)
                    }
            }
            Spacer(minLength: 0)
            if offset < 0, let trailing {
                let reveal = max(0, -offset)
                button(for: trailing)
                    .frame(width: reveal)
                    .clipped()
                    .background(alignment: .trailing) {
                        actionUnderlay(trailing.tint, reveal: reveal)
                    }
            }
        }
    }

    /// Extends the action tint beneath the moving card's rounded edge.
    private func actionUnderlay(_ tint: Color, reveal: CGFloat) -> some View {
        tint
            .frame(width: reveal > 0 ? reveal + cornerRadius : 0)
            .allowsHitTesting(false)
    }

    private func button(for action: BideSwipeAction) -> some View {
        Button {
            fire(action)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                Text(action.title)
                    .font(BideFont.caption)
            }
            .foregroundStyle(BideColor.inverseText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(action.tint)
            // Keep the label at full width and clip it to the revealed area.
            .frame(width: Self.revealWidth)
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .clipped()
    }

    // MARK: - Gesture

    private var drag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if claimedAt == nil {
                    // Commit to horizontal movement for the rest of this gesture.
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    claimedAt = value.translation.width
                    settled = offset
                    openRow = id
                }
                guard let claimedAt else { return }
                offset = clamped(settled + value.translation.width - claimedAt)
            }
            .onEnded { value in
                guard let claimedAt else { return }
                self.claimedAt = nil

                let travelled = settled + value.translation.width - claimedAt
                let action = travelled > 0 ? leading : trailing

                guard let action else { return close() }

                if action.allowsFullSwipe, abs(travelled) > width * Self.fullSwipeFraction {
                    return fire(action)
                }

                // Include projected momentum so a short flick can open the row.
                let projected = travelled + (value.predictedEndTranslation.width - value.translation.width) * 0.4
                guard abs(projected) > Self.openThreshold else { return close() }

                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    offset = travelled > 0 ? Self.revealWidth : -Self.revealWidth
                }
            }
    }

    /// Applies resistance beyond the available action width.
    private func clamped(_ proposed: CGFloat) -> CGFloat {
        if proposed > 0 {
            guard leading != nil else { return 0 }
            return proposed <= Self.revealWidth ? proposed : Self.revealWidth + (proposed - Self.revealWidth) * 0.62
        }
        if proposed < 0 {
            guard trailing != nil else { return 0 }
            return proposed >= -Self.revealWidth ? proposed : -Self.revealWidth + (proposed + Self.revealWidth) * 0.62
        }
        return 0
    }

    private func fire(_ action: BideSwipeAction) {
        close()
        action.perform()
    }

    private func close() {
        if openRow == id { openRow = nil }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            offset = 0
        }
    }
}

#Preview("Swipe") {
    @Previewable @State var openRow: AnyHashable?

    return VStack(spacing: 12) {
        ForEach(["Nats Park", "Union Market"], id: \.self) { place in
            BideSwipeActions(
                id: place,
                openRow: $openRow,
                leading: BideSwipeAction(title: "Delete", systemImage: "trash.fill", tint: BideColor.delay(.late)) {},
                trailing: BideSwipeAction(title: "Edit", systemImage: "slider.horizontal.3", tint: BideColor.control) {}
            ) {
                Text(place)
                    .font(BideFont.cardTitle)
                    .foregroundStyle(BideColor.primaryText)
                    .frame(maxWidth: .infinity, minHeight: 88)
                    .bideCard()
            }
        }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .bideBackground()
}
