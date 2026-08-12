import Foundation
import BideKit

/// Where the app's Supabase project lives, and the objects built from it.
///
/// The publishable key is not a secret and is meant to ship inside the app:
/// the `anon` role has every privilege revoked on every Bide table (see
/// `backend/supabase/migrations/…_enable_row_level_security.sql`), so this key
/// on its own opens nothing. Every request is authorised by the user's own JWT
/// on top of it.
///
/// The database password is a different matter entirely and appears nowhere in
/// this repository.
struct BideBackend {

    static let projectURL = "https://uglncucsqhqtvzkconpq.supabase.co"
    static let publishableKey = "sb_publishable_WZZX2ZYV5iy0PCM0aY0cvA_M05uccNX"

    let auth: BideAuthProvider
    let api: any BideAPI

    /// One backend for the whole app, so a cached token is shared rather than
    /// every call signing in again.
    static let shared = BideBackend()

    private init() {
        guard let configuration = SupabaseConfiguration(projectURL: Self.projectURL, anonKey: Self.publishableKey) else {
            // A malformed constant above is a build-time mistake, not a runtime
            // condition, and every screen in the app needs a backend to talk to.
            preconditionFailure("BideBackend.projectURL is not a valid URL: \(Self.projectURL)")
        }

        let auth = BideAuthProvider(configuration: configuration)
        self.auth = auth
        self.api = SupabaseAPIClient(configuration: configuration, sessionProvider: auth)
    }
}
