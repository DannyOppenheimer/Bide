import Foundation

/// Shared App Group configuration for the app and Messages extension.
public enum BideAppGroup {
    public static let identifier = "group.app.trybide.bide"
}

extension UserDefaults {

    /// Shared defaults, falling back to process-local storage if unavailable.
    public static var bideShared: UserDefaults {
        UserDefaults(suiteName: BideAppGroup.identifier) ?? .standard
    }
}

/// Stores profile details shared with the Messages extension.
public struct BideProfileStore: @unchecked Sendable {

    /// `UserDefaults` is thread-safe, which supports the unchecked conformance.
    private let defaults: UserDefaults
    private static let displayNameKey = "bide.profile.displayName"
    private static let signedInKey = "bide.profile.signedInWithApple"

    public init(defaults: UserDefaults = .bideShared) {
        self.defaults = defaults
    }

    /// The trimmed display name, or `nil` if unset or empty.
    public var displayName: String? {
        get {
            let stored = defaults.string(forKey: Self.displayNameKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return stored?.isEmpty == false ? stored : nil
        }
        nonmutating set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                defaults.set(trimmed, forKey: Self.displayNameKey)
            } else {
                defaults.removeObject(forKey: Self.displayNameKey)
            }
        }
    }

    /// Whether the app has a durable Apple identity that can send invitations.
    /// Defaults to `false` when shared storage is unavailable or uninitialized.
    public var isSignedInWithApple: Bool {
        get { defaults.bool(forKey: Self.signedInKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.signedInKey) }
    }
}
