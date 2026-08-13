#if DEBUG
import ActivityKit
import Foundation
import BideKit

/// **Temporary. This whole file is meant to be deleted.** See
/// `design/dev-build-reset.md` for what it does and how to take it out.
///
/// Clean slate on every new build: deletes this device's account from the
/// server, signs out, and drops everything held locally, so each trip through
/// Xcode starts at the sign-in screen with nothing behind it.
///
/// It goes that far because nothing less actually works. A bide is not local
/// state, and neither is the identity that owns it:
///
/// - The anonymous identity is a **keychain** item, and iOS does not clear
///   keychain items when an app is uninstalled. Delete the app, reinstall, and
///   the same `auth.uid()` comes back.
/// - Signing out is not enough either, and this is the part that catches
///   people: Sign in with Apple maps the same Apple ID to the *same* Supabase
///   user, so signing out and back in returns the same account and the same
///   bides. Only deleting the account produces a genuinely new one.
///
/// Debug-only by construction: the `#if DEBUG` wraps the file rather than the
/// body, so there is nothing to strip out of a release build and no way to call
/// this from one by accident.
@MainActor
enum DevBuildReset {

    /// Set to `false` to keep the account across builds — necessary when the
    /// thing under test *is* persistence, and when two devices are sharing a
    /// bide, since deleting the creator's account deletes that bide for both.
    static let isEnabled = true

    private static let fingerprintKey = "bide.dev.buildFingerprint"
    private static let answerKeyPrefix = "bide.answer."

    /// Runs once per build, before anything reads a session. Every launch after
    /// the first is a no-op, because the fingerprint already matches.
    static func runIfNeeded(
        auth: AuthController,
        api: any BideAPI = BideBackend.shared.api,
        defaults: UserDefaults = .standard
    ) async {
        guard isEnabled, let fingerprint = buildFingerprint() else { return }
        guard defaults.string(forKey: fingerprintKey) != fingerprint else { return }

        // Nothing to delete on a device that has never had an identity — and
        // asking for one here would *mint* an anonymous user purely so the next
        // line could throw it away.
        guard KeychainTokenStore().loadRefreshToken() != nil else {
            defaults.set(fingerprint, forKey: fingerprintKey)
            return
        }

        do {
            try await api.deleteMe()
        } catch {
            // The fingerprint stays unrecorded, so the next launch tries again.
            // Being offline shouldn't mean this build silently keeps yesterday's
            // account — that is the exact confusion the whole file exists to
            // prevent.
            print("[DevBuildReset] could not delete the account, retrying next launch: \(error)")
            return
        }

        await clearEverythingLocal(auth: auth)

        defaults.set(fingerprint, forKey: fingerprintKey)
        print("[DevBuildReset] clean slate for build \(fingerprint) — sign in again")
    }

    // MARK: - Local state

    private static func clearEverythingLocal(auth: AuthController) async {
        // A Live Activity outlives the process that started it, so anything
        // left over from the previous build is an orphan: the new
        // `LiveActivityController` has an empty table and cannot end what it
        // never started. ActivityKit is the only thing that still knows.
        for activity in Activity<BideActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        // Drops the keychain token and resets `hasOnboarded`, which is what
        // sends the app back to the sign-in screen.
        await auth.signOut()

        PendingInviteStore().removeAll()
        clearLocalAnswers()

        // The display name deliberately survives. Apple hands a name over
        // exactly once — on the very first authorisation, ever — so clearing it
        // would leave every later build with no name at all, and tiles reading
        // "Someone wants to go to…". That looks precisely like the class of bug
        // this file exists to rule out, so it would be a bad thing to introduce
        // in the name of a clean slate. `BideProfileStore.displayName` is one
        // line away if you want it gone.
    }

    /// `LocalBideStore` writes a key per bide under a shared prefix and has no
    /// "forget everything" of its own — deliberately, since the product never
    /// needs one. Sweeping the prefix here rather than adding that API keeps the
    /// decision intact and this file deletable.
    private static func clearLocalAnswers() {
        for defaults in [UserDefaults.standard, .bideShared] {
            let keys = defaults.dictionaryRepresentation().keys
            for key in keys where key.hasPrefix(answerKeyPrefix) {
                defaults.removeObject(forKey: key)
            }
        }
    }

    // MARK: - Telling one build from the next

    /// What makes this build different from the last one installed.
    ///
    /// `CFBundleVersion` is no use on its own — nothing bumps it, so every build
    /// of this app is "1". The part that actually moves is the executable's
    /// modification date, which changes every time Xcode compiles and installs.
    /// Version and build ride along so the log line is readable.
    ///
    /// Nil if the date can't be read, which is treated as "do nothing": that is
    /// the safe answer when the check itself is broken, and this is not an
    /// operation to perform on a guess.
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
