import Foundation
import SwiftUI
import BideKit
import BideUI

@main
struct BideApp: App {

    @State private var auth: AuthController
    @State private var store: BideStore

    init() {
        let backend = BideBackend.shared
        _auth = State(initialValue: AuthController(auth: backend.auth, api: backend.api))
        _store = State(
            initialValue: BideStore(
                api: backend.api,
                // Only the container app is entitled to track location in the background.
                eta: MapKitETAEngine(locations: LocationService(background: true))
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(auth: auth, store: store)
        }
    }
}

/// Chooses the authenticated root screen and handles incoming invitation links.
struct RootView: View {

    let auth: AuthController
    let store: BideStore

    /// Link deferred until authentication completes.
    @State private var pendingURL: URL?

    var body: some View {
        Group {
            if auth.hasOnboarded, let session = auth.session {
                HomeView(store: store, auth: auth)
                    .task(id: session.userID) {
                        store.start(userID: session.userID)
                        if let url = pendingURL {
                            pendingURL = nil
                            await store.handle(url: url)
                        }
                    }
            } else {
                SignInView(auth: auth)
            }
        }
        .task {
            // Temporary debug reset must run before session restoration.
            // Remove with `DevBuildReset`; see design/dev-build-reset.md.
            #if DEBUG
            await DevBuildReset.runIfNeeded(auth: auth)
            #endif

            await auth.restore()
        }
        .onOpenURL { url in
            receive(url)
        }
        // Universal Links may arrive as browsing-web user activities.
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            guard let url = activity.webpageURL else { return }
            receive(url)
        }
    }

    private func receive(_ url: URL) {
        // Defer links until the container app has an authenticated identity.
        guard auth.session != nil else {
            pendingURL = url
            return
        }
        Task { await store.handle(url: url) }
    }
}
