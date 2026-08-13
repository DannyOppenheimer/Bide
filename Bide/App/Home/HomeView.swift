import SwiftUI
import BideKit
import BideUI

/// Main screen containing active sessions and the solo-bide composer.
struct HomeView: View {

    let store: BideStore
    let auth: AuthController

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var draft = BidePlanDraft()
    @State private var search = PlaceSearchService()
    @State private var showingSettings = false
    @State private var isSaving = false

    /// Identifier of the single session currently being edited.
    @State private var editing: UUID?
    @State private var editDraft = BidePlanDraft()
    /// Dedicated search state that does not interfere with the create form.
    @State private var editSearch = PlaceSearchService()
    @State private var isEditSaving = false
    /// Identifier of the card with visible swipe actions.
    @State private var openSwipeRow: AnyHashable?
    /// Bide currently presented in the share sheet.
    @State private var sharing: BideState?

    /// Shared clock for all visible countdowns.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BideMetrics.sectionSpacing) {
                header

                activeSessions

                section("Create Solo-Bide") {
                    BidePlanForm(draft: $draft, style: .solo, search: search, isBusy: isSaving) {
                        save()
                    }
                    .bideCard()
                }

                if let errorMessage = store.errorMessage {
                    Text(errorMessage)
                        .font(BideFont.caption)
                        .foregroundStyle(BideColor.delay(.late))
                }
            }
            .padding(BideMetrics.gutter)
            // Animate the session section without moving the create form in the same transition.
            .animation(sessionAnimation, value: store.sessions.map(\.bideID))
        }
        .scrollDismissesKeyboard(.interactively)
        .frame(maxWidth: .infinity)
        .bideBackground()
        .preferredColorScheme(.dark)
        // Foreground activation refreshes data that polling could not fetch in the background.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await store.refresh() }
        }
        .onReceive(tick) { now = $0 }
        .sheet(isPresented: $showingSettings) {
            SettingsView(store: store, auth: auth)
        }
        // The card's existing share button presents the system share sheet directly.
        .sheet(item: $sharing) { state in
            ShareSheet(items: [store.trackingLink(for: state)])
                .presentationDetents([.medium, .large])
        }
        .alert("Are you sure?", isPresented: showingConflict, presenting: store.conflict) { prompt in
            Button("Cancel", role: .cancel) { store.conflict = nil }
            Button("Continue", role: .destructive) {
                let proceed = prompt.proceed
                store.conflict = nil
                Task { await proceed() }
            }
        } message: { prompt in
            Text(prompt.message)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            // Anonymous users can return to sign-in without deleting their identity.
            if !auth.isSignedInWithApple {
                Button {
                    store.stop()
                    auth.returnToSignIn()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(BideColor.primaryText)
                }
                .accessibilityLabel("Back to sign in")
            }

            Text("Bide")
                .font(BideFont.screenTitle)
                .foregroundStyle(BideColor.primaryText)

            Spacer()

            // Account settings require a durable Apple identity.
            if auth.isSignedInWithApple {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(BideColor.primaryText)
                }
                .accessibilityLabel("Settings")
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No active bides")
                .font(BideFont.cardTitle)
                .foregroundStyle(BideColor.primaryText)
            Text("Send a tile from a Messages thread, or create a solo-bide below.")
                .font(BideFont.body)
                .foregroundStyle(BideColor.secondaryText)
        }
        .bideCard()
    }

    /// Remains mounted when empty so the final row can run its exit transition.
    private var activeSessions: some View {
        VStack(alignment: .leading, spacing: BideMetrics.stackSpacing) {
            if !store.sessions.isEmpty {
                Text("Active Bide Sessions")
                    .font(BideFont.sectionTitle)
                    .foregroundStyle(BideColor.primaryText)
                    .transition(.opacity)
            }

            ForEach(store.sessions) { state in
                Group {
                    if editing == state.bideID {
                        editor(for: state)
                    } else {
                        sessionCard(for: state)
                    }
                }
                .transition(sessionTransition)
            }

            if store.sessions.isEmpty {
                emptyState
            }
        }
    }

    private var sessionTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity,
                // Scale the finished card surface without changing its colors or corners.
                removal: .scale(scale: 0.001, anchor: .center)
            )
    }

    private var sessionAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .smooth(duration: 0.52)
    }

    // MARK: - Sessions

    /// Builds a session card with swipe shortcuts duplicated in its context menu.
    private func sessionCard(for state: BideState) -> some View {
        BideSwipeActions(
            id: state.bideID,
            openRow: $openSwipeRow,
            leading: BideSwipeAction(
                title: store.isWatching(state) ? "Stop" : "Delete",
                systemImage: store.isWatching(state) ? "eye.slash.fill" : "trash.fill",
                tint: BideColor.delay(.late)
            ) {
                Task { await store.leave(state.bideID) }
            },
            trailing: store.canEdit(state)
                ? BideSwipeAction(
                    title: "Edit",
                    systemImage: "slider.horizontal.3",
                    tint: BideColor.controlSelected
                ) {
                    beginEditing(state)
                }
                : nil
        ) {
            BideSessionCard(
                headline: store.headline(for: state, now: now),
                destination: state.destinationName,
                companionNote: store.companionNote(for: state),
                participants: state.roster,
                me: store.userID,
                scheduledArrival: state.scheduledFor,
                isLive: store.trackedBideIDs.contains(state.bideID),
                isWatching: state.isWatching(store.userID),
                now: now,
                onShare: store.canShare(state) ? { sharing = state } : nil
            )
        }
        .contextMenu {
            if store.canShare(state) {
                ShareLink(item: store.trackingLink(for: state)) {
                    Label("Let someone track this", systemImage: "square.and.arrow.up")
                }
            }
            if store.canEdit(state) {
                Button {
                    beginEditing(state)
                } label: {
                    Label("Edit this Bide", systemImage: "slider.horizontal.3")
                }
            }
            Button(store.leaveTitle(for: state), role: .destructive) {
                Task { await store.leave(state.bideID) }
            }
        }
    }

    /// Replaces a session card with its inline edit form.
    private func editor(for state: BideState) -> some View {
        VStack(alignment: .leading, spacing: BideMetrics.stackSpacing) {
            Text(state.isSolo ? "Edit this Bide" : "Edit this Bide for everyone")
                .font(BideFont.sectionTitle)
                .foregroundStyle(BideColor.primaryText)

            BidePlanForm(
                draft: $editDraft,
                style: .editing(isSolo: state.isSolo),
                search: editSearch,
                isBusy: isEditSaving,
                cancel: { endEditing() }
            ) {
                saveEdit(to: state.bideID)
            }

            if !state.isSolo {
                Text("Everyone in this Bide sees the new place and time. Your travel mode is only yours.")
                    .font(BideFont.caption)
                    .foregroundStyle(BideColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .bideCard()
        .transition(.opacity)
    }

    private func beginEditing(_ state: BideState) {
        editSearch.clear()
        editDraft = BidePlanDraft(
            destination: state.destination,
            // Only the local participant's travel mode is editable.
            mode: store.userID.flatMap { state.participant($0)?.mode } ?? .walking,
            scheduledFor: state.scheduledFor,
            arrivalStyle: state.arrivalStyle
        )
        withAnimation(.easeOut(duration: 0.2)) { editing = state.bideID }
    }

    private func endEditing() {
        editSearch.clear()
        withAnimation(.easeOut(duration: 0.2)) { editing = nil }
    }

    private func saveEdit(to bideID: UUID) {
        guard let destination = editDraft.destination else { return }
        isEditSaving = true
        Task {
            await store.edit(
                bideID,
                destination: destination,
                scheduledFor: editDraft.scheduledFor,
                mode: editDraft.mode
            )
            isEditSaving = false
            // Preserve the form and entered values when saving fails.
            if store.errorMessage == nil { endEditing() }
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: BideMetrics.stackSpacing) {
            Text(title)
                .font(BideFont.sectionTitle)
                .foregroundStyle(BideColor.primaryText)
            content()
        }
    }

    private var showingConflict: Binding<Bool> {
        Binding(
            get: { store.conflict != nil },
            set: { if !$0 { store.conflict = nil } }
        )
    }

    private func save() {
        isSaving = true
        Task {
            await store.create(draft, isSolo: true)
            isSaving = false
            if store.errorMessage == nil {
                draft = BidePlanDraft()
                search.clear()
            }
        }
    }
}

/// UIKit wrapper used to present sharing from an existing card button.
private struct ShareSheet: UIViewControllerRepresentable {

    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
