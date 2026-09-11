import SwiftUI

/// A Finder-style determinate progress ring — fills clockwise from the
/// top as `fraction` (0...1) increases, unlike SwiftUI's built-in
/// `.circular` progress style, which stays an indeterminate spinner
/// even when given a value on macOS. `fraction == nil` falls back to a
/// plain spinner (nothing to show a determinate ring for yet, e.g.
/// before the first progress reading arrives).
struct CircularProgressView: View {
    let fraction: Double?
    var lineWidth: CGFloat = 3

    var body: some View {
        if let fraction {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: max(0, min(1, fraction)))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: fraction)
            }
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }
}
