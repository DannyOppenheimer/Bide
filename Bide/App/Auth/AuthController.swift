import AuthenticationServices
import CryptoKit
import Foundation
import Observation
import BideKit

/// Who the user is, and how they got here.
///
/// Two ways in, and the app works either way: Sign in with Apple, or carry on
/// anonymously. Both end at the same place — a real `auth.uid()` that the
/// row-level security policies are written against — so nothing downstream has
/// to care which happened.
@MainActor
@Observable
final class AuthController {

    private(set) var session: BideSession?
    private(set) var isWorking = false
    private(set) var errorMessage: String?

    /// Whether the user has been past the sign-in screen. Persisted, so
    /// choosing "use without signing in" isn't a decision they're asked to
    /// make again on every launch.
    private(set) var hasOnboarded: Bool {
        didSet { defaults.set(hasOnboarded, forKey: Self.onboardedKey) }
    }

    var isSignedInWithApple: Bool { session?.isAnonymous == false }

    private static let onboardedKey = "bide.onboarded"

    private let auth: BideAuthProvider
    private let api: any BideAPI
    private let profile: BideProfileStore
    private let defaults: UserDefaults

    /// The raw nonce for the sign-in currently in flight. Apple echoes its
    /// SHA-256 back inside the identity token, and Supabase checks the two
    /// against each other — which is what stops a token being replayed.
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

    /// Restores whatever identity this device already had, without prompting.
    func restore() async {
        guard hasOnboarded, session == nil else { return }
        session = try? await auth.currentSession()
    }

    /// "Use without signing in". Signs in anonymously behind the scenes, since
    /// every write needs an identity even when the user doesn't want an
    /// account.
    func continueWithoutSigningIn() async {
        await run {
            self.session = try await self.auth.currentSession()
            self.hasOnboarded = true
        }
    }

    // MARK: - Sign in with Apple

    /// Called by `SignInWithAppleButton` before the sheet appears.
    func configure(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.makeNonce()
        pendingNonce = nonce
        request.requestedScopes = [.fullName]
        request.nonce = Self.sha256(nonce)
    }

    func handle(_ result: Result<ASAuthorization, any Error>) async {
        switch result {
        case .failure(let error):
            // Tapping "Cancel" is not an error worth shouting about.
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

            await run {
                self.session = try await self.auth.signInWithApple(idToken: idToken, nonce: nonce)
                self.hasOnboarded = true
                self.pendingNonce = nil

                // Apple hands over a name exactly once, on the very first
                // authorisation. If it isn't kept now, it is gone.
                if let name = credential.fullName?.formatted(.name(style: .short)), !name.isEmpty {
                    self.profile.displayName = name
                    try? await self.api.updateDisplayName(name)
                }
            }
        }
    }

    /// Forgets this device's identity. An anonymous identity cannot be
    /// recovered afterwards, which is why the settings screen says so.
    func signOut() async {
        await auth.signOut()
        session = nil
        hasOnboarded = false
    }

    // MARK: - Plumbing

    private func run(_ work: @escaping () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            try await work()
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Something went wrong signing in."
        }
    }

    /// A random, single-use string. Apple requires the request carry its hash;
    /// Supabase requires the raw value, and compares them.
    private static func makeNonce(length: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            // Cannot proceed with a predictable nonce: that's the whole point
            // of it, and a weak one silently weakens sign-in.
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
