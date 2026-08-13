import Foundation
import BideKit

/// Supabase configuration and shared service instances.
/// The publishable key is protected by row-level security; database credentials
/// must never be added to the app or repository.
struct BideBackend {

    static let projectURL = "https://uglncucsqhqtvzkconpq.supabase.co"
    static let publishableKey = "sb_publishable_WZZX2ZYV5iy0PCM0aY0cvA_M05uccNX"

    let auth: BideAuthProvider
    let api: any BideAPI

    /// Shared backend that reuses one authenticated session cache.
    static let shared = BideBackend()

    private init() {
        guard let configuration = SupabaseConfiguration(projectURL: Self.projectURL, anonKey: Self.publishableKey) else {
            // A malformed compile-time endpoint prevents the app from functioning.
            preconditionFailure("BideBackend.projectURL is not a valid URL: \(Self.projectURL)")
        }

        let auth = BideAuthProvider(configuration: configuration)
        self.auth = auth
        self.api = SupabaseAPIClient(configuration: configuration, sessionProvider: auth)
    }
}
