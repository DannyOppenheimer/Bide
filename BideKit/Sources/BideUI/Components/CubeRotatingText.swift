import SwiftUI

/// Rotates between text phrases using two faces of a virtual cube.
public struct CubeRotatingText: View {

    /// Default taglines, shuffled by the default initializer.
    public static let taglines = [
        "Know when to leave.",
        "You've got more time than you think.",
        "Stay on the couch a little longer.",
        "The last text you'll send before you leave.",
        #"No more "where are you?""#,
        "Stop guessing. Start relaxing.",
        "Never leave too early again.",
        "Wait less. Rush less.",
        #"The "how far are you" text, automated."#,
        "Because someone always leaves too early.",
        "Coordinate less. Meet on time.",
        "Get one more scroll in.",
    ]

    private let phrases: [String]
    private let font: Font
    private let interval: TimeInterval
    private let duration: TimeInterval

    @State private var index = 0
    @State private var incoming = 1
    @State private var turn: Double = 0
    /// Measured face height, also used as the cube depth.
    @State private var faceHeight: CGFloat = 24

    public init(
        phrases: [String] = CubeRotatingText.taglines.shuffled(),
        font: Font = BideFont.prompt,
        interval: TimeInterval = 4,
        duration: TimeInterval = 0.7
    ) {
        self.phrases = phrases.isEmpty ? ["Know when to leave."] : phrases
        self.font = font
        self.interval = interval
        self.duration = duration
    }

    public var body: some View {
        ZStack {
            face(phrases[index % phrases.count], angle: -90 * turn)
            face(phrases[incoming % phrases.count], angle: 90 - 90 * turn)
        }
        .frame(height: faceHeight)
        .background {
            // Reserve enough height to prevent layout changes during rotation.
            Text(phrases.max(by: { $0.count < $1.count }) ?? "")
                .font(font)
                .hidden()
                .background {
                    GeometryReader { proxy in
                        Color.clear.onAppear { faceHeight = proxy.size.height }
                    }
                }
        }
        .task {
            // The task is cancelled automatically when the view disappears.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: duration)) {
                    turn = 1
                }
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                // Reset to the incoming face without animating the index swap.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    index = incoming
                    incoming = (incoming + 1) % phrases.count
                    turn = 0
                }
            }
        }
        .accessibilityLabel(phrases[index % phrases.count])
    }

    private func face(_ text: String, angle: Double) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(BideColor.primaryText)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.center)
            .rotation3DEffect(
                .degrees(angle),
                axis: (x: 1, y: 0, z: 0),
                anchor: .center,
                anchorZ: -faceHeight / 2,
                perspective: 0.5
            )
            // Hide a face after it rotates past the visible edge.
            .opacity(abs(angle) > 60 ? 0 : 1)
            .animation(.easeInOut(duration: duration), value: angle)
    }
}

#Preview {
    VStack(spacing: 16) {
        BideMark(.horizontal, dotDiameter: 14)
        Text("Bide")
            .font(BideFont.display)
            .foregroundStyle(BideColor.primaryText)
        CubeRotatingText(interval: 1.5)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .bideBackground()
}
