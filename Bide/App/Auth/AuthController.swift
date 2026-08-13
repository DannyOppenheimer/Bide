import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import BideKit

/// Manages anonymous and Apple authentication for a shared `auth.uid()` session.
@MainActor
@Observable
final class AuthController {

    private(set) var session: BideSession? {
        didSet {
            // Share durable-sign-in state with the identity-free Messages extension.
            // A failed restore leaves the existing flag unchanged.
            guard let session else { return }
            profile.isSignedInWithApple = !session.isAnonymous
        }
    }
    private(set) var isWorking = false
    private(set) var errorMessage: String?

    /// Whether onboarding has completed, including anonymous continuation.
    private(set) var hasOnboarded: Bool {
        didSet { defaults.set(hasOnboarded, forKey: Self.onboardedKey) }
    }

    var isSignedInWithApple: Bool { session?.isAnonymous == false }

    /// Display name from account metadata, if available.
    var accountDisplayName: String? { session?.displayName }

    private static let onboardedKey = "bide.onboarded"

    private let auth: BideAuthProvider
    private let api: any BideAPI
    private let profile: BideProfileStore
    private let defaults: UserDefaults

    /// Raw nonce retained while Apple authentication is in progress.
    private var pendingNonce: String?

    init(
        auth: BideAuthProvider,
        api: any BideAPI,
        profile: BideProfileStore = BideProfileStore(),
        defaults: UserDefaults = .standard
    ) {
        self.auth = auth
        self.api = api
        self.profile = profile
        self.defaults = defaults
        self.hasOnboarded = defaults.bool(forKey: Self.onboardedKey)
    }

    /// Restores the device's existing identity without prompting.
    func restore() async {
        guard hasOnboarded, session == nil else { return }
        session = try? await auth.currentSession()
        await reconcileName()
    }

    /// Creates or restores an anonymous session for unauthenticated use.
    func continueWithoutSigningIn() async {
        await run(describe: { Self.signInFailure($0, fallback: "Couldn't start a Bide session. Try again.") }) {
            self.session = try await self.auth.currentSession()
            self.hasOnboarded = true
        }
    }

    // MARK: - Sign in with Apple

    /// Configures Apple authentication with the nonce and scopes Supabase requires.
    /// Email must be requested so the first identity token can create a Supabase user.
    func configure(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.makeNonce()
        pendingNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
    }

    func handle(_ result: Result<ASAuthorization, any Error>) async {
        switch result {
        case .failure(let error):
            // User cancellation does not need an error message.
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            errorMessage = "Couldn't sign in with Apple. Try again."

        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let idToken = String(data: tokenData, encoding: .utf8),
                let nonce = pendingNonce
            else {
                errorMessage = "Apple didn't return a usable sign-in."
                return
            }

            await run(describe: { Self.signInFailure($0, fallback: "Apple couldn't sign you in. Try again.") }) {
                self.session = try await self.auth.signInWithApple(idToken: idToken, nonce: nonce)
                self.hasOnboarded = true
                self.pendingNonce = nil

                // Persist Apple's one-time name locally, in rosters, and in account metadata.
                let offered = credential.fullName?.formatted(.name(style: .short))
                if let offered, !offered.isEmpty, self.profile.displayName == nil {
                    await self.adopt(name: offered)
                }
            }

            // Recover the stored account name when Apple no longer supplies one.
            await reconcileName()
        }
    }

    /// Reconciles local and account names without overwriting an existing local choice.
    private func reconcileName() async {
        guard let session else { return }

        guard let local = profile.displayName else {
            if let remote = session.displayName { await adopt(name: remote) }
            return
        }

        // Synchronization is best-effort and retries on a later launch.
        guard session.displayName == nil else { return }
        try? await api.updateDisplayName(local)
        await record(local)
    }

    /// Persists a user-selected name in account metadata.
    func remember(displayName: String) async {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        await record(trimmed.isEmpty ? nil : trimmed)
    }

    /// Copies a name to local profile storage, participant rows, and account metadata.
    private func adopt(name: String) async {
        profile.displayName = name
        try? await api.updateDisplayName(name)
        await record(name)
    }

    /// Writes account metadata and updates the cached session to match.
    private func record(_ name: String?) async {
        try? await auth.record(displayName: name)
        session = session.map {
            BideSession(
                userID: $0.userID,
                accessToken: $0.accessToken,
                isAnonymous: $0.isAnonymous,
                displayName: name
            )
        }
    }

    /// Deletes the local session. Anonymous identities cannot be recovered afterward.
    func signOut() async {
        await auth.signOut()
        session = nil
        hasOnboarded = false
        profile.isSignedInWithApple = false
    }

    /// Returns to onboarding without deleting the recoverable anonymous identity.
    func returnToSignIn() {
        session = nil
        hasOnboarded = false
    }

    // MARK: - Plumbing

    private func run(
        describe: @escaping (APIError) -> String = { $0.errorDescription ?? "Something went wrong signing in." },
        _ work: @escaping () async throws -> Void
    ) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            try await work()
        } catch let error as APIError {
            errorMessage = describe(error)
        } catch {
            errorMessage = "Something went wrong signing in."
        }
    }

    /// Converts authentication errors to sign-in-specific text while preserving
    /// actionable Supabase configuration messages.
    private static func signInFailure(_ error: APIError, fallback: String) -> String {
        switch error {
        case .notAuthenticated:
            fallback
        case .serverError(_, let message?):
            message
        default:
            error.errorDescription ?? fallback
        }
    }

    /// Creates a secure single-use nonce whose hash is sent to Apple.
    private static func makeNonce(length: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            // Authentication cannot safely continue without secure randomness.
            preconditionFailure("SecRandomCopyBytes failed — no secure randomness available")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
