import SwiftUI
import BideKit

/// Bide's visual constants, sampled from the Figma reference screens.
///
/// The design notes say the reference files are rough — different fonts and
/// colours between screens — so this is the arbitration. Nothing in the app,
/// the extension, or the Live Activity should name a colour, a size, or a
/// radius that isn't here.
public enum BideColor {

    /// Every Bide surface sits on this. Fixed, not adaptive: the tile renders
    /// inside Messages, which is light, and the brand is dark regardless.
    public static let background = Color(hex: 0x1D1D1F)

    /// Cards, sheets, and the tile body.
    public static let surface = Color(hex: 0x2C2C2E)

    /// Controls resting on a surface — chips, the search field, the unselected
    /// mode buttons.
    public static let control = Color(hex: 0x333333)

    /// The selected mode button, one step brighter than a control.
    public static let controlSelected = Color(hex: 0x48484A)

    public static let primaryText = Color.white
    public static let secondaryText = Color(hex: 0x8E8E93)
    public static let tertiaryText = Color(hex: 0x6D6D73)

    /// Text and icons drawn on a white button.
    public static let inverseText = Color(hex: 0x0A0A0A)

    /// The LIVE pill, straight out of the Figma.
    public static let live = Color(hex: 0xEB4E3D)

    /// Avatar circles.
    public static let avatar = Color(hex: 0x8E8E93)

    /// Hairline borders, e.g. the Decline button's outline.
    public static let border = Color.white.opacity(0.18)

    /// The three states a time can be in.
    public static func delay(_ grade: DelayGrade) -> Color {
        switch grade {
        case .onSchedule: Color(hex: 0x30D158)
        case .slipping: Color(hex: 0xFFD60A)
        case .late: Color(hex: 0xFF453A)
        }
    }
}

/// SF Pro throughout, which is what `Font.system` resolves to. Named by role
/// so a screen never picks a point size directly.
public enum BideFont {

    /// The wordmark on the sign-in screen.
    public static let display = Font.system(size: 52, weight: .bold)
    /// A screen's own title — "Bide" on the main page.
    public static let screenTitle = Font.system(size: 34, weight: .bold)
    /// "Active Bide Sessions", "Create Solo-Bide".
    public static let sectionTitle = Font.system(size: 17, weight: .semibold)
    /// A card's headline — "Leave in 10 minutes", "John wants to go to Nats Park".
    public static let cardTitle = Font.system(size: 16, weight: .semibold)
    /// Prompts like "Where are we going?".
    public static let prompt = Font.system(size: 17, weight: .regular)
    public static let body = Font.system(size: 15, weight: .regular)
    /// Field labels — "Date", "Time", "Arrival Style".
    public static let label = Font.system(size: 13, weight: .medium)
    /// Secondary lines under a name or a title.
    public static let caption = Font.system(size: 13, weight: .regular)
    public static let button = Font.system(size: 17, weight: .semibold)
    /// A person's name in the roster.
    public static let personName = Font.system(size: 15, weight: .medium)
    /// The letter inside an avatar.
    public static let avatarInitial = Font.system(size: 22, weight: .medium)
    /// The LIVE pill.
    public static let badge = Font.system(size: 11, weight: .bold)
}

/// Spacing, radii, and the handful of fixed sizes the design repeats.
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
}

extension Color {
    /// `0xRRGGBB`, the form the design references are written in.
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
    /// The standard dark card: surface fill, brand radius.
    public func bideCard(
        padding: CGFloat = BideMetrics.cardPadding,
        radius: CGFloat = BideMetrics.cardRadius
    ) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity)
            .background(BideColor.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Paints Bide's background behind a whole screen, ignoring safe areas so
    /// it reaches the edges.
    public func bideBackground() -> some View {
        background(BideColor.background.ignoresSafeArea())
    }

    /// Text-field trimmings for the place search. Wrapped because these are
    /// iOS-only modifiers and BideUI still has to compile on macOS, where the
    /// package's tests run.
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

    /// A compact navigation title on iOS, the platform default elsewhere.
    func bideInlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
