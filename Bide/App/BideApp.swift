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
                // Background location, unlike the Messages extension: an ETA
                // that freezes when the phone goes in a pocket is worse than
                // no ETA at all.
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

/// Decides between the sign-in screen and the app, and routes the `bide://`
/// hand-off from the Messages extension.
struct RootView: View {

    let auth: AuthController
    let store: BideStore

    /// A tile that arrived before there was an identity to act on it with.
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
        .task { await auth.restore() }
        .onOpenURL { url in
            // Accepting a tile means "start counting down my ETA", which needs
            // location, MKDirections, and this app's identity — none of which
            // the extension has.
            guard auth.session != nil else {
                pendingURL = url
                return
            }
            Task { await store.handle(url: url) }
        }
    }
}
