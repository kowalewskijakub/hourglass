import SwiftUI

/// A circular progress ring that fills clockwise from 12 o'clock.
struct TimerRingView: View {
    var progress: Double          // 0 = just started, 1 = complete
    var tint: Color
    var lineWidth: CGFloat = 16

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: progress)
        }
        .padding(lineWidth / 2)
    }
}
