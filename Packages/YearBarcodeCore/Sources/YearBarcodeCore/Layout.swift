import Foundation

public struct PixelSize: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var long: Int { max(width, height) }
    public var short: Int { min(width, height) }
}

public struct PixelRect: Codable, Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }

    public func intersects(_ other: PixelRect) -> Bool {
        x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }

    public func contains(_ other: PixelRect) -> Bool {
        other.x >= x && other.y >= y && other.maxX <= maxX && other.maxY <= maxY
    }
}

/// Poster geometry. Everything scales with the canvas, so the same layout
/// drives a small on-screen preview and the 300-PPI export.
///
/// V1 constants (proposed, not printing standards): the barcode covers 90% of
/// the long side and 75% of the short side, centered.
public struct PosterLayout: Hashable, Sendable {
    public static let maxBorderPhotos = 4
    public static let watermarkText = "Made with Year Barcode"

    public let canvas: PixelSize
    public let orientation: Orientation
    public let barcode: PixelRect
    public let yearLabel: PixelRect
    public let countLabel: PixelRect
    public let watermark: PixelRect

    /// Distance along which stripes are laid out (width in landscape, height in portrait).
    public var barcodeLength: Int { orientation == .landscape ? barcode.width : barcode.height }

    /// floor(barcode length / 2): keeps every stripe at least two pixels thick.
    public var maxGroups: Int { barcodeLength / 2 }

    public init(printSize: PrintSize, orientation: Orientation) {
        self.init(canvas: printSize.canvas(orientation), orientation: orientation)
    }

    public init(canvas: PixelSize, orientation: Orientation) {
        self.canvas = canvas
        self.orientation = orientation
        let long = canvas.long
        let short = canvas.short
        let length = long * 9 / 10
        let thickness = short * 3 / 4
        let u = Double(short) / 100 // layout unit

        func px(_ value: Double) -> Int { Int(value.rounded()) }

        let barcode: PixelRect
        switch orientation {
        case .landscape:
            barcode = PixelRect(x: (canvas.width - length) / 2, y: (canvas.height - thickness) / 2, width: length, height: thickness)
        case .portrait:
            barcode = PixelRect(x: (canvas.width - thickness) / 2, y: (canvas.height - length) / 2, width: thickness, height: length)
        }
        self.barcode = barcode

        // Year: centered in the top border.
        let topBorder = barcode.y
        let yearHeight = px(Double(topBorder) * 0.42)
        yearLabel = PixelRect(x: barcode.x, y: (topBorder - yearHeight) / 2, width: barcode.width, height: yearHeight)

        // Watermark: a small line directly below the barcode.
        watermark = PixelRect(x: barcode.x, y: barcode.maxY + px(0.6 * u), width: barcode.width, height: px(1.2 * u))

        // Included photo count: the bottom of the lower border.
        let countHeight = px(2.0 * u)
        countLabel = PixelRect(x: barcode.x, y: canvas.height - px(1.0 * u) - countHeight, width: barcode.width, height: countHeight)
    }

    /// Slots for optional border photos. Landscape: one centered row in the
    /// lower border between the watermark and count. Portrait: stacked in the
    /// wider side borders, alternating left and right.
    public func photoSlots(count: Int) -> [PixelRect] {
        let count = min(max(count, 0), Self.maxBorderPhotos)
        guard count > 0 else { return [] }
        let u = Double(canvas.short) / 100
        func px(_ value: Double) -> Int { Int(value.rounded()) }

        switch orientation {
        case .landscape:
            let top = watermark.maxY + px(0.7 * u)
            let bottom = countLabel.y - px(0.7 * u)
            let height = bottom - top
            let width = height * 4 / 3
            let gap = px(1.2 * u)
            let total = count * width + (count - 1) * gap
            let x0 = (canvas.width - total) / 2
            return (0..<count).map { PixelRect(x: x0 + $0 * (width + gap), y: top, width: width, height: height) }

        case .portrait:
            let sideWidth = barcode.x
            let margin = px(1.75 * u)
            let width = sideWidth - 2 * margin
            let height = width * 5 / 4
            let gap = px(1.5 * u)
            let centerY = barcode.y + barcode.height / 2
            var slots: [PixelRect] = []
            for index in 0..<count {
                let isLeft = index % 2 == 0
                let perSide = isLeft ? (count + 1) / 2 : count / 2
                let position = index / 2
                let stack = perSide * height + (perSide - 1) * gap
                let y = centerY - stack / 2 + position * (height + gap)
                let x = isLeft ? margin : barcode.maxX + margin
                slots.append(PixelRect(x: x, y: y, width: width, height: height))
            }
            return slots
        }
    }

    /// Pixel extent of stripe `index` along the barcode, relative to the barcode origin.
    public func stripeBoundaries(count: Int) -> [Int] {
        StripeGeometry.boundaries(count: count, length: barcodeLength)
    }
}
