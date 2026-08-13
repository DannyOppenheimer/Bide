import SwiftUI
import BideKit

/// Shared color tokens for the app, extension, and Live Activity.
public enum BideColor {

    /// Fixed brand background used in both light and dark system appearances.
    public static let background = Color(hex: 0x1D1D1F)

    /// Cards, sheets, and the tile body.
    public static let surface = Color(hex: 0x2C2C2E)

    /// Background for chips, fields, and unselected controls.
    public static let control = Color(hex: 0x333333)

    /// Background for selected controls.
    public static let controlSelected = Color(hex: 0x48484A)

    public static let primaryText = Color.white
    public static let secondaryText = Color(hex: 0x8E8E93)
    public static let tertiaryText = Color(hex: 0x6D6D73)

    /// Text and icons displayed on light controls.
    public static let inverseText = Color(hex: 0x0A0A0A)

    /// Live-status badge color.
    public static let live = Color(hex: 0xEB4E3D)

    /// Watcher accent, distinct from delay-status colors.
    public static let watching = Color(hex: 0x5E9CFF)

    /// Avatar circles.
    public static let avatar = Color(hex: 0x8E8E93)

    /// Hairline border color.
    public static let border = Color.white.opacity(0.18)

    /// Color associated with a delay grade.
    public static func delay(_ grade: DelayGrade) -> Color {
        switch grade {
        case .onSchedule: Color(hex: 0x30D158)
        case .slipping: Color(hex: 0xFFD60A)
        case .late: Color(hex: 0xFF453A)
        }
    }
}

/// Shared typography tokens using the system font.
public enum BideFont {

    /// The wordmark on the sign-in screen.
    public static let display = Font.system(size: 52, weight: .bold)
    /// Primary screen title.
    public static let screenTitle = Font.system(size: 34, weight: .bold)
    /// Section heading.
    public static let sectionTitle = Font.system(size: 17, weight: .semibold)
    /// Card headline.
    public static let cardTitle = Font.system(size: 16, weight: .semibold)
    /// Form prompt.
    public static let prompt = Font.system(size: 17, weight: .regular)
    public static let body = Font.system(size: 15, weight: .regular)
    /// Field label.
    public static let label = Font.system(size: 13, weight: .medium)
    /// Secondary text below names and titles.
    public static let caption = Font.system(size: 13, weight: .regular)
    public static let button = Font.system(size: 17, weight: .semibold)
    /// Participant name.
    public static let personName = Font.system(size: 15, weight: .medium)
    /// Prominent ETA value in a roster tile.
    public static let etaValue = Font.system(size: 20, weight: .semibold)
    /// Avatar initial.
    public static let avatarInitial = Font.system(size: 22, weight: .medium)
    /// Live-status badge.
    public static let badge = Font.system(size: 11, weight: .bold)
}

/// Shared spacing, radius, and size tokens.
public enum BideMetrics {

    public static let cardRadius: CGFloat = 20
    public static let tileRadius: CGFloat = 18
    public static let controlRadius: CGFloat = 10

    /// Screen and sheet gutters.
    public static let gutter: CGFloat = 20
    /// Padding inside a card.
    public static let cardPadding: CGFloat = 16

    public static let sectionSpacing: CGFloat = 20
    public static let stackSpacing: CGFloat = 12
    public static let tightSpacing: CGFloat = 6

    public static let controlHeight: CGFloat = 44
    public static let modeButtonSize: CGFloat = 40
    public static let avatarSize: CGFloat = 52

    /// Extra top inset that clears Messages' app badge in live-layout bubbles.
    public static let tileBadgeClearance: CGFloat = 14

    /// Fixed Lock Screen Live Activity height; excess content is clipped.
    public static let liveActivityMaxHeight: CGFloat = 160
}

extension Color {
    /// Creates a color from an `0xRRGGBB` value.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension View {
    /// Applies the standard card padding, fill, and corner radius.
    public func bideCard(
        padding: CGFloat = BideMetrics.cardPadding,
        radius: CGFloat = BideMetrics.cardRadius
    ) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity)
            .background(BideColor.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Applies the brand background through all safe areas.
    public func bideBackground() -> some View {
        background(BideColor.background.ignoresSafeArea())
    }

    /// Applies platform-appropriate place-search input behavior.
    func bideSearchInput() -> some View {
        #if os(iOS)
        self
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .submitLabel(.search)
        #else
        self.autocorrectionDisabled()
        #endif
    }

    /// Uses an inline navigation title on iOS and the platform default elsewhere.
    func bideInlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
