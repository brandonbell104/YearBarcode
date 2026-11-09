import XCTest
@testable import YearBarcodeCore

final class ProfileTests: XCTestCase {
    /// A 4×4 "photo": blue sky on top, sand below.
    private func skyOverSand() -> [UInt8] {
        var pixels: [UInt8] = []
        for y in 0..<4 {
            for _ in 0..<4 {
                pixels += y < 2 ? [40, 90, 220, 255] : [210, 180, 120, 255]
            }
        }
        return pixels
    }

    func testProfileKeepsTopToBottomColors() {
        let pixels = skyOverSand()
        let profile = pixels.withUnsafeBufferPointer {
            ColorProfile.compute(pixels: $0, width: 4, height: 4, bytesPerRow: 16)
        }
        XCTAssertEqual(profile.rows.count, 4)
        XCTAssertEqual(profile.rows[0], RGB8(r: 40, g: 90, b: 220), "Top row is sky")
        XCTAssertEqual(profile.rows[3], RGB8(r: 210, g: 180, b: 120), "Bottom row is sand")
        // Every column holds the same half-and-half mix.
        XCTAssertEqual(Set(profile.columns).count, 1)
    }

    func testSamplingInterpolatesAlongTheStripe() {
        let profile = [RGB8(r: 0, g: 0, b: 0), RGB8(r: 200, g: 100, b: 50)]
        XCTAssertEqual(ColorProfile.sample(profile, at: 0), profile[0])
        XCTAssertEqual(ColorProfile.sample(profile, at: 1), profile[1])
        XCTAssertEqual(ColorProfile.sample(profile, at: 0.5), RGB8(r: 100, g: 50, b: 25))
    }

    func testGroupsAverageProfilesWithEqualWeight() {
        let calendar = YearCalendar(timeZone: TimeZone(identifier: "UTC")!)
        let day = calendar.dayKey(for: calendar.startOfYear(2025))
        let black = [RGB8](repeating: .black, count: 4)
        let white = [RGB8](repeating: .white, count: 4)
        let photos = [
            IncludedPhoto(assetID: "a", captureDate: calendar.startOfYear(2025), day: day, color: LinearRGB(r: 0, g: 0, b: 0), rows: black, columns: black),
            IncludedPhoto(assetID: "b", captureDate: calendar.startOfYear(2025).addingTimeInterval(1), day: day, color: .white, rows: white, columns: white),
        ]
        let stripe = Stripe(photos: photos)
        XCTAssertEqual(stripe.rows?.count, 2)
        // Linear 0.5 encodes to 188, the same rule as solid colors.
        XCTAssertEqual(stripe.profile(for: .landscape)?.first, RGB8(r: 188, g: 188, b: 188))

        // One photo without a profile means the stripe falls back to solid.
        var mixed = photos
        mixed[1].rows = nil
        XCTAssertNil(Stripe(photos: mixed).rows)

        let day1 = Grouper.everyDay(photos)
        XCTAssertNotNil(day1.first?.rows)
    }

    func testRendererPaintsProfilesAlongStripes() {
        let red = RGB8(r: 255, g: 0, b: 0), blue = RGB8(r: 0, g: 0, b: 255)
        for orientation in Orientation.allCases {
            let canvas = orientation == .landscape ? PixelSize(width: 300, height: 200) : PixelSize(width: 200, height: 300)
            let layout = PosterLayout(canvas: canvas, orientation: orientation)
            let renderer = ScanlineRenderer(
                layout: layout,
                stripeColors: [.white, .white],
                overlays: [],
                stripeProfiles: [[red, blue], []]
            )
            let image = renderer.renderImage()
            func pixel(_ x: Int, _ y: Int) -> RGB8 {
                let i = (y * canvas.width + x) * 3
                return RGB8(r: image[i], g: image[i + 1], b: image[i + 2])
            }
            let bar = layout.barcode
            switch orientation {
            case .landscape:
                XCTAssertEqual(pixel(bar.x + 2, bar.y + 1), red, "Top of the first stripe")
                XCTAssertEqual(pixel(bar.x + 2, bar.maxY - 2), blue, "Bottom of the first stripe")
                XCTAssertEqual(pixel(bar.maxX - 2, bar.y + 1), .white, "Second stripe has no profile: solid")
            case .portrait:
                XCTAssertEqual(pixel(bar.x + 1, bar.y + 2), red, "Left of the first stripe")
                XCTAssertEqual(pixel(bar.maxX - 2, bar.y + 2), blue, "Right of the first stripe")
                XCTAssertEqual(pixel(bar.x + 1, bar.maxY - 2), .white)
            }
        }
    }

    func testSettingsWithoutStyleDecodeAsSolid() throws {
        let legacy = Data(#"{"mode":"everyPhoto","printSize":"size24x36","orientation":"landscape"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ArtworkSettings.self, from: legacy).stripeStyle, .solid)
    }

    func testPreviewProfilesDownsample() {
        let a = Stripe(sum: nil, rows: ProfileSum([RGB8](repeating: .black, count: 2)), columns: ProfileSum([RGB8](repeating: .black, count: 2)))
        let b = Stripe(sum: nil, rows: ProfileSum([RGB8](repeating: .white, count: 2)), columns: ProfileSum([RGB8](repeating: .white, count: 2)))
        let previews = StripeGeometry.previewProfiles([a, b, a, b], pixels: 2, orientation: .landscape)
        XCTAssertEqual(previews.count, 2)
        XCTAssertEqual(previews[0], [RGB8(r: 188, g: 188, b: 188), RGB8(r: 188, g: 188, b: 188)])
        XCTAssertTrue(StripeGeometry.previewProfiles([Stripe(sum: nil)], pixels: 2, orientation: .landscape).isEmpty)
    }
}

final class FormatTests: XCTestCase {
    func testBorderlessBarcodeFillsTheCanvas() {
        for orientation in Orientation.allCases {
            let settings = ArtworkSettings(printSize: .size18x24, orientation: orientation, borderless: true)
            let layout = PosterLayout(settings: settings)
            let canvas = settings.canvas
            XCTAssertEqual(layout.barcode, PixelRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
            XCTAssertEqual(layout.maxGroups, canvas.long / 2, "Edge to edge: more room for stripes")
            // Labels and default photo slots stay where the framed poster has them.
            let framed = PosterLayout(printSize: .size18x24, orientation: orientation)
            XCTAssertEqual(layout.yearLabel, framed.yearLabel)
            XCTAssertEqual(layout.photoSlots(count: 2), framed.photoSlots(count: 2))
            // The watermark is a short line inside the poster.
            XCTAssertTrue(PixelRect(x: 0, y: 0, width: canvas.width, height: canvas.height).contains(layout.watermark))
            XCTAssertLessThan(layout.watermark.width, canvas.width / 2)
        }
    }

    func testWallpaperCanvasMatchesThePhone() {
        var settings = ArtworkSettings(orientation: .portrait, wallpaper: PixelSize(width: 1179, height: 2556))
        XCTAssertEqual(settings.canvas, PixelSize(width: 1179, height: 2556))
        XCTAssertEqual(settings.sizeTitle, "Wallpaper")
        settings.orientation = .landscape
        XCTAssertEqual(settings.canvas, PixelSize(width: 2556, height: 1179))

        let layout = PosterLayout(settings: ArtworkSettings(orientation: .portrait, wallpaper: PixelSize(width: 750, height: 1334)))
        XCTAssertGreaterThan(layout.maxGroups, 366, "Even a small phone fits one stripe per day")

        let legacy = Data(#"{"mode":"everyPhoto","printSize":"size24x36","orientation":"landscape"}"#.utf8)
        let decoded = try! JSONDecoder().decode(ArtworkSettings.self, from: legacy)
        XCTAssertFalse(decoded.borderless)
        XCTAssertNil(decoded.wallpaper)
        XCTAssertEqual(decoded.sizeTitle, "24 × 36")
    }

    func testBorderlessRenderHasNoBackgroundAtTheEdges() {
        let settings = ArtworkSettings(orientation: .landscape, background: RGB8(r: 10, g: 20, b: 30), borderless: true)
        let layout = PosterLayout(settings: settings, canvas: PixelSize(width: 300, height: 200))
        let red = RGB8(r: 255, g: 0, b: 0)
        let image = ScanlineRenderer(layout: layout, stripeColors: [red], overlays: [], background: settings.background).renderImage()
        XCTAssertEqual(Array(image[0..<3]), [255, 0, 0], "Top-left corner is barcode, not border")
        XCTAssertEqual(Array(image[(image.count - 3)...]), [255, 0, 0])
    }
}
