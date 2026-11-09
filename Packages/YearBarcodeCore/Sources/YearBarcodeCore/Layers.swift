import Foundation

/// Fonts offered for text layers. The platform maps each to a real font.
public enum FontStyle: String, Codable, CaseIterable, Sendable {
    case system
    case rounded
    case serif
    case mono
    case avenir
    case futura
    case georgia
    case didot
    case typewriter
    case marker
    case script

    public var title: String {
        switch self {
        case .system: return "System"
        case .rounded: return "Rounded"
        case .serif: return "Serif"
        case .mono: return "Mono"
        case .avenir: return "Avenir"
        case .futura: return "Futura"
        case .georgia: return "Georgia"
        case .didot: return "Didot"
        case .typewriter: return "Typewriter"
        case .marker: return "Marker"
        case .script: return "Script"
        }
    }
}

/// Where a text layer sits: center as fractions of the poster, plus rotation.
public struct TextPosition: Codable, Hashable, Sendable {
    public var centerX: Double
    public var centerY: Double
    /// Clockwise rotation in radians.
    public var rotation: Double

    public init(centerX: Double, centerY: Double, rotation: Double = 0) {
        self.centerX = centerX
        self.centerY = centerY
        self.rotation = rotation
    }
}

/// A block of text on the poster. The year and photo count are text layers
/// too, so they can be moved, resized, restyled, edited or deleted.
public struct TextLayer: Codable, Hashable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable {
        case custom
        case year
        case photoCount
    }

    public var id: String
    public var role: Role
    /// Nil keeps the automatic text (the year, or "7,842 photos").
    public var text: String?
    public var font: FontStyle
    public var bold: Bool
    /// Nil picks dark or light automatically for the background.
    public var color: RGB8?
    /// Font size as a fraction of the poster's short side. Nil uses the role's default.
    public var size: Double?
    /// Nil uses the role's default spot.
    public var position: TextPosition?

    public init(
        id: String = UUID().uuidString,
        role: Role,
        text: String? = nil,
        font: FontStyle = .system,
        bold: Bool = false,
        color: RGB8? = nil,
        size: Double? = nil,
        position: TextPosition? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.font = font
        self.bold = bold
        self.color = color
        self.size = size
        self.position = position
    }

    public static let minSize = 0.005
    public static let maxSize = 0.3

    public func displayText(year: Int, includedPhotos: Int, locale: Locale = .current) -> String {
        displayText(title: String(year), includedPhotos: includedPhotos, locale: locale)
    }

    /// - Parameter title: what the poster covers ("2025" or a custom timeline).
    public func displayText(title: String, includedPhotos: Int, locale: Locale = .current) -> String {
        if let text { return text }
        switch role {
        case .year: return title
        case .photoCount: return ArtworkText.photoCount(includedPhotos, locale: locale)
        case .custom: return ""
        }
    }
}

/// One item on the poster, drawn bottom to top in `PosterDesign.layers` order.
public enum PosterLayer: Codable, Hashable, Identifiable, Sendable {
    case photo(BorderPhoto)
    case text(TextLayer)

    public var id: String {
        switch self {
        case .photo(let photo): return "photo:" + photo.assetID
        case .text(let text): return "text:" + text.id
        }
    }
}

/// Everything the user placed on the poster besides the barcode and the watermark.
public struct PosterDesign: Codable, Hashable, Sendable {
    /// Bottom to top.
    public var layers: [PosterLayer]

    public init(layers: [PosterLayer]) {
        self.layers = layers
    }

    /// Plenty for a poster while keeping the full-size export within memory.
    public static let maxPhotos = 20

    /// The year and photo count in their usual places, with photos above them.
    public static func standard(photos: [BorderPhoto] = []) -> PosterDesign {
        PosterDesign(layers: [
            .text(TextLayer(id: "year", role: .year, bold: true)),
            .text(TextLayer(id: "count", role: .photoCount)),
        ] + photos.map { .photo($0) })
    }

    public var photos: [BorderPhoto] {
        layers.compactMap { if case .photo(let photo) = $0 { return photo } else { return nil } }
    }

    /// Reads a saved design. Designs saved before layers existed were a plain
    /// list of photos; they become the standard design with those photos.
    public static func decode(_ data: Data) -> PosterDesign {
        let decoder = JSONDecoder()
        if let design = try? decoder.decode(PosterDesign.self, from: data) { return design }
        if let photos = try? decoder.decode([BorderPhoto].self, from: data) { return .standard(photos: photos) }
        return .standard()
    }

    /// Index among photos only (used for default slots).
    public func photoIndex(of assetID: String) -> Int? {
        photos.firstIndex { $0.assetID == assetID }
    }

    public mutating func move(from index: Int, to destination: Int) {
        guard layers.indices.contains(index), layers.indices.contains(destination), index != destination else { return }
        let layer = layers.remove(at: index)
        layers.insert(layer, at: destination)
    }
}

extension PosterLayout {
    public func defaultTextSize(for role: TextLayer.Role) -> Double {
        let rect: PixelRect
        switch role {
        case .year: rect = yearLabel
        case .photoCount: rect = countLabel
        case .custom: return 0.04
        }
        return Double(rect.height) / 1.25 / Double(canvas.short)
    }

    public func defaultTextPosition(for role: TextLayer.Role) -> TextPosition {
        let rect: PixelRect
        switch role {
        case .year: rect = yearLabel
        case .photoCount: rect = countLabel
        case .custom: return TextPosition(centerX: 0.5, centerY: 0.5)
        }
        return TextPosition(
            centerX: (Double(rect.x) + Double(rect.width) / 2) / Double(canvas.width),
            centerY: (Double(rect.y) + Double(rect.height) / 2) / Double(canvas.height)
        )
    }

    /// Font size in poster pixels.
    public func fontSize(for text: TextLayer) -> Double {
        let size = min(max(text.size ?? defaultTextSize(for: text.role), TextLayer.minSize), TextLayer.maxSize)
        return size * Double(canvas.short)
    }

    public func position(for text: TextLayer) -> TextPosition {
        if let position = text.position, (0...1).contains(position.centerX), (0...1).contains(position.centerY) {
            return position
        }
        return defaultTextPosition(for: text.role)
    }
}
