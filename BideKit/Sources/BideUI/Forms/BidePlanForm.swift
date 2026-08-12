import SwiftUI
import BideKit

/// The form that starts a bide.
///
/// One component, two homes: the Messages compose sheet
/// (`ios-message-thread-send`) and "Create Solo-Bide" on the main page
/// (`bide-main-page`). They ask for the same things and differ only in wording
/// and chip emphasis, which is what ``Style`` covers.
public struct BidePlanForm: View {

    public struct Style: Sendable {
        /// "Where are we going?" / "Where are you going?"
        public var prompt: String
        public var actionTitle: String
        /// Solo bides have nobody to arrive alongside, so the choice is hidden.
        public var showsArrivalStyle: Bool
        public var chipEmphasis: BideChipEmphasis

        public init(
            prompt: String,
            actionTitle: String,
            showsArrivalStyle: Bool,
            chipEmphasis: BideChipEmphasis
        ) {
            self.prompt = prompt
            self.actionTitle = actionTitle
            self.showsArrivalStyle = showsArrivalStyle
            self.chipEmphasis = chipEmphasis
        }

        /// The Messages compose sheet.
        public static let send = Style(
            prompt: "Where are we going?",
            actionTitle: "Send",
            showsArrivalStyle: true,
            chipEmphasis: .solid
        )

        /// The app's solo-bide card.
        public static let solo = Style(
            prompt: "Where are you going?",
            actionTitle: "Save",
            showsArrivalStyle: false,
            chipEmphasis: .subtle
        )
    }

    @Binding private var draft: BidePlanDraft
    private let style: Style
    private let search: PlaceSearchService
    private let isBusy: Bool
    private let action: () -> Void

    @State private var editingDate = false
    @State private var editingTime = false
    @State private var unavailableMode: TravelMode?

    public init(
        draft: Binding<BidePlanDraft>,
        style: Style,
        search: PlaceSearchService,
        isBusy: Bool = false,
        action: @escaping () -> Void
    ) {
        self._draft = draft
        self.style = style
        self.search = search
        self.isBusy = isBusy
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(style.prompt)
                .font(BideFont.prompt)
                .foregroundStyle(BideColor.primaryText)

            PlaceSearchField(service: search, destination: $draft.destination)

            TravelModeRow(selection: $draft.mode) { mode in
                unavailableMode = mode
            }

            if let unavailableMode {
                Text("\(unavailableMode.title) is coming later.")
                    .font(BideFont.caption)
                    .foregroundStyle(BideColor.secondaryText)
                    .transition(.opacity)
            }

            schedule

            if style.showsArrivalStyle {
                arrivalStyle
            }

            Button(action: action) {
                if isBusy {
                    ProgressView().tint(BideColor.inverseText)
                } else {
                    Text(style.actionTitle)
                }
            }
            .buttonStyle(.bidePrimary)
            .disabled(!draft.isComplete || isBusy)
            .opacity(draft.isComplete ? 1 : 0.4)
        }
        .animation(.easeOut(duration: 0.2), value: unavailableMode)
    }

    // MARK: - Date and time

    private var schedule: some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 6) {
                BideFieldLabel("Date")
                BideChip(emphasis: style.chipEmphasis) {
                    editingDate = true
                } label: {
                    Text(draft.scheduledFor.map { BideFormat.day($0) } ?? "ASAP")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                BideFieldLabel("Time")
                BideChip(emphasis: style.chipEmphasis) {
                    editingTime = true
                } label: {
                    Text(draft.scheduledFor.map { BideFormat.time($0) } ?? "ASAP")
                }
            }

            Spacer(minLength: 0)
        }
        .sheet(isPresented: $editingDate) {
            SchedulePicker(scheduledFor: $draft.scheduledFor, components: .date, title: "Date")
        }
        .sheet(isPresented: $editingTime) {
            SchedulePicker(scheduledFor: $draft.scheduledFor, components: .hourAndMinute, title: "Time")
        }
    }

    // MARK: - Arrival style

    private var arrivalStyle: some View {
        VStack(alignment: .leading, spacing: 6) {
            BideFieldLabel("Arrival Style")

            HStack(spacing: 10) {
                ForEach(ArrivalStyle.allCases) { option in
                    Button {
                        draft.arrivalStyle = option
                    } label: {
                        Text(option.title)
                            .font(BideFont.cardTitle)
                            .foregroundStyle(
                                draft.arrivalStyle == option ? BideColor.inverseText : BideColor.primaryText
                            )
                            .padding(.horizontal, 14)
                            .frame(height: 40)
                            .background(
                                draft.arrivalStyle == option ? BideColor.primaryText : BideColor.control,
                                in: RoundedRectangle(cornerRadius: BideMetrics.controlRadius, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(draft.arrivalStyle.explanation)
                .font(BideFont.caption)
                .foregroundStyle(BideColor.secondaryText)
        }
        .animation(.easeOut(duration: 0.16), value: draft.arrivalStyle)
    }
}

/// The native date or time picker, in a sheet, with the way out to "as soon as
/// everyone can" that the design calls for.
private struct SchedulePicker: View {

    @Binding var scheduledFor: Date?
    let components: DatePickerComponents
    let title: String

    @Environment(\.dismiss) private var dismiss

    private var selection: Binding<Date> {
        Binding(
            get: { scheduledFor ?? BidePlanDraft.defaultTime() },
            set: { scheduledFor = $0 }
        )
    }

    /// The two styles are different types, so this can't be a ternary.
    @ViewBuilder
    private var picker: some View {
        if components == .date {
            DatePicker(title, selection: selection, in: Date()..., displayedComponents: .date)
                .datePickerStyle(.graphical)
        } else {
            DatePicker(title, selection: selection, in: Date()..., displayedComponents: .hourAndMinute)
                #if os(iOS)
                .datePickerStyle(.wheel)
                #endif
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                picker
                    .labelsHidden()
                    .tint(BideColor.primaryText)

                Button("As soon as everyone can") {
                    scheduledFor = nil
                    dismiss()
                }
                .font(BideFont.body)
                .foregroundStyle(BideColor.secondaryText)

                Spacer(minLength: 0)
            }
            .padding(BideMetrics.gutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .bideBackground()
            .navigationTitle(title)
            .bideInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        // Opening the picker at all means a time was wanted.
                        if scheduledFor == nil { scheduledFor = BidePlanDraft.defaultTime() }
                        dismiss()
                    }
                    .tint(BideColor.primaryText)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(BideColor.background)
        .preferredColorScheme(.dark)
    }
}

#Preview {
    @Previewable @State var draft = BidePlanDraft(scheduledFor: BidePlanDraft.defaultTime())

    return BidePlanForm(draft: $draft, style: .send, search: PlaceSearchService()) {}
        .padding(BideMetrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .bideBackground()
        .preferredColorScheme(.dark)
}
