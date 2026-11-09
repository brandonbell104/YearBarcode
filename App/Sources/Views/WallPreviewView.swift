import SwiftUI
import YearBarcodeCore

/// How a print would be finished.
enum WallFinish: String, CaseIterable, Identifiable {
    case poster
    case framedBlack
    case framedWhite
    case framedOak
    case canvas

    var id: String { rawValue }

    var title: String {
        switch self {
        case .poster: return "Poster"
        case .framedBlack: return "Black frame"
        case .framedWhite: return "White frame"
        case .framedOak: return "Oak frame"
        case .canvas: return "Canvas"
        }
    }

    var frameColor: Color? {
        switch self {
        case .framedBlack: return Color(hex: 0x1E1E1E)
        case .framedWhite: return Color(hex: 0xF4F4F2)
        case .framedOak: return Color(hex: 0xB98D5A)
        default: return nil
        }
    }
}

/// A room to hang the poster in, measured in inches so every print size
/// shows at its true size. `x` is from the left edge, `y` is height above
/// the floor.
struct WallScene: Identifiable {
    let id: String
    let name: String
    /// Inches across the whole picture; the picture is 4:3.
    let widthInches: Double = 144
    let floorInches: Double = 14
    let wall: Color
    let floor: Color
    /// Center of the hung poster.
    let posterCenter: (x: Double, y: Double)
    /// Draws furniture in inch coordinates via `place`.
    let furniture: (inout GraphicsContext, (_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect, Double) -> Void

    var heightInches: Double { widthInches * 3 / 4 }
}

extension WallScene {
    static let all: [WallScene] = [livingRoom, bedroom, entryway]

    static let livingRoom = WallScene(
        id: "living", name: "Living room",
        wall: Color(hex: 0xEDE7DE), floor: Color(hex: 0xA77B52),
        posterCenter: (72, 63)
    ) { context, rect, k in
        // Sofa: 84 × 34 in, cushions and legs.
        let body = Color(hex: 0x7D8590)
        context.fill(Path(roundedRect: rect(30, 16, 84, 18), cornerRadius: 3 * k), with: .color(body))       // back
        context.fill(Path(roundedRect: rect(26, 4, 92, 16), cornerRadius: 4 * k), with: .color(body.opacity(0.92))) // seat base
        for i in 0..<3 {                                                                                       // seat cushions
            context.fill(Path(roundedRect: rect(32 + Double(i) * 27, 14, 26, 7), cornerRadius: 2.5 * k), with: .color(Color(hex: 0x8C949E)))
        }
        context.fill(Path(roundedRect: rect(24, 4, 9, 22), cornerRadius: 3 * k), with: .color(body))          // arms
        context.fill(Path(roundedRect: rect(111, 4, 9, 22), cornerRadius: 3 * k), with: .color(body))
        context.fill(Path(roundedRect: rect(38, 21, 14, 11), cornerRadius: 3 * k), with: .color(Color(hex: 0xD9B44A))) // pillow
        for x in [28.0, 114.0] { context.fill(Path(rect(x, 0, 2, 4)), with: .color(Color(hex: 0x3B2F25))) }  // legs
        // Plant in a pot.
        context.fill(Path(roundedRect: rect(126, 0, 12, 14), cornerRadius: 2 * k), with: .color(Color(hex: 0xF2F0EC)))
        for (dx, dy, r) in [(132.0, 26.0, 9.0), (127.0, 20.0, 7.0), (137.0, 21.0, 7.0), (131.0, 34.0, 6.0)] {
            context.fill(Path(ellipseIn: rect(dx - r, dy - r, r * 2, r * 2)), with: .color(Color(hex: 0x4F7A4A)))
        }
    }

    static let bedroom = WallScene(
        id: "bedroom", name: "Bedroom",
        wall: Color(hex: 0xC9D1D6), floor: Color(hex: 0xD8CBB8),
        posterCenter: (72, 74)
    ) { context, rect, k in
        // Headboard (64 × 50) and queen bed.
        context.fill(Path(roundedRect: rect(40, 0, 64, 50), cornerRadius: 4 * k), with: .color(Color(hex: 0x9AA6AE)))
        context.fill(Path(roundedRect: rect(38, 0, 68, 24), cornerRadius: 3 * k), with: .color(Color(hex: 0xF7F5F1)))  // duvet
        context.fill(Path(roundedRect: rect(38, 14, 68, 6), cornerRadius: 2 * k), with: .color(Color(hex: 0xE2DCD2)))  // fold
        for x in [44.0, 75.0] {                                                                                         // pillows
            context.fill(Path(roundedRect: rect(x, 24, 25, 10), cornerRadius: 4 * k), with: .color(.white))
        }
        // Nightstands with lamps.
        for x in [14.0, 108.0] {
            context.fill(Path(roundedRect: rect(x, 0, 22, 24), cornerRadius: 1.5 * k), with: .color(Color(hex: 0x6F5B4B)))
            context.fill(Path(rect(x + 10, 24, 2, 10)), with: .color(Color(hex: 0x3A3A3A)))
            var shade = Path()
            shade.move(to: rect(x + 4, 34, 0, 0).origin)
            shade.addLine(to: rect(x + 18, 34, 0, 0).origin)
            shade.addLine(to: rect(x + 15, 44, 0, 0).origin)
            shade.addLine(to: rect(x + 7, 44, 0, 0).origin)
            shade.closeSubpath()
            context.fill(shade, with: .color(Color(hex: 0xF3EBDD)))
        }
    }

    static let entryway = WallScene(
        id: "entry", name: "Entryway",
        wall: Color(hex: 0x3E5245), floor: Color(hex: 0x8A8A86),
        posterCenter: (72, 62)
    ) { context, rect, k in
        // Console table 54 × 30 with a vase and books.
        context.fill(Path(roundedRect: rect(45, 28, 54, 3), cornerRadius: 1 * k), with: .color(Color(hex: 0xC8A27A)))
        for x in [47.0, 95.0] { context.fill(Path(rect(x, 0, 2, 28)), with: .color(Color(hex: 0x2B2B2B))) }
        context.fill(Path(rect(47, 8, 50, 1.5)), with: .color(Color(hex: 0x2B2B2B)))
        context.fill(Path(roundedRect: rect(52, 31, 7, 14), cornerRadius: 3 * k), with: .color(Color(hex: 0xE9E4DA)))   // vase
        context.fill(Path(roundedRect: rect(80, 31, 12, 2.5), cornerRadius: 0.5 * k), with: .color(Color(hex: 0xB24A3A))) // books
        context.fill(Path(roundedRect: rect(81, 33.5, 10, 2), cornerRadius: 0.5 * k), with: .color(Color(hex: 0xE8D9B5)))
        // Woven basket under the table.
        context.fill(Path(roundedRect: rect(60, 0, 20, 7), cornerRadius: 2 * k), with: .color(Color(hex: 0xB08B5E)))
    }
}

/// Shows the poster hanging in a room at true size, with the chosen finish.
/// Drawn entirely on the phone; nothing is uploaded.
struct WallPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let session: ArtworkSession

    @State private var sceneID = WallScene.all[0].id
    @State private var finish: WallFinish = .framedBlack
    @State private var withMat = true
    @State private var size: PrintSize = .size24x36
    @State private var image: CGImage?

    private var scene: WallScene { WallScene.all.first { $0.id == sceneID } ?? WallScene.all[0] }
    private var orientation: Orientation { session.artwork.settings.orientation }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    room
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)

                    Text(caption)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)

                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Room")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(WallScene.all) { item in
                                    Button { withAnimation(.snappy) { sceneID = item.id } } label: {
                                        Text(item.name)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(item.id == sceneID ? Theme.background : Theme.primaryText)
                                            .padding(.horizontal, 14)
                                            .frame(height: 36)
                                            .background(item.id == sceneID ? Theme.primaryText : Theme.control, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Size", trailing: "inches")
                        ChipPicker(
                            options: PrintSize.allCases.map { ($0, "\($0.shortInches) × \($0.longInches)") },
                            selection: $size,
                            height: 40
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Finish")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(WallFinish.allCases) { option in
                                    Button { withAnimation(.snappy) { finish = option } } label: {
                                        Text(option.title)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(option == finish ? Theme.background : Theme.primaryText)
                                            .padding(.horizontal, 14)
                                            .frame(height: 36)
                                            .background(option == finish ? Theme.primaryText : Theme.control, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        if finish.frameColor != nil {
                            Toggle("White mat inside the frame", isOn: $withMat.animation(.snappy))
                                .font(.system(size: 15))
                                .tint(Theme.accent)
                                .padding(.top, 4)
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("On the Wall")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.tint(Theme.accent) }
            }
            .task(id: size) { await render() }
        }
    }

    private var caption: String {
        let w = orientation == .landscape ? size.longInches : size.shortInches
        let h = orientation == .landscape ? size.shortInches : size.longInches
        return "\(w) × \(h) in, shown to scale. Colors on screen vary from print."
    }

    // MARK: - Room

    private var room: some View {
        GeometryReader { geometry in
            let k = geometry.size.width / scene.widthInches   // points per inch
            let floorY = geometry.size.height - scene.floorInches * k
            let rect: (Double, Double, Double, Double) -> CGRect = { x, y, w, h in
                CGRect(x: x * k, y: floorY - (y + h) * k, width: w * k, height: h * k)
            }
            ZStack(alignment: .topLeading) {
                Canvas { context, canvasSize in
                    // Wall with soft light from the top.
                    context.fill(Path(CGRect(origin: .zero, size: canvasSize)), with: .color(scene.wall))
                    context.fill(
                        Path(CGRect(x: 0, y: 0, width: canvasSize.width, height: floorY)),
                        with: .linearGradient(
                            Gradient(colors: [.white.opacity(0.18), .clear, .black.opacity(0.08)]),
                            startPoint: .zero, endPoint: CGPoint(x: 0, y: floorY)
                        )
                    )
                    // Floor and baseboard.
                    context.fill(Path(CGRect(x: 0, y: floorY, width: canvasSize.width, height: canvasSize.height - floorY)), with: .color(scene.floor))
                    context.fill(Path(CGRect(x: 0, y: floorY - 4 * k, width: canvasSize.width, height: 4 * k)), with: .color(.white.opacity(0.85)))
                    var furniture = context
                    scene.furniture(&furniture, rect, k)
                }
                hungPoster(k: k)
                    .position(x: scene.posterCenter.x * k, y: floorY - scene.posterCenter.y * k)
            }
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Your poster in a \(scene.name.lowercased()), \(caption)")
    }

    @ViewBuilder
    private func hungPoster(k: CGFloat) -> some View {
        let w = CGFloat(orientation == .landscape ? size.longInches : size.shortInches) * k
        let h = CGFloat(orientation == .landscape ? size.shortInches : size.longInches) * k
        let art = Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.high)
            } else {
                Color.white.overlay(ProgressView())
            }
        }
        .frame(width: w, height: h)

        switch finish {
        case .poster:
            art.shadow(color: .black.opacity(0.25), radius: 2 * k, x: 0, y: 1 * k)
        case .canvas:
            // Gallery wrap: a 1.5 in deep edge catches shadow on the right and bottom.
            art
                .overlay(alignment: .trailing) { LinearGradient(colors: [.clear, .black.opacity(0.18)], startPoint: .leading, endPoint: .trailing).frame(width: 1.5 * k) }
                .overlay(alignment: .bottom) { LinearGradient(colors: [.clear, .black.opacity(0.14)], startPoint: .top, endPoint: .bottom).frame(height: 1.5 * k) }
                .shadow(color: .black.opacity(0.35), radius: 4 * k, x: 1.5 * k, y: 2 * k)
        default:
            let frame = 1.0 * k
            let mat = withMat ? 2.5 * k : 0
            art
                .padding(mat)
                .background(Color(hex: 0xFBFAF7))
                .padding(frame)
                .background(finish.frameColor ?? .black)
                .overlay(Rectangle().strokeBorder(.black.opacity(0.15), lineWidth: max(0.5, 0.15 * k)))
                .shadow(color: .black.opacity(0.35), radius: 3 * k, x: 0, y: 2 * k)
        }
    }

    // MARK: - Rendering

    /// The poster at the size being previewed (grouping depends on size).
    private func render() async {
        guard let report = session.report, let input = session.input else { return }
        var settings = input.settings
        settings.printSize = size
        settings.wallpaper = nil
        let design = input.design
        let title = input.title
        let watermark = input.showWatermark
        let images = session.borderImages
        image = await Task.detached(priority: .userInitiated) {
            let data = report.barcode(for: settings)
            let sized = ArtworkInput(title: title, settings: settings, barcode: data, design: design, showWatermark: watermark)
            return ArtworkRenderer.preview(sized, longEdge: 1400, borderImages: images)
        }.value
    }
}
