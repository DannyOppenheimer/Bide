import SwiftUI
import BideKit

/// The row of travel modes from the reference screens.
///
/// Every mode in ``TravelMode/displayOrder`` is drawn, but only the selectable
/// ones respond. Cycling, flights and trains are shown dimmed rather than
/// hidden: the row is part of the brand, and a gap where an icon used to be
/// reads as a bug where a dimmed icon reads as "not yet".
public struct TravelModeRow: View {

    @Binding private var selection: TravelMode
    private let size: CGFloat
    private let onUnavailable: ((TravelMode) -> Void)?

    public init(
        selection: Binding<TravelMode>,
        size: CGFloat = BideMetrics.modeButtonSize,
        onUnavailable: ((TravelMode) -> Void)? = nil
    ) {
        self._selection = selection
        self.size = size
        self.onUnavailable = onUnavailable
    }

    public var body: some View {
        HStack(spacing: 10) {
            ForEach(TravelMode.displayOrder) { mode in
                button(for: mode)
            }
        }
    }

    private func button(for mode: TravelMode) -> some View {
        let isSelected = selection == mode

        return Button {
            if mode.isSelectable {
                selection = mode
            } else {
                onUnavailable?(mode)
            }
        } label: {
            Image(systemName: mode.symbolName)
                .font(.system(size: size * 0.45, weight: .medium))
                .foregroundStyle(BideColor.primaryText)
                .frame(width: size, height: size)
                .background {
                    if isSelected {
                        Circle().fill(BideColor.controlSelected)
                    }
                }
                .opacity(mode.isSelectable ? 1 : 0.32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.16), value: isSelected)
        .accessibilityLabel(mode.title)
        .accessibilityValue(mode.isSelectable ? (isSelected ? "Selected" : "") : "Not available yet")
    }
}

#Preview {
    @Previewable @State var mode: TravelMode = .walking

    return VStack(alignment: .leading, spacing: 24) {
        TravelModeRow(selection: $mode)
        Text(mode.title)
            .font(BideFont.body)
            .foregroundStyle(BideColor.secondaryText)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .bideBackground()
}
