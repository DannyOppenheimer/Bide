import SwiftUI
import BideKit
import BideUI

/// The app's only screen — `bide-main-page`. Active sessions at the top,
/// mirroring what the Live Activity shows, and the solo-bide composer beneath.
struct HomeView: View {

    let store: BideStore
    let auth: AuthController

    @State private var draft = BidePlanDraft()
    @State private var search = PlaceSearchService()
    @State private var showingSettings = false
    @State private var isSaving = false

    /// Drives the countdowns without every card owning a timer.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BideMetrics.sectionSpacing) {
                header

                if !store.bides.isEmpty {
                    section("Active Bide Sessions") {
                        ForEach(store.bides) { state in
                            BideSessionCard(
                                headline: store.headline(for: state, now: now),
                                destination: state.destinationName,
                                participants: state.participants.filter { $0.status != .declined },
                                me: store.userID,
                                isLive: state.bideID == store.trackedBideID,
                                now: now
                            )
                            .contextMenu {
                                // A solo bide is worth sharing: the design's
                                // "invite others to track it". The link is the
                                // same tile URL a Messages tile carries.
                                ShareLink(item: state.invite.webURL()) {
                                    Label("Invite others to track", systemImage: "square.and.arrow.up")
                                }
                                Button("Leave this Bide", role: .destructive) {
                                    Task { await store.leave(state.bideID) }
                                }
                            }
                        }
                    }
                } else if store.isLoading {
                    ProgressView()
                        .tint(BideColor.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                } else {
                    emptyState
                }

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
        }
        .scrollDismissesKeyboard(.interactively)
        .frame(maxWidth: .infinity)
        .bideBackground()
        .preferredColorScheme(.dark)
        .refreshable { await store.refresh() }
        .onReceive(tick) { now = $0 }
        .sheet(isPresented: $showingSettings) {
            SettingsView(store: store, auth: auth)
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
            // The way back for somebody who chose "use without signing in" and
            // has changed their mind — without it, that choice is permanent
            // short of deleting the app. Signed-in users have no landing page
            // to go back to, so they don't get one.
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

            // The design puts settings behind sign-in: an anonymous identity
            // has no name to change and no calendar to connect it to.
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
