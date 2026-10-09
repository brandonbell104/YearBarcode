import Photos
import UIKit
import YearBarcodeCore

enum BorderPhotoError: Error, LocalizedError {
    case unavailable(assetID: String)

    var errorDescription: String? {
        "A border photo is no longer available at full resolution. Choose a replacement."
    }
}

/// Everything needed to draw one artwork. Built from cached analyses; drawing
/// never re-reads source photos except the optional border photos.
struct ArtworkInput: Sendable {
    var year: Int
    var settings: ArtworkSettings
    var barcode: BarcodeData
    var borderPhotos: [BorderPhoto]
    var showWatermark: Bool
}

enum ArtworkRenderer {
    // MARK: Preview

    /// Low-resolution preview from logical color data.
    static func preview(_ input: ArtworkInput, longEdge: Int = 1500, borderImages: [String: UIImage]) -> CGImage? {
        let full = input.settings.printSize.canvas(input.settings.orientation)
        let scale = Double(longEdge) / Double(full.long)
        let canvas = PixelSize(width: Int((Double(full.width) * scale).rounded()), height: Int((Double(full.height) * scale).rounded()))
        let layout = PosterLayout(canvas: canvas, orientation: input.settings.orientation)
        let colors = StripeGeometry.previewColors(input.barcode.stripes, pixels: layout.barcodeLength)
        let overlays = labelOverlays(input, layout: layout)
            + photoOverlays(input.borderPhotos, layout: layout, images: borderImages)
        let renderer = ScanlineRenderer(layout: layout, stripeColors: colors, overlays: overlays)
        return PixelSampler.cgImage(rgb: renderer.renderImage(), width: canvas.width, height: canvas.height)
    }

    // MARK: Export

    /// Streams the full-resolution PNG. Border photos are fetched at the
    /// resolution their slots need; a missing one fails instead of being replaced.
    static func exportPNG(_ input: ArtworkInput, library: PhotoLibraryService, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let layout = PosterLayout(printSize: input.settings.printSize, orientation: input.settings.orientation)
        let slots = layout.photoSlots(count: input.borderPhotos.count)

        var images: [String: UIImage] = [:]
        for (photo, slot) in zip(input.borderPhotos, slots) {
            guard let asset = library.asset(id: photo.assetID) else { throw BorderPhotoError.unavailable(assetID: photo.assetID) }
            let zoom = min(max(photo.zoom, 1), BorderPhoto.maxZoom)
            let target = CGSize(width: Double(slot.width) * zoom * 1.25, height: Double(slot.height) * zoom * 1.25)
            do {
                images[photo.assetID] = try await library.image(for: asset, targetSize: target, contentMode: .aspectFill)
            } catch {
                throw BorderPhotoError.unavailable(assetID: photo.assetID)
            }
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = input.settings.printSize
        let name = "Year-Barcode-\(input.year)-\(size.shortInches)x\(size.longInches)-\(input.settings.orientation.rawValue).png"
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)

        let overlays = labelOverlays(input, layout: layout) + photoOverlays(input.borderPhotos, layout: layout, images: images)
        images.removeAll()
        let colors = input.barcode.stripes.map(\.rgb8)
        try await Task.detached(priority: .userInitiated) {
            let renderer = ScanlineRenderer(layout: layout, stripeColors: colors, overlays: overlays)
            try renderer.writePNG(to: url, progress: progress)
        }.value
        return url
    }

    // MARK: Overlays

    static func labelOverlays(_ input: ArtworkInput, layout: PosterLayout) -> [RasterOverlay] {
        var overlays = [
            text(String(input.year), in: layout.yearLabel, weight: .semibold, color: UIColor(white: 0.12, alpha: 1)),
            text(ArtworkText.photoCount(input.barcode.includedPhotoCount), in: layout.countLabel, weight: .regular, color: UIColor(white: 0.3, alpha: 1)),
        ]
        if input.showWatermark {
            overlays.append(text(PosterLayout.watermarkText, in: layout.watermark, weight: .regular, color: UIColor(white: 0.55, alpha: 1)))
        }
        return overlays
    }

    static func text(_ string: String, in rect: PixelRect, weight: UIFont.Weight, color: UIColor) -> RasterOverlay {
        PixelSampler.overlay(rect: rect) { _, size in
            var font = UIFont.systemFont(ofSize: size.height / 1.25, weight: weight)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph, .kern: font.pointSize * 0.04]
            let measured = (string as NSString).size(withAttributes: attributes)
            if measured.width > size.width {
                font = font.withSize(font.pointSize * size.width / measured.width * 0.95)
                attributes[.font] = font
            }
            let lineHeight = font.lineHeight
            let y = (size.height - lineHeight) / 2
            (string as NSString).draw(in: CGRect(x: 0, y: y, width: size.width, height: lineHeight), withAttributes: attributes)
        }
    }

    static func photoOverlays(_ photos: [BorderPhoto], layout: PosterLayout, images: [String: UIImage]) -> [RasterOverlay] {
        zip(photos, layout.photoSlots(count: photos.count)).compactMap { photo, slot in
            guard let image = images[photo.assetID] else { return nil }
            return PixelSampler.overlay(rect: slot) { _, size in
                let crop = photo.cropRect(imageWidth: image.size.width, imageHeight: image.size.height, slotAspect: size.width / size.height)
                let scale = size.width / crop.width
                image.draw(in: CGRect(x: -crop.x * scale, y: -crop.y * scale, width: image.size.width * scale, height: image.size.height * scale))
            }
        }
    }
}
