import SwiftUI

/// Tokens Nothing : noir OLED, gris en opacité, rouge réservé aux interruptions.
enum NTColor {
    static let background = Color.black
    static let surface = Color(white: 0.07)
    static let border = Color(white: 0.16)
    static let display = Color.white
    static let primary = Color.white.opacity(0.9)
    static let secondary = Color.white.opacity(0.6)
    static let disabled = Color.white.opacity(0.4)
    static let accent = Color(red: 0.843, green: 0.098, blue: 0.129) // #D71921
}

extension Text {
    /// Étiquette tertiaire : mono, majuscules, interlettrage large.
    func ntLabel(_ color: Color = NTColor.secondary) -> some View {
        self.font(.system(size: 11, weight: .regular, design: .monospaced))
            .tracking(1.6)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}

struct SectionHeader: View {
    let title: LocalizedStringKey
    var trailing: String = ""
    var body: some View {
        HStack {
            Text(title).ntLabel()
            Spacer()
            if !trailing.isEmpty { Text(verbatim: trailing).ntLabel(NTColor.disabled) }
        }
    }
}

/// Contrôle segmenté : pilule contour fin, segment actif plein.
struct Segmented<ID: Hashable>: View {
    let options: [(id: ID, label: String)]
    let selection: ID?
    let onSelect: (ID) -> Void
    @State private var hovered: Int?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let active = option.id == selection
                Button { onSelect(option.id) } label: {
                    Text(verbatim: option.label)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .textCase(.uppercase)
                        .tracking(1.2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(active ? Color.black : NTColor.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(active ? NTColor.display : (hovered == index ? Color.white.opacity(0.08) : Color.clear)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { inside in hovered = inside ? index : (hovered == index ? nil : hovered) }
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(4)
        .overlay(Capsule().stroke(NTColor.border, lineWidth: 1))
    }
}

// MARK: - Matrice de points

/// Chiffres 5×7 dessinés en points, pour le moment « signature » de l'écran.
struct DotMatrixText: View {
    let text: String
    var dot: CGFloat = 7
    var color: Color = NTColor.display

    private static let glyphs: [Character: [String]] = [
        "0": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
        "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
        "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
        "3": ["11110", "00001", "00001", "01110", "00001", "00001", "11110"],
        "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
        "5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
        "6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
        "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
        "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
        "9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
        "%": ["11001", "11010", "00010", "00100", "01000", "01011", "10011"],
        "-": ["00000", "00000", "00000", "11111", "00000", "00000", "00000"],
    ]

    private var pitch: CGFloat { dot * 1.45 }
    private var size: CGSize {
        let n = CGFloat(text.count)
        return CGSize(width: n * 5 * pitch + max(0, n - 1) * pitch, height: 7 * pitch - (pitch - dot))
    }

    var body: some View {
        Canvas { ctx, _ in
            for (ci, ch) in text.enumerated() {
                guard let rows = Self.glyphs[ch] else { continue }
                let x0 = CGFloat(ci) * 6 * pitch
                for (r, row) in rows.enumerated() {
                    for (c, bit) in row.enumerated() where bit == "1" {
                        let rect = CGRect(x: x0 + CGFloat(c) * pitch, y: CGFloat(r) * pitch, width: dot, height: dot)
                        ctx.fill(Path(ellipseIn: rect), with: .color(color))
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityLabel(text)
    }
}
