import CZlib
import XCTest
@testable import YearBarcodeCore

final class RenderTests: XCTestCase {
    func testLayoutElementsNeverOverlapInEitherOrientation() {
        for size in PrintSize.allCases {
            for orientation in Orientation.allCases {
                let layout = PosterLayout(printSize: size, orientation: orientation)
                let canvas = PixelRect(x: 0, y: 0, width: layout.canvas.width, height: layout.canvas.height)
                for photoCount in 0...PosterLayout.maxBorderPhotos {
                    let rects = [layout.barcode, layout.yearLabel, layout.watermark, layout.countLabel] + layout.photoSlots(count: photoCount)
                    for (i, a) in rects.enumerated() {
                        XCTAssertTrue(canvas.contains(a), "\(size) \(orientation) rect \(i) off canvas")
                        XCTAssertGreaterThan(a.width, 0)
                        XCTAssertGreaterThan(a.height, 0)
                        for b in rects[(i + 1)...] {
                            XCTAssertFalse(a.intersects(b), "\(size) \(orientation) \(photoCount) photos: \(a) overlaps \(b)")
                        }
                    }
                }
                XCTAssertLessThan(layout.yearLabel.maxY, layout.barcode.y, "Year sits in the top border")
                XCTAssertGreaterThan(layout.countLabel.y, layout.barcode.maxY, "Count sits in the lower border")
                XCTAssertGreaterThan(layout.watermark.y, layout.barcode.maxY)
                XCTAssertLessThan(layout.watermark.maxY, layout.countLabel.y)
            }
        }
    }

    func testLandscapeStripesRunLeftToRightAndPortraitTopToBottom() {
        let colors = [RGB8(r: 255, g: 0, b: 0), RGB8(r: 0, g: 255, b: 0), RGB8(r: 0, g: 0, b: 255)]
        for orientation in Orientation.allCases {
            let canvas = orientation == .landscape ? PixelSize(width: 300, height: 200) : PixelSize(width: 200, height: 300)
            let layout = PosterLayout(canvas: canvas, orientation: orientation)
            let renderer = ScanlineRenderer(layout: layout, stripeColors: colors, overlays: [])
            let image = renderer.renderImage()
            func pixel(_ x: Int, _ y: Int) -> RGB8 {
                let i = (y * canvas.width + x) * 3
                return RGB8(r: image[i], g: image[i + 1], b: image[i + 2])
            }
            let bar = layout.barcode
            XCTAssertEqual(pixel(0, 0), .white, "Border is white")
            switch orientation {
            case .landscape:
                XCTAssertEqual(pixel(bar.x + 1, bar.y + 5), colors[0], "Oldest at left")
                XCTAssertEqual(pixel(bar.maxX - 2, bar.y + 5), colors[2])
            case .portrait:
                XCTAssertEqual(pixel(bar.x + 5, bar.y + 1), colors[0], "Oldest at top")
                XCTAssertEqual(pixel(bar.x + 5, bar.maxY - 2), colors[2])
            }
        }
    }

    func testStreamingPNGRoundTripsWithMetadata() throws {
        let layout = PosterLayout(canvas: PixelSize(width: 240, height: 160), orientation: .landscape)
        let overlayRect = layout.yearLabel
        let overlay = RasterOverlay(rect: overlayRect, pixels: (0..<(overlayRect.width * overlayRect.height * 3)).map { UInt8($0 % 251) })
        let colors = (0..<50).map { RGB8(r: UInt8($0 * 5), g: UInt8(255 - $0 * 5), b: 128) }
        let renderer = ScanlineRenderer(layout: layout, stripeColors: colors, overlays: [overlay])

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yb-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try renderer.writePNG(to: url)

        let bytes = [UInt8](try Data(contentsOf: url))
        XCTAssertEqual(Array(bytes[0..<8]), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        var offset = 8
        var chunks: [(String, [UInt8])] = []
        while offset < bytes.count {
            let length = Int(be32(bytes, offset))
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            let data = Array(bytes[(offset + 8)..<(offset + 8 + length)])
            let storedCRC = be32(bytes, offset + 8 + length)
            let segment = Array(bytes[(offset + 4)..<(offset + 8 + length)])
            let computed = segment.withUnsafeBufferPointer { UInt32(crc32(0, $0.baseAddress, uInt($0.count))) }
            XCTAssertEqual(storedCRC, computed, "CRC mismatch in \(type)")
            chunks.append((type, data))
            offset += 12 + length
        }
        XCTAssertEqual(chunks.first?.0, "IHDR")
        XCTAssertEqual(chunks.last?.0, "IEND")
        let types = chunks.map(\.0)
        XCTAssertTrue(types.contains("sRGB"))
        XCTAssertFalse(types.contains("eXIf"))
        XCTAssertFalse(types.contains("tEXt"))

        let ihdr = chunks[0].1
        XCTAssertEqual(be32(ihdr, 0), 240)
        XCTAssertEqual(be32(ihdr, 4), 160)
        XCTAssertEqual(ihdr[8], 8)
        XCTAssertEqual(ihdr[9], 2, "Opaque RGB")

        let phys = chunks.first { $0.0 == "pHYs" }!.1
        XCTAssertEqual(be32(phys, 0), 11811, "300 PPI")
        XCTAssertEqual(phys[8], 1)

        // Inflate IDAT and undo the Up filter; must equal the renderer output.
        let compressed = chunks.filter { $0.0 == "IDAT" }.flatMap(\.1)
        let rowBytes = 240 * 3
        let raw = try inflate(compressed, expected: (rowBytes + 1) * 160)
        var previous = [UInt8](repeating: 0, count: rowBytes)
        var decoded: [UInt8] = []
        for y in 0..<160 {
            let start = y * (rowBytes + 1)
            XCTAssertEqual(raw[start], 2)
            var row = [UInt8](repeating: 0, count: rowBytes)
            for i in 0..<rowBytes { row[i] = raw[start + 1 + i] &+ previous[i] }
            decoded += row
            previous = row
        }
        XCTAssertEqual(decoded, renderer.renderImage())
    }

    private func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    private func inflate(_ input: [UInt8], expected: Int) throws -> [UInt8] {
        var stream = z_stream()
        XCTAssertEqual(inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)), Z_OK)
        defer { inflateEnd(&stream) }
        var input = input
        var output = [UInt8](repeating: 0, count: expected + 16)
        let status: Int32 = input.withUnsafeMutableBufferPointer { inp in
            output.withUnsafeMutableBufferPointer { out in
                stream.next_in = inp.baseAddress
                stream.avail_in = uInt(inp.count)
                stream.next_out = out.baseAddress
                stream.avail_out = uInt(out.count)
                return CZlib.inflate(&stream, Z_FINISH)
            }
        }
        XCTAssertEqual(status, Z_STREAM_END)
        XCTAssertEqual(Int(stream.total_out), expected)
        return Array(output.prefix(expected))
    }
}
