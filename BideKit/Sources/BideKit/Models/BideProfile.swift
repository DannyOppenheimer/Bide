import Foundation

/// The App Group the container app and the Messages extension share.
///
/// Everything shared through it is small and non-authoritative — a display
/// name, this device's own answers — so if the entitlement isn't provisioned,
/// ``UserDefaults/bideShared`` quietly falls back to per-process storage and
/// the only thing lost is that the extension stops knowing what the app knows.
/// Nothing breaks; a name goes missing from a tile.
public enum BideAppGroup {
    public static let identifier = "group.app.trybide.bide"
}

extension UserDefaults {

    /// Shared defaults, or this process's own if the App Group isn't
    /// available. Computed rather than stored: `UserDefaults` isn't
    /// `Sendable`, and it hands back the same suite instance every time
    /// anyway, so there is nothing to cache.
    public static var bideShared: UserDefaults {
        UserDefaults(suiteName: BideAppGroup.identifier) ?? .standard
    }
}

/// What the user calls themselves.
///
/// Lives in the App Group because the extension needs it at compose time — a
/// tile that says "John wants to go to Nats Park" gets the name from here —
/// while the app is the only place it can be edited.
public struct BideProfileStore: @unchecked Sendable {

    /// `UserDefaults` is thread-safe; that's what the unchecked conformance
    /// stands on.
    private let defaults: UserDefaults
    private static let displayNameKey = "bide.profile.displayName"
    private static let signedInKey = "bide.profile.signedInWithApple"

    public init(defaults: UserDefaults = .bideShared) {
        self.defaults = defaults
    }

    /// Nil when they've never set one, which is different from an empty
    /// string: the UI shows a placeholder rather than a blank.
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

    /// Whether this person has a real account rather than a device-local one.
    ///
    /// Written by the container app, which owns the identity, and read by the
    /// Messages extension, which has none of its own. Sending a tile puts a
    /// bide in someone else's hands and has to survive a reinstall, so it is
    /// the one thing an anonymous identity may not do — the extension checks
    /// this before offering the compose form.
    ///
    /// Defaults to false, which is the safe answer: a missing App Group, or a
    /// launch before the app has ever run, reads as "not signed in" and offers
    /// the way in rather than a form that would fail later.
    public var isSignedInWithApple: Bool {
        get { defaults.bool(forKey: Self.signedInKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.signedInKey) }
    }
}
