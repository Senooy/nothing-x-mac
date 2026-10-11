import SwiftUI

/// Curseur vertical d'une bande d'égaliseur (-12…+12 dB, pas de 0,5).
struct BandSlider: View {
    let gain: Float
    let freq: Float
    var range: ClosedRange<Float> = -12...12
    let onChange: (Float) -> Void
    let onEnd: () -> Void

    private let trackHeight: CGFloat = 160

    private var freqLabel: String {
        freq >= 1000 ? String(format: "%.1fK", freq / 1000).replacingOccurrences(of: ".0K", with: "K") : "\(Int(freq))"
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(String(format: "%+.1f", gain))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(gain == 0 ? NTColor.disabled : NTColor.display)
            GeometryReader { _ in
                let span = range.upperBound - range.lowerBound
                let y = trackHeight * CGFloat((range.upperBound - gain) / span)
                ZStack(alignment: .top) {
                    Rectangle().fill(NTColor.border).frame(width: 1)
                    // Bar from the 0 dB line to the thumb: grows up for boosts, down for cuts.
                    Rectangle().fill(NTColor.display)
                        .frame(width: 4, height: abs(y - trackHeight / 2))
                        .offset(y: min(y, trackHeight / 2))
                    Rectangle().fill(NTColor.disabled).frame(width: 14, height: 1)
                        .offset(y: trackHeight / 2)
                    Circle().fill(NTColor.display).frame(width: 12, height: 12)
                        .offset(y: y - 6)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let t = min(max(drag.location.y / trackHeight, 0), 1)
                            let raw = range.upperBound - Float(t) * span
                            onChange(((raw * 2).rounded() / 2))
                        }
                        .onEnded { _ in onEnd() }
                )
            }
            .frame(height: trackHeight)
            Text(freqLabel).ntLabel(NTColor.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(freqLabel) Hz"))
        .accessibilityValue(Text(verbatim: String(format: "%+.1f dB", gain)))
        .accessibilityAdjustableAction { direction in
            let step: Float = direction == .increment ? 0.5 : -0.5
            onChange(min(max(gain + step, range.lowerBound), range.upperBound))
            onEnd()
        }
    }
}
