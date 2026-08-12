import SwiftUI

/// Bide's logo, in both forms and every frame in between.
///
/// Geometry is taken from `design/company_style/`: dots of radius R, centres
/// spaced 4R apart, joined by a bar 0.24R thick. Drawing it rather than
/// shipping the SVGs keeps one definition for the app, the tile, and the Live
/// Activity, and — more usefully — makes the morph between the two forms a
/// single animatable number.
///
/// The morph is the one the design asks for. The top-left dot never moves:
///
/// ```
/// o        o        o        o-o      o-o-o    o-o-o-o
/// |        |
/// o        o
/// |
/// o
/// ```
///
/// The two lower dots retract into the anchor, then three new ones slide out
/// sideways. `progress` 0 is the vertical mark, 1 the horizontal one, and
/// because it's a `Shape` the in-between frames are real — SwiftUI drives them
/// with any ordinary animation.
public struct BideMark: View {

    public enum Form {
        case vertical
        case horizontal

        var progress: Double {
            switch self {
            case .vertical: 0
            case .horizontal: 1
            }
        }
    }

    private let progress: Double
    private let dotDiameter: CGFloat
    private let color: Color

    public init(_ form: Form, dotDiameter: CGFloat = 8, color: Color = BideColor.primaryText) {
        self.init(progress: form.progress, dotDiameter: dotDiameter, color: color)
    }

    /// Free-standing progress, for driving the transition by hand.
    public init(progress: Double, dotDiameter: CGFloat = 8, color: Color = BideColor.primaryText) {
        self.progress = min(max(progress, 0), 1)
        self.dotDiameter = dotDiameter
        self.color = color
    }

    /// Distance between dot centres.
    private var spacing: CGFloat { dotDiameter * 2 }

    public var body: some View {
        // The frame collapses and grows with the mark, so the anchor dot stays
        // put while the rest of the layout closes up around it.
        let horizontal = min(max(progress * 2 - 1, 0), 1)
        let vertical = 1 - min(progress * 2, 1)

        BideMarkShape(progress: progress, dotDiameter: dotDiameter)
            .fill(color)
            .frame(
                width: dotDiameter + spacing * 3 * horizontal,
                height: dotDiameter + spacing * 2 * vertical,
                alignment: .topLeading
            )
    }
}

/// The mark as a single filled path — dots and bar together, so one `fill`
/// covers it and `animatableData` interpolates the whole thing.
struct BideMarkShape: Shape {

    var progress: Double
    var dotDiameter: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    /// The bar's thickness, from the source SVGs: 6pt against a 25pt radius.
    private var barThickness: CGFloat { max(1, dotDiameter * 0.24) }
    private var spacing: CGFloat { dotDiameter * 2 }

    func path(in rect: CGRect) -> Path {
        // Two halves of one gesture: the vertical tail retracts over the first
        // half, the horizontal tail extends over the second.
        let retracted = 1 - min(max(progress * 2, 0), 1)
        let extended = min(max(progress * 2 - 1, 0), 1)

        let anchor = CGPoint(x: rect.minX + dotDiameter / 2, y: rect.minY + dotDiameter / 2)
        var path = Path()

        // Vertical tail: two dots that slide up into the anchor.
        let verticalReach = spacing * 2 * retracted
        if verticalReach > 0.5 {
            path.addPath(bar(from: anchor, to: CGPoint(x: anchor.x, y: anchor.y + verticalReach)))
        }
        for index in 1...2 {
            let offset = spacing * CGFloat(index) * retracted
            path.addPath(dot(at: CGPoint(x: anchor.x, y: anchor.y + offset)))
        }

        // Horizontal tail: three dots that slide out of it.
        let horizontalReach = spacing * 3 * extended
        if horizontalReach > 0.5 {
            path.addPath(bar(from: anchor, to: CGPoint(x: anchor.x + horizontalReach, y: anchor.y)))
        }
        for index in 1...3 {
            let offset = spacing * CGFloat(index) * extended
            path.addPath(dot(at: CGPoint(x: anchor.x + offset, y: anchor.y)))
        }

        // The anchor is added last so it sits over the bar ends, which is what
        // keeps the single-dot frame of the animation looking like one dot.
        path.addPath(dot(at: anchor))
        return path
    }

    private func dot(at centre: CGPoint) -> Path {
        Path(
            ellipseIn: CGRect(
                x: centre.x - dotDiameter / 2,
                y: centre.y - dotDiameter / 2,
                width: dotDiameter,
                height: dotDiameter
            )
        )
    }

    private func bar(from start: CGPoint, to end: CGPoint) -> Path {
        let rect = CGRect(
            x: min(start.x, end.x) - (start.x == end.x ? barThickness / 2 : 0),
            y: min(start.y, end.y) - (start.y == end.y ? barThickness / 2 : 0),
            width: start.x == end.x ? barThickness : abs(end.x - start.x),
            height: start.y == end.y ? barThickness : abs(end.y - start.y)
        )
        return Path(rect)
    }
}

#Preview("Forms") {
    VStack(spacing: 40) {
        BideMark(.horizontal, dotDiameter: 12)
        BideMark(.vertical, dotDiameter: 12)
        BideMark(progress: 0.5, dotDiameter: 12)
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .bideBackground()
}
