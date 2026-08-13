import SwiftUI
import BideKit

/// Shared form for composing invitations, creating solo bides, and editing plans.
public struct BidePlanForm: View {

    public struct Style: Sendable {
        /// Destination prompt.
        public var prompt: String
        public var actionTitle: String
        /// Label for the target arrival field.
        public var timeLabel: String
        /// Whether to show group arrival coordination choices.
        public var showsArrivalStyle: Bool
        public var chipEmphasis: BideChipEmphasis

        public init(
            prompt: String,
            actionTitle: String,
            timeLabel: String,
            showsArrivalStyle: Bool,
            chipEmphasis: BideChipEmphasis
        ) {
            self.prompt = prompt
            self.actionTitle = actionTitle
            self.timeLabel = timeLabel
            self.showsArrivalStyle = showsArrivalStyle
            self.chipEmphasis = chipEmphasis
        }

        /// Style for the Messages compose sheet.
        public static let send = Style(
            prompt: "Where are we going?",
            actionTitle: "Send",
            timeLabel: "Meetup time",
            showsArrivalStyle: true,
            chipEmphasis: .subtle
        )

        /// Style for creating a solo bide in the app.
        public static let solo = Style(
            prompt: "Where are you going?",
            actionTitle: "Save",
            timeLabel: "Arrival time",
            showsArrivalStyle: false,
            chipEmphasis: .subtle
        )

        /// Style for editing an existing plan. Arrival style is immutable here.
        public static func editing(isSolo: Bool) -> Style {
            Style(
                prompt: isSolo ? "Where are you going?" : "Where are we going?",
                actionTitle: "Save",
                timeLabel: isSolo ? "Arrival time" : "Meetup time",
                showsArrivalStyle: false,
                chipEmphasis: .subtle
            )
        }
    }

    @Binding private var draft: BidePlanDraft
    private let style: Style
    private let search: PlaceSearchService
    private let isBusy: Bool
    private let action: () -> Void
    /// Optional cancel action used by inline editors.
    private let cancel: (() -> Void)?

    @State private var editingDate = false
    @State private var editingTime = false
    @State private var unavailableMode: TravelMode?

    public init(
        draft: Binding<BidePlanDraft>,
        style: Style,
        search: PlaceSearchService,
        isBusy: Bool = false,
        cancel: (() -> Void)? = nil,
        action: @escaping () -> Void
    ) {
        self._draft = draft
        self.style = style
        self.search = search
        self.isBusy = isBusy
        self.cancel = cancel
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

            HStack(spacing: 12) {
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

                if let cancel {
                    Button("Cancel", action: cancel)
                        .buttonStyle(.bideSecondary)
                        .disabled(isBusy)
                }
            }
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
                    // Present an unscheduled plan as its user-facing "Today" value.
                    Text(draft.scheduledFor.map { BideFormat.day($0) } ?? "Today")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                // Clarify that this is an arrival time, not a departure time.
                BideFieldLabel(style.timeLabel)
                BideChip(emphasis: style.chipEmphasis) {
                    editingTime = true
                } label: {
                    Text(draft.scheduledFor.map { BideFormat.time($0) } ?? "Now")
                }
            }

            Spacer(minLength: 0)
        }
        .sheet(isPresented: $editingDate) {
            SchedulePicker(scheduledFor: $draft.scheduledFor, components: .date, title: "Date")
        }
        .sheet(isPresented: $editingTime) {
            SchedulePicker(
                scheduledFor: $draft.scheduledFor,
                components: .hourAndMinute,
                title: style.timeLabel
            )
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

/// Sheet containing a native date or time picker and an ASAP option.
private struct SchedulePicker: View {

    @Binding var scheduledFor: Date?
    let components: DatePickerComponents
    let title: String

    @Environment(\.dismiss) private var dismiss

    /// Fixed reference time captured when the picker opens.
    @State private var openedAt = Date()

    private var selection: Binding<Date> {
        Binding(
            get: { scheduledFor ?? openedAt },
            set: { scheduledFor = $0 }
        )
    }

    /// Whether the selection still represents an immediate departure.
    private var isEffectivelyNow: Bool {
        guard let scheduledFor else { return true }
        return Calendar.current.isDate(scheduledFor, equalTo: openedAt, toGranularity: .minute)
    }

    /// Chooses the platform picker style for the selected components.
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

                // Show the ASAP option only while the selection remains the current minute.
                if isEffectivelyNow {
                    Button("Leave now — as soon as everyone can") {
                        scheduledFor = nil
                        dismiss()
                    }
                    .font(BideFont.body)
                    .foregroundStyle(BideColor.secondaryText)
                }

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
                        // Persist the initially displayed time if the wheel was untouched.
                        if scheduledFor == nil { scheduledFor = openedAt }
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
    @Previewable @State var draft = BidePlanDraft()

    return BidePlanForm(draft: $draft, style: .send, search: PlaceSearchService()) {}
        .padding(BideMetrics.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .bideBackground()
        .preferredColorScheme(.dark)
}
