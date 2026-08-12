import SwiftUI
import BideKit
import BideUI

/// Settings, reachable only when signed in — there's nothing here for an
/// identity that lives on one device.
struct SettingsView: View {

    let store: BideStore
    let auth: AuthController

    @Environment(\.dismiss) private var dismiss

    @State private var profile = BideProfileStore()
    @State private var displayName = ""
    @State private var autoCreateFromCalendar = UserDefaults.standard.bool(forKey: SettingsView.calendarKey)
    @State private var calendarMessage: String?
    @State private var scanner = CalendarScanner()

    static let calendarKey = "bide.calendar.autoCreate"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BideMetrics.sectionSpacing) {
                    displayNameSection
                    calendarSection
                    accountSection
                }
                .padding(BideMetrics.gutter)
            }
            .frame(maxWidth: .infinity)
            .bideBackground()
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                        .tint(BideColor.primaryText)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { displayName = profile.displayName ?? "" }
    }

    private var displayNameSection: some View {
        VStack(alignment: .leading, spacing: BideMetrics.stackSpacing) {
            Text("Display name")
                .font(BideFont.sectionTitle)
                .foregroundStyle(BideColor.primaryText)

            TextField(
                "",
                text: $displayName,
                prompt: Text("What should people call you?").foregroundColor(BideColor.secondaryText)
            )
            .font(BideFont.prompt)
            .foregroundStyle(BideColor.primaryText)
            .padding(.horizontal, 14)
            .frame(height: BideMetrics.controlHeight)
            .background(BideColor.control, in: Capsule())

            Text("Shown beside your avatar in every bide you're in.")
                .font(BideFont.caption)
                .foregroundStyle(BideColor.secondaryText)
        }
    }

    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: BideMetrics.stackSpacing) {
            Text("Calendar")
                .font(BideFont.sectionTitle)
                .foregroundStyle(BideColor.primaryText)

            Toggle(isOn: $autoCreateFromCalendar) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create solo-bides for events")
                        .font(BideFont.body)
                        .foregroundStyle(BideColor.primaryText)
                    Text("Upcoming events that have a location get their own leave-time reminder.")
                        .font(BideFont.caption)
                        .foregroundStyle(BideColor.secondaryText)
                }
            }
            .tint(BideColor.delay(.onSchedule))
            .onChange(of: autoCreateFromCalendar) { _, isOn in
                guard isOn else { return }
                Task { await enableCalendar() }
            }

            if let calendarMessage {
                Text(calendarMessage)
                    .font(BideFont.caption)
                    .foregroundStyle(BideColor.secondaryText)
            }
        }
        .bideCard()
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: BideMetrics.stackSpacing) {
            Text("Account")
                .font(BideFont.sectionTitle)
                .foregroundStyle(BideColor.primaryText)

            Button("Sign out", role: .destructive) {
                Task {
                    await auth.signOut()
                    dismiss()
                }
            }
            .font(BideFont.body)
            .foregroundStyle(BideColor.delay(.late))
        }
    }

    private func enableCalendar() async {
        guard await scanner.requestAccess() else {
            autoCreateFromCalendar = false
            calendarMessage = "Calendar access is off. Turn it on in iOS Settings to use this."
            return
        }
        calendarMessage = nil
        await createFromCalendar()
    }

    /// Converts what's already on the calendar, so turning the switch on does
    /// something visible rather than promising to later.
    private func createFromCalendar() async {
        for (eventID, draft) in await scanner.upcomingDrafts() {
            await store.create(draft, isSolo: true)
            scanner.markConverted(eventID)
        }
    }

    private func save() {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.displayName = trimmed
        UserDefaults.standard.set(autoCreateFromCalendar, forKey: Self.calendarKey)

        Task {
            await store.updateDisplayName(trimmed)
            dismiss()
        }
    }
}
