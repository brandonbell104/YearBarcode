import SwiftUI
import YearBarcodeCore

/// The app's dark design language: near-black canvas, light primary buttons,
/// rounded charcoal cards and a single orange accent.
enum Theme {
    static let background = Color(light: 0xF2F2F7, dark: 0x0A0A0B)
    static let card = Color(light: 0xFFFFFF, dark: 0x161618)
    static let control = Color(light: 0xE5E5EA, dark: 0x1C1C1F)
    static let controlSelected = Color(light: 0xFFFFFF, dark: 0x3A3A3F)
    static let posterWell = Color(light: 0xE5E5EA, dark: 0x151517)
    static let hairline = Color(light: 0xD1D1D6, dark: 0x2C2C30)
    static let primaryText = Color(light: 0x1C1C1E, dark: 0xF5F5F7)
    static let secondaryText = Color(light: 0x6E6E73, dark: 0xA1A1A6)
    static let tertiaryText = Color(light: 0x8E8E93, dark: 0x8E8E93)
    static let bodyText = Color(light: 0x3A3A3C, dark: 0xD1D1D6)
    static let accent = Color(light: 0xF28C00, dark: 0xFF9F0A)
    static let destructive = Color(light: 0xE5372C, dark: 0xFF6961)
    static let success = Color(light: 0x248A3D, dark: 0x30D158)
}

/// The user's appearance choice (Settings). Dark is the default look.
enum Appearance: String, CaseIterable {
    case system
    case light
    case dark

    static let storageKey = "appearance"

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    /// A color that follows light and dark mode.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Theme.background)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Theme.primaryText.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var foreground: Color = Theme.primaryText

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Theme.control.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 16))
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
    static func secondary(_ foreground: Color) -> SecondaryButtonStyle { SecondaryButtonStyle(foreground: foreground) }
}

/// Small uppercase heading above a control group ("MODE", "PRINT SIZE").
struct SectionLabel: View {
    let text: String
    var trailing: String?

    init(_ text: String, trailing: String? = nil) {
        self.text = text
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text.uppercased())
                .font(.system(size: 13, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.tertiaryText)
            Spacer()
            if let trailing {
                Text(trailing).font(.system(size: 12)).foregroundStyle(Theme.tertiaryText)
            }
        }
    }
}

/// Dark pill segmented control (Every Photo / Every Day).
struct PillSegmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var height: CGFloat = 38

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.0) { option in
                let (value, label) = option
                let on = value == selection
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = value }
                } label: {
                    Text(label)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(on ? Theme.primaryText : Theme.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: height)
                        .background(on ? Theme.controlSelected : .clear, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Light-when-selected chips (print sizes).
struct ChipPicker<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var height: CGFloat = 46

    var body: some View {
        HStack(spacing: 10) {
            ForEach(options, id: \.0) { option in
                let (value, label) = option
                let on = value == selection
                Button {
                    selection = value
                } label: {
                    Text(label)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(on ? Theme.background : Theme.primaryText)
                        .frame(maxWidth: .infinity, minHeight: height)
                        .background(on ? Theme.primaryText : Theme.control, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// Custom navigation bar: back link on the left, title centered, optional trailing item.
struct NavHeader<Trailing: View>: View {
    var backTitle: String?
    var title: String
    var onBack: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ZStack {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.primaryText)
            HStack {
                if let backTitle, let onBack {
                    Button(action: onBack) {
                        HStack(spacing: 2) {
                            Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                            Text(backTitle).font(.system(size: 17))
                        }
                        .foregroundStyle(Theme.accent)
                        .frame(minHeight: 44)
                        .padding(.horizontal, 8)
                    }
                }
                Spacer()
                trailing()
            }
        }
        .frame(height: 44)
        .padding(.horizontal, 8)
    }
}

extension NavHeader where Trailing == EmptyView {
    init(backTitle: String? = nil, title: String, onBack: (() -> Void)? = nil) {
        self.init(backTitle: backTitle, title: title, onBack: onBack) { EmptyView() }
    }
}

// MARK: - Barcode drawing

/// Equal-width stripes drawn with Canvas (fast even for thousands of stripes).
struct StripesView: View {
    let colors: [Color]
    var vertical = true

    var body: some View {
        Canvas { context, size in
            guard !colors.isEmpty else { return }
            let n = CGFloat(colors.count)
            for (i, color) in colors.enumerated() {
                let a = CGFloat(i) / n, b = CGFloat(i + 1) / n
                let rect = vertical
                    ? CGRect(x: a * size.width, y: 0, width: (b - a) * size.width + 0.5, height: size.height)
                    : CGRect(x: 0, y: a * size.height, width: size.width, height: (b - a) * size.height + 0.5)
                context.fill(Path(rect), with: .color(color))
            }
        }
    }
}

extension Color {
    init(_ color: RGB8) {
        self.init(.sRGB, red: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255)
    }
}

/// Decorative "a year of photos" stripes for places with no real data yet
/// (the welcome screen). Seasonal hues with natural variation.
enum DecorativeStripes {
    private static let keys: [(Double, Double, Double, Double)] = [
        (0, 212, 18, 58), (0.12, 205, 22, 48), (0.25, 150, 22, 50), (0.38, 105, 38, 46), (0.5, 195, 55, 55),
        (0.6, 40, 50, 62), (0.72, 32, 62, 48), (0.83, 22, 48, 36), (0.92, 8, 45, 38), (1, 215, 25, 30),
    ]

    static func colors(_ n: Int, seed: Int = 11) -> [Color] {
        var s = seed
        func random() -> Double {
            s = (s * 16807) % 2147483647
            return Double(s) / 2147483647
        }
        return (0..<n).map { i in
            let t = Double(i) / Double(max(n - 1, 1))
            var a = keys[0], b = keys[keys.count - 1]
            for k in 0..<(keys.count - 1) where t >= keys[k].0 && t <= keys[k + 1].0 {
                a = keys[k]; b = keys[k + 1]; break
            }
            let u = (t - a.0) / max(b.0 - a.0, 1e-9)
            var h = a.1 + (b.1 - a.1) * u, sat = a.2 + (b.2 - a.2) * u, l = a.3 + (b.3 - a.3) * u
            let x = random()
            if x < 0.07 { l = 10 + random() * 10; sat *= 0.5 } else if x < 0.12 { l = 72 + random() * 12; sat *= 0.6 } else if x < 0.2 { h += (random() - 0.5) * 80 }
            h += (random() - 0.5) * 18; l += (random() - 0.5) * 16; sat += (random() - 0.5) * 14
            l = min(max(l, 6), 88); sat = min(max(sat, 4), 85)
            return Color(hsl: (h + 360).truncatingRemainder(dividingBy: 360), sat / 100, l / 100)
        }
    }
}

extension DecorativeStripes {
    /// Plain gray stripes: clearly a stand-in, not anyone's real year.
    static func placeholder(_ n: Int, seed: Int = 5) -> [Color] {
        var s = seed
        return (0..<n).map { _ in
            s = (s * 16807) % 2147483647
            let l = 0.78 + Double(s % 1000) / 1000 * 0.14
            return Color(.sRGB, red: l, green: l, blue: l)
        }
    }
}

extension Color {
    /// HSL (hue in degrees, saturation and lightness 0...1).
    init(hsl h: Double, _ s: Double, _ l: Double) {
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r, g, b): (Double, Double, Double)
        switch h {
        case ..<60: (r, g, b) = (c, x, 0)
        case ..<120: (r, g, b) = (x, c, 0)
        case ..<180: (r, g, b) = (0, c, x)
        case ..<240: (r, g, b) = (0, x, c)
        case ..<300: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        self.init(.sRGB, red: r + m, green: g + m, blue: b + m)
    }
}

/// The poster preview inside its dark rounded well.
struct PosterWell: View {
    let image: CGImage?
    let settings: ArtworkSettings
    var height: CGFloat = 270

    var body: some View {
        let canvas = settings.printSize.canvas(settings.orientation)
        RoundedRectangle(cornerRadius: 24)
            .fill(Theme.posterWell)
            .frame(height: height)
            .overlay {
                Group {
                    if let image {
                        Image(decorative: image, scale: 1).resizable().interpolation(.medium)
                    } else {
                        Color(settings.background).overlay(ProgressView().tint(Theme.tertiaryText))
                    }
                }
                .aspectRatio(CGFloat(canvas.width) / CGFloat(canvas.height), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .shadow(color: .black.opacity(0.6), radius: 24, y: 12)
                .padding(20)
            }
            .accessibilityElement()
            .accessibilityLabel("Poster preview")
    }
}
