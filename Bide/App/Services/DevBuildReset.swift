#if DEBUG
import ActivityKit
import Foundation
import BideKit

/// Temporary debug-only reset that deletes server and local state once per build.
/// Remove this file and its call site as described in `design/dev-build-reset.md`.
/// Account deletion is required because keychain and Apple identities survive reinstall.
@MainActor
enum DevBuildReset {

    /// Disable while testing persistence or a bide shared across devices.
    static let isEnabled = true

    private static let fingerprintKey = "bide.dev.buildFingerprint"
    private static let answerKeyPrefix = "bide.answer."

    /// Runs before session restoration and skips subsequent launches of the same build.
    static func runIfNeeded(
        auth: AuthController,
        api: any BideAPI = BideBackend.shared.api,
        defaults: UserDefaults = .standard
    ) async {
        guard isEnabled, let fingerprint = buildFingerprint() else { return }
        guard defaults.string(forKey: fingerprintKey) != fingerprint else { return }

        // Do not create an anonymous identity solely to delete it.
        guard KeychainTokenStore().loadRefreshToken() != nil else {
            defaults.set(fingerprint, forKey: fingerprintKey)
            return
        }

        do {
            try await api.deleteMe()
        } catch {
            // Leave the fingerprint unset so the next launch retries.
            print("[DevBuildReset] could not delete the account, retrying next launch: \(error)")
            return
        }

        await clearEverythingLocal(auth: auth)

        defaults.set(fingerprint, forKey: fingerprintKey)
        print("[DevBuildReset] clean slate for build \(fingerprint) — sign in again")
    }

    // MARK: - Local state

    private static func clearEverythingLocal(auth: AuthController) async {
        // ActivityKit retains activities across process and build lifetimes.
        for activity in Activity<BideActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        // Clear the keychain identity and return to onboarding.
        await auth.signOut()

        PendingInviteStore().removeAll()
        SentInviteStore().removeAll()
        clearLocalAnswers()

        // Preserve the display name because Apple supplies it only on first authorization.
    }

    /// Removes the per-bide keys used only by this temporary reset.
    private static func clearLocalAnswers() {
        for defaults in [UserDefaults.standard, .bideShared] {
            let keys = defaults.dictionaryRepresentation().keys
            for key in keys where key.hasPrefix(answerKeyPrefix) {
                defaults.removeObject(forKey: key)
            }
        }
    }

    // MARK: - Build identification

    /// Identifies a build by executable modification time plus version metadata.
    /// Returns `nil` rather than risking a reset when the timestamp is unavailable.
    private static func buildFingerprint() -> String? {
        guard
            let executable = Bundle.main.executableURL,
            let modified = try? executable
                .resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
        else { return nil }

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version)(\(build))@\(Int(modified.timeIntervalSince1970))"
    }
}
#endif
