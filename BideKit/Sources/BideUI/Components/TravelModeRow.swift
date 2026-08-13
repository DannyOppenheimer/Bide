import SwiftUI
import BideKit

/// Displays travel modes in design order, dimming modes that are unavailable.
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
