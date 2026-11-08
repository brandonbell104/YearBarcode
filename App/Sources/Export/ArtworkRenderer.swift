import Photos
import UIKit
import YearBarcodeCore

enum BorderPhotoError: Error, LocalizedError {
    case unavailable(assetID: String)

    var errorDescription: String? {
        "A photo on the poster is no longer available at full resolution. Choose a replacement."
    }
}

/// Everything needed to draw one artwork. Built from cached analyses; drawing
/// never re-reads source photos except the photos placed on the poster.
struct ArtworkInput: Sendable {
    var year: Int
    var settings: ArtworkSettings
    var barcode: BarcodeData
    var design: PosterDesign
    var showWatermark: Bool
}

enum ArtworkRenderer {
    // MARK: Preview

    static func previewCanvas(for settings: ArtworkSettings, longEdge: Int = 1500) -> PixelSize {
        let full = settings.printSize.canvas(settings.orientation)
        let scale = Double(longEdge) / Double(full.long)
        return PixelSize(width: Int((Double(full.width) * scale).rounded()), height: Int((Double(full.height) * scale).rounded()))
    }

    /// Low-resolution preview from logical color data. `includeLayers: false`
    /// draws only the barcode and background (the layout editor draws layers live on top).
    static func preview(_ input: ArtworkInput, longEdge: Int = 1500, borderImages: [String: UIImage], includeLayers: Bool = true) -> CGImage? {
        let canvas = previewCanvas(for: input.settings, longEdge: longEdge)
        let layout = PosterLayout(canvas: canvas, orientation: input.settings.orientation)
        let colors = StripeGeometry.previewColors(input.barcode.stripes, pixels: layout.barcodeLength)
        let profiles = input.settings.stripeStyle == .squeezed
            ? StripeGeometry.previewProfiles(input.barcode.stripes, pixels: layout.barcodeLength, orientation: input.settings.orientation)
            : []
        var overlays: [RasterOverlay] = []
        if includeLayers { overlays += layerOverlays(input, layout: layout, images: borderImages) }
        overlays += watermarkOverlays(input, layout: layout)
        let renderer = ScanlineRenderer(layout: layout, stripeColors: colors, overlays: overlays, background: input.settings.background, stripeProfiles: profiles)
        return PixelSampler.cgImage(rgb: renderer.renderImage(), width: canvas.width, height: canvas.height)
    }

    // MARK: Export

    /// Streams the full-resolution PNG. Photos are fetched at the resolution
    /// their frames need; a missing one fails instead of being replaced.
    static func exportPNG(_ input: ArtworkInput, library: PhotoLibraryService, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let layout = PosterLayout(printSize: input.settings.printSize, orientation: input.settings.orientation)
        let photos = input.design.photos

        var images: [String: UIImage] = [:]
        for (index, photo) in photos.enumerated() {
            guard let asset = library.asset(id: photo.assetID) else { throw BorderPhotoError.unavailable(assetID: photo.assetID) }
            let frame = layout.frame(for: photo, index: index, count: photos.count)
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

        // Layers in stack order; the watermark always stays on top.
        let overlays = layerOverlays(input, layout: layout, images: images) + watermarkOverlays(input, layout: layout)
        images.removeAll()
        let colors = input.barcode.stripes.map(\.rgb8)
        let background = input.settings.background
        let orientation = input.settings.orientation
        let profiles: [[RGB8]] = input.settings.stripeStyle == .squeezed
            ? input.barcode.stripes.map { $0.profile(for: orientation) ?? [] }
            : []
        try await Task.detached(priority: .userInitiated) {
            let renderer = ScanlineRenderer(layout: layout, stripeColors: colors, overlays: overlays, background: background, stripeProfiles: profiles)
            try renderer.writePNG(to: url, progress: progress)
        }.value
        return url
    }

    // MARK: Layers

    /// Photo and text layers, bottom to top.
    static func layerOverlays(_ input: ArtworkInput, layout: PosterLayout, images: [String: UIImage]) -> [RasterOverlay] {
        let photos = input.design.photos
        return input.design.layers.compactMap { layer -> RasterOverlay? in
            switch layer {
            case .photo(let photo):
                guard let image = images[photo.assetID], let index = input.design.photoIndex(of: photo.assetID) else { return nil }
                return photoOverlay(photo, image: image, frame: layout.frame(for: photo, index: index, count: photos.count), layout: layout)
            case .text(let text):
                return textOverlay(text, input: input, layout: layout)
            }
        }
    }

    /// A rotated photo: its bounding box with transparent corners, cropped at the poster edge.
    static func photoOverlay(_ photo: BorderPhoto, image: UIImage, frame: OrientedRect, layout: PosterLayout) -> RasterOverlay? {
        let box = clamp(frame.boundingBox, to: PixelRect(x: 0, y: 0, width: layout.canvas.width, height: layout.canvas.height))
        guard box.width > 0, box.height > 0 else { return nil }
        return PixelSampler.transparentOverlay(rect: box) { context, _ in
            context.translateBy(x: frame.centerX - Double(box.x), y: frame.centerY - Double(box.y))
            context.rotate(by: frame.rotation)
            let target = CGRect(x: -frame.width / 2, y: -frame.height / 2, width: frame.width, height: frame.height)
            context.clip(to: target)
            drawCropped(image, photo: photo, in: target)
        }
    }

    /// A text block in its font, size, color and rotation.
    static func textOverlay(_ text: TextLayer, input: ArtworkInput, layout: PosterLayout) -> RasterOverlay? {
        let string = text.displayText(year: input.year, includedPhotos: input.barcode.includedPhotoCount)
        guard !string.isEmpty else { return nil }
        let attributes = textAttributes(text, layout: layout, background: input.settings.background)
        let measured = (string as NSString).size(withAttributes: attributes)
        guard measured.width > 0, measured.height > 0 else { return nil }
        let position = layout.position(for: text)
        let frame = OrientedRect(
            centerX: position.centerX * Double(layout.canvas.width),
            centerY: position.centerY * Double(layout.canvas.height),
            width: measured.width, height: measured.height, rotation: position.rotation
        )
        let box = clamp(frame.boundingBox, to: PixelRect(x: 0, y: 0, width: layout.canvas.width, height: layout.canvas.height))
        guard box.width > 0, box.height > 0 else { return nil }
        return PixelSampler.transparentOverlay(rect: box) { context, _ in
            context.translateBy(x: frame.centerX - Double(box.x), y: frame.centerY - Double(box.y))
            context.rotate(by: frame.rotation)
            (string as NSString).draw(at: CGPoint(x: -measured.width / 2, y: -measured.height / 2), withAttributes: attributes)
        }
    }

    /// Size of a text block in poster pixels (for the editor's selection box).
    static func textSize(_ text: TextLayer, input: ArtworkInput, layout: PosterLayout) -> CGSize {
        let string = text.displayText(year: input.year, includedPhotos: input.barcode.includedPhotoCount)
        let attributes = textAttributes(text, layout: layout, background: input.settings.background)
        return ((string.isEmpty ? " " : string) as NSString).size(withAttributes: attributes)
    }

    static func textAttributes(_ text: TextLayer, layout: PosterLayout, background: RGB8) -> [NSAttributedString.Key: Any] {
        let font = font(text.font, bold: text.bold, size: layout.fontSize(for: text))
        return [
            .font: font,
            .foregroundColor: textColor(text, background: background),
            .kern: font.pointSize * 0.02,
        ]
    }

    static func textColor(_ text: TextLayer, background: RGB8) -> UIColor {
        if let color = text.color { return UIColor(color) }
        let light = background.prefersLightText
        switch text.role {
        case .year, .custom: return light ? UIColor(white: 0.95, alpha: 1) : UIColor(white: 0.12, alpha: 1)
        case .photoCount: return light ? UIColor(white: 0.8, alpha: 1) : UIColor(white: 0.3, alpha: 1)
        }
    }

    static func font(_ style: FontStyle, bold: Bool, size: Double) -> UIFont {
        let size = CGFloat(size)
        func system(_ design: UIFontDescriptor.SystemDesign) -> UIFont {
            let base = UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
            guard let descriptor = base.fontDescriptor.withDesign(design) else { return base }
            return UIFont(descriptor: descriptor, size: size)
        }
        func named(_ regular: String, _ boldName: String) -> UIFont {
            UIFont(name: bold ? boldName : regular, size: size) ?? UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        }
        switch style {
        case .system: return system(.default)
        case .rounded: return system(.rounded)
        case .serif: return system(.serif)
        case .mono: return system(.monospaced)
        case .avenir: return named("AvenirNext-Regular", "AvenirNext-Bold")
        case .futura: return named("Futura-Medium", "Futura-Bold")
        case .georgia: return named("Georgia", "Georgia-Bold")
        case .didot: return named("Didot", "Didot-Bold")
        case .typewriter: return named("AmericanTypewriter", "AmericanTypewriter-Bold")
        case .marker: return named("MarkerFelt-Thin", "MarkerFelt-Wide")
        case .script: return named("SnellRoundhand", "SnellRoundhand-Bold")
        }
    }

    /// Drawn last, above every layer, so nothing can hide it.
    static func watermarkOverlays(_ input: ArtworkInput, layout: PosterLayout) -> [RasterOverlay] {
        guard input.showWatermark else { return [] }
        let background = input.settings.background
        let color = background.prefersLightText ? UIColor(white: 0.65, alpha: 1) : UIColor(white: 0.55, alpha: 1)
        return [PixelSampler.overlay(rect: layout.watermark, background: background) { _, size in
            var font = UIFont.systemFont(ofSize: size.height / 1.25, weight: .regular)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            let measured = (PosterLayout.watermarkText as NSString).size(withAttributes: attributes)
            if measured.width > size.width {
                font = font.withSize(font.pointSize * size.width / measured.width * 0.95)
                attributes[.font] = font
            }
            let y = (size.height - font.lineHeight) / 2
            (PosterLayout.watermarkText as NSString).draw(in: CGRect(x: 0, y: y, width: size.width, height: font.lineHeight), withAttributes: attributes)
        }]
    }

    // MARK: Photo helpers

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
