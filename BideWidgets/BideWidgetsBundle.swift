import SwiftUI
import WidgetKit

/// The app's widget extension. Only a Live Activity for now — the design has
/// no home-screen widget, and an empty one would be worse than none.
@main
struct BideWidgetsBundle: WidgetBundle {
    var body: some Widget {
        BideLiveActivity()
    }
}
