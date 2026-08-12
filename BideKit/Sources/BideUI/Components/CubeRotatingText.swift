import SwiftUI

/// The line under the wordmark, rotating like a face of a cube.
///
/// Two faces are on screen at once — the one leaving and the one arriving —
/// each rotated about the x-axis and pushed out from the centre by half the
/// cube's depth, which is what makes the edge between them read as a corner
/// rather than a crossfade.
public struct CubeRotatingText: View {

    /// The taglines from the design brief. Shuffled once per launch so the
    /// same one doesn't always greet you.
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
    ]

    private let phrases: [String]
    private let font: Font
    private let interval: TimeInterval
    private let duration: TimeInterval

    @State private var index = 0
    @State private var incoming = 1
    @State private var turn: Double = 0
    /// Measured rather than assumed: the cube's depth has to match the height
    /// of the text or the faces don't meet at the corner.
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
            // Sizes the cube from the longest phrase so the frame never jumps
            // mid-rotation.
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
            // A phrase holds still for `interval`, then turns. Cancelled with
            // the view, so nothing keeps spinning off-screen.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: duration)) {
                    turn = 1
                }
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                // Land the incoming face on the front and reset, with no
                // animation so the swap is invisible.
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
            // The face swinging away fades out as it turns past the edge.
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
