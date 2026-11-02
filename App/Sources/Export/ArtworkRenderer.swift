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

    static func previewCanvas(for settings: ArtworkSettings, longEdge: Int = 1500) -> PixelSize {
        let full = settings.printSize.canvas(settings.orientation)
        let scale = Double(longEdge) / Double(full.long)
        return PixelSize(width: Int((Double(full.width) * scale).rounded()), height: Int((Double(full.height) * scale).rounded()))
    }

    /// Low-resolution preview from logical color data. `includePhotos: false`
    /// leaves the border photos out (the arrange editor draws them live on top).
    static func preview(_ input: ArtworkInput, longEdge: Int = 1500, borderImages: [String: UIImage], includePhotos: Bool = true) -> CGImage? {
        let canvas = previewCanvas(for: input.settings, longEdge: longEdge)
        let layout = PosterLayout(canvas: canvas, orientation: input.settings.orientation)
        let colors = StripeGeometry.previewColors(input.barcode.stripes, pixels: layout.barcodeLength)
        var overlays = labelOverlays(input, layout: layout)
        if includePhotos { overlays += photoOverlays(input.borderPhotos, layout: layout, images: borderImages) }
        overlays += watermarkOverlays(input, layout: layout)
        let renderer = ScanlineRenderer(layout: layout, stripeColors: colors, overlays: overlays, background: input.settings.background)
        return PixelSampler.cgImage(rgb: renderer.renderImage(), width: canvas.width, height: canvas.height)
    }

    // MARK: Export

    /// Streams the full-resolution PNG. Border photos are fetched at the
    /// resolution their frames need; a missing one fails instead of being replaced.
    static func exportPNG(_ input: ArtworkInput, library: PhotoLibraryService, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let layout = PosterLayout(printSize: input.settings.printSize, orientation: input.settings.orientation)

        var images: [String: UIImage] = [:]
        for (index, photo) in input.borderPhotos.enumerated() {
            guard let asset = library.asset(id: photo.assetID) else { throw BorderPhotoError.unavailable(assetID: photo.assetID) }
            let frame = layout.frame(for: layout.resolvedPlacement(for: photo, index: index, count: input.borderPhotos.count))
            let zoom = min(max(photo.zoom, 1), BorderPhoto.maxZoom)
            let target = CGSize(width: frame.width * zoom * 1.25, height: frame.height * zoom * 1.25)
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

        // Order matters: photos cover the barcode and labels, the watermark stays on top.
        let overlays = labelOverlays(input, layout: layout)
            + photoOverlays(input.borderPhotos, layout: layout, images: images)
            + watermarkOverlays(input, layout: layout)
        images.removeAll()
        let colors = input.barcode.stripes.map(\.rgb8)
        let background = input.settings.background
        try await Task.detached(priority: .userInitiated) {
            let renderer = ScanlineRenderer(layout: layout, stripeColors: colors, overlays: overlays, background: background)
            try renderer.writePNG(to: url, progress: progress)
        }.value
        return url
    }

    // MARK: Overlays

    /// Year and count, in dark or light text depending on the background.
    static func labelOverlays(_ input: ArtworkInput, layout: PosterLayout) -> [RasterOverlay] {
        let background = input.settings.background
        let light = background.prefersLightText
        let primary = light ? UIColor(white: 0.95, alpha: 1) : UIColor(white: 0.12, alpha: 1)
        let secondary = light ? UIColor(white: 0.8, alpha: 1) : UIColor(white: 0.3, alpha: 1)
        return [
            text(String(input.year), in: layout.yearLabel, weight: .semibold, color: primary, background: background),
            text(ArtworkText.photoCount(input.barcode.includedPhotoCount), in: layout.countLabel, weight: .regular, color: secondary, background: background),
        ]
    }

    /// Drawn last, above any border photo, so photos can't hide it.
    static func watermarkOverlays(_ input: ArtworkInput, layout: PosterLayout) -> [RasterOverlay] {
        guard input.showWatermark else { return [] }
        let background = input.settings.background
        let color = background.prefersLightText ? UIColor(white: 0.65, alpha: 1) : UIColor(white: 0.55, alpha: 1)
        return [text(PosterLayout.watermarkText, in: layout.watermark, weight: .regular, color: color, background: background)]
    }

    static func text(_ string: String, in rect: PixelRect, weight: UIFont.Weight, color: UIColor, background: RGB8) -> RasterOverlay {
        PixelSampler.overlay(rect: rect, background: background) { _, size in
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

    /// Border photos at their (possibly rotated) placements. Each overlay is the
    /// photo's bounding box with transparent corners, so photos can overlap each
    /// other, the barcode and the labels. Anything past the poster edge is cropped.
    static func photoOverlays(_ photos: [BorderPhoto], layout: PosterLayout, images: [String: UIImage]) -> [RasterOverlay] {
        let canvas = PixelRect(x: 0, y: 0, width: layout.canvas.width, height: layout.canvas.height)
        return photos.enumerated().compactMap { index, photo in
            guard let image = images[photo.assetID] else { return nil }
            let frame = layout.frame(for: layout.resolvedPlacement(for: photo, index: index, count: photos.count))
            let box = clamp(frame.boundingBox, to: canvas)
            guard box.width > 0, box.height > 0 else { return nil }
            return PixelSampler.transparentOverlay(rect: box) { context, _ in
                context.translateBy(x: frame.centerX - Double(box.x), y: frame.centerY - Double(box.y))
                context.rotate(by: frame.rotation)
                let target = CGRect(x: -frame.width / 2, y: -frame.height / 2, width: frame.width, height: frame.height)
                context.clip(to: target)
                drawCropped(image, photo: photo, in: target)
            }
        }
    }

    /// Draws `image` cropped per the photo's zoom/center to fill `target`.
    static func drawCropped(_ image: UIImage, photo: BorderPhoto, in target: CGRect) {
        let crop = photo.cropRect(imageWidth: image.size.width, imageHeight: image.size.height, slotAspect: target.width / target.height)
        let scale = target.width / crop.width
        image.draw(in: CGRect(
            x: target.minX - crop.x * scale,
            y: target.minY - crop.y * scale,
            width: image.size.width * scale,
            height: image.size.height * scale
        ))
    }

    /// The cropped photo as its own image (for on-screen editing).
    static func croppedImage(_ image: UIImage, photo: BorderPhoto, aspect: Double, longEdge: CGFloat = 600) -> UIImage {
        let size = aspect >= 1
            ? CGSize(width: longEdge, height: longEdge / aspect)
            : CGSize(width: longEdge * aspect, height: longEdge)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            drawCropped(image, photo: photo, in: CGRect(origin: .zero, size: size))
        }
    }

    private static func clamp(_ rect: PixelRect, to bounds: PixelRect) -> PixelRect {
        let x0 = max(rect.x, bounds.x), y0 = max(rect.y, bounds.y)
        let x1 = min(rect.maxX, bounds.maxX), y1 = min(rect.maxY, bounds.maxY)
        return PixelRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }
}
