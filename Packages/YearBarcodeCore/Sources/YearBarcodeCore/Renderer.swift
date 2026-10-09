import Foundation

/// A small pre-rendered RGB bitmap (label text or a border photo) placed on the poster.
public struct RasterOverlay: Sendable {
    public var rect: PixelRect
    /// Tightly packed 8-bit RGB, `rect.width * 3` bytes per row, already flattened on white.
    public var pixels: [UInt8]

    public init(rect: PixelRect, pixels: [UInt8]) {
        precondition(pixels.count == rect.width * rect.height * 3, "Overlay size mismatch")
        self.rect = rect
        self.pixels = pixels
    }
}

/// Composes the poster one scanline at a time so peak memory stays at a few
/// rows plus the overlays, regardless of the 77-megapixel output size.
public struct ScanlineRenderer: Sendable {
    public let layout: PosterLayout
    public let stripeColors: [RGB8]
    public let overlays: [RasterOverlay]

    public init(layout: PosterLayout, stripeColors: [RGB8], overlays: [RasterOverlay]) {
        self.layout = layout
        self.stripeColors = stripeColors
        self.overlays = overlays.filter {
            PixelRect(x: 0, y: 0, width: layout.canvas.width, height: layout.canvas.height).contains($0.rect)
        }
    }

    public var width: Int { layout.canvas.width }
    public var height: Int { layout.canvas.height }

    /// Calls `body` with each RGB row, top to bottom. The buffer is reused between calls.
    public func renderRows(_ body: (_ y: Int, _ row: UnsafeBufferPointer<UInt8>) throws -> Void) rethrows {
        let rowBytes = width * 3
        var row = [UInt8](repeating: 255, count: rowBytes)
        let whiteRow = row
        let bar = layout.barcode
        let bounds = layout.stripeBoundaries(count: stripeColors.count)

        // Landscape: every barcode row is identical, so build it once.
        var landscapeBarcodeRow: [UInt8] = []
        if layout.orientation == .landscape {
            landscapeBarcodeRow = whiteRow
            for (i, color) in stripeColors.enumerated() {
                fill(&landscapeBarcodeRow, from: bar.x + bounds[i], to: bar.x + bounds[i + 1], color: color)
            }
        }

        // Stripe index lookup for portrait rows.
        var portraitStripe = 0

        for y in 0..<height {
            if y >= bar.y && y < bar.maxY && !stripeColors.isEmpty {
                switch layout.orientation {
                case .landscape:
                    row = landscapeBarcodeRow
                case .portrait:
                    let offset = y - bar.y
                    while portraitStripe + 1 < stripeColors.count && bounds[portraitStripe + 1] <= offset {
                        portraitStripe += 1
                    }
                    row = whiteRow
                    fill(&row, from: bar.x, to: bar.maxX, color: stripeColors[portraitStripe])
                }
            } else {
                row = whiteRow
            }

            for overlay in overlays where y >= overlay.rect.y && y < overlay.rect.maxY {
                let src = (y - overlay.rect.y) * overlay.rect.width * 3
                let dst = overlay.rect.x * 3
                let count = overlay.rect.width * 3
                row.withUnsafeMutableBufferPointer { out in
                    overlay.pixels.withUnsafeBufferPointer { inp in
                        _ = UnsafeMutableRawPointer(out.baseAddress! + dst)
                            .copyMemory(from: inp.baseAddress! + src, byteCount: count)
                    }
                }
            }

            try row.withUnsafeBufferPointer { try body(y, $0) }
        }
    }

    /// Renders into one RGB buffer. Only for small previews.
    public func renderImage() -> [UInt8] {
        var image = [UInt8]()
        image.reserveCapacity(width * height * 3)
        renderRows { _, row in image.append(contentsOf: row) }
        return image
    }

    private func fill(_ row: inout [UInt8], from x0: Int, to x1: Int, color: RGB8) {
        guard x1 > x0 else { return }
        for x in x0..<x1 {
            row[x * 3] = color.r
            row[x * 3 + 1] = color.g
            row[x * 3 + 2] = color.b
        }
    }
}
