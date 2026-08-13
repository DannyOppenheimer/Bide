import SwiftUI

/// Bide's logo and its animated transition between vertical and horizontal forms.
/// `progress` ranges from 0 for vertical to 1 for horizontal.
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

    /// Creates a mark at an explicit animation progress.
    public init(progress: Double, dotDiameter: CGFloat = 8, color: Color = BideColor.primaryText) {
        self.progress = min(max(progress, 0), 1)
        self.dotDiameter = dotDiameter
        self.color = color
    }

    /// Distance between adjacent dot centers.
    private var spacing: CGFloat { dotDiameter * 2 }

    public var body: some View {
        // Resize around the stationary anchor dot as the mark changes orientation.
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

/// A single animatable path containing the mark's dots and connecting bar.
struct BideMarkShape: Shape {

    var progress: Double
    var dotDiameter: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    /// Bar thickness scaled from the source SVG proportions.
    private var barThickness: CGFloat { max(1, dotDiameter * 0.24) }
    private var spacing: CGFloat { dotDiameter * 2 }

    func path(in rect: CGRect) -> Path {
        // Retract vertically during the first half, then extend horizontally.
        let retracted = 1 - min(max(progress * 2, 0), 1)
        let extended = min(max(progress * 2 - 1, 0), 1)

        let anchor = CGPoint(x: rect.minX + dotDiameter / 2, y: rect.minY + dotDiameter / 2)
        var path = Path()

        // Retracting vertical tail.
        let verticalReach = spacing * 2 * retracted
        if verticalReach > 0.5 {
            path.addPath(bar(from: anchor, to: CGPoint(x: anchor.x, y: anchor.y + verticalReach)))
        }
        for index in 1...2 {
            let offset = spacing * CGFloat(index) * retracted
            path.addPath(dot(at: CGPoint(x: anchor.x, y: anchor.y + offset)))
        }

        // Extending horizontal tail.
        let horizontalReach = spacing * 3 * extended
        if horizontalReach > 0.5 {
            path.addPath(bar(from: anchor, to: CGPoint(x: anchor.x + horizontalReach, y: anchor.y)))
        }
        for index in 1...3 {
            let offset = spacing * CGFloat(index) * extended
            path.addPath(dot(at: CGPoint(x: anchor.x + offset, y: anchor.y)))
        }

        // Draw the anchor last to cover the bar ends at the midpoint.
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
