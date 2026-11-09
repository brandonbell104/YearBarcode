import Foundation
import Observation
import Photos
import UIKit
import YearBarcodeCore

/// Loaded state for one saved generation: the report built from cached
/// analyses, the user's artwork choices, and the current preview.
@MainActor
@Observable
final class ArtworkSession {
    enum ExportPurpose { case files, photos, share }

    enum ExportState {
        case idle
        case exporting(Double)
        /// Waiting for the Files or Share sheet.
        case ready(URL, ExportPurpose)
        case savedToPhotos
        case failed(String)
    }

    let generationID: UUID
    @ObservationIgnored private unowned let model: AppModel

    private(set) var report: GenerationReport?
    private(set) var artwork: ArtworkRecord
    private(set) var barcode: BarcodeData?
    private(set) var preview: CGImage?
    private(set) var borderImages: [String: UIImage] = [:]
    private(set) var isLoading = true
    var exportState: ExportState = .idle
    var replacementNeeded: String?

    init(generationID: UUID, model: AppModel) {
        self.generationID = generationID
        self.model = model
        artwork = model.artwork(for: generationID)
            ?? ArtworkRecord(generationID: generationID, settings: model.generation(generationID)?.settings ?? .default, design: .standard(), exportPath: nil)
    }

    var showWatermark: Bool { !model.purchases.isUnlocked }

    func load() async {
        isLoading = true
        report = await model.report(for: generationID)
        fillMissingAspects()
        await loadBorderImages()
        await rebuild()
        isLoading = false
    }

    func update(_ settings: ArtworkSettings) async {
        guard settings != artwork.settings else { return }
        artwork.settings = settings
        model.save(artwork)
        await rebuild()
    }

    /// Replaces the layer stack (photos and text) and re-renders the preview.
    func setDesign(_ design: PosterDesign) async {
        artwork.design = design
        model.save(artwork)
        await loadBorderImages()
        await rebuild()
    }

    /// Replaces one photo layer (matched by asset) keeping its place in the stack.
    func updatePhoto(_ photo: BorderPhoto) async {
        var design = artwork.design
        if let index = design.layers.firstIndex(where: { $0.id == PosterLayer.photo(photo).id }) {
            design.layers[index] = .photo(photo)
        }
        await setDesign(design)
    }

    /// A screen-sized copy of a library photo, for the layout editor.
    func displayImage(for assetID: String) async -> UIImage? {
        if let cached = borderImages[assetID] { return cached }
        guard let asset = model.library.asset(id: assetID) else { return nil }
        return try? await model.library.image(for: asset, targetSize: CGSize(width: 600, height: 600))
    }

    /// The photo's own width / height (PhotoKit reports display-oriented pixels).
    func aspect(of assetID: String) -> Double? {
        guard let asset = model.library.asset(id: assetID), asset.pixelWidth > 0, asset.pixelHeight > 0 else { return nil }
        return Double(asset.pixelWidth) / Double(asset.pixelHeight)
    }

    /// Photos added before shapes were stored get their real shape, so they
    /// stop being cropped to the slot.
    private func fillMissingAspects() {
        guard artwork.design.photos.contains(where: { $0.aspect == nil }) else { return }
        artwork.design.layers = artwork.design.layers.map { layer in
            guard case .photo(var photo) = layer, photo.aspect == nil else { return layer }
            photo.aspect = aspect(of: photo.assetID)
            // The old crop was for the slot shape; show the whole photo instead.
            photo.zoom = 1
            photo.centerX = 0.5
            photo.centerY = 0.5
            return .photo(photo)
        }
        model.save(artwork)
    }

    /// Recomputes groups from the original per-photo colors, then the preview.
    func rebuild() async {
        guard let report else { return }
        let settings = artwork.settings
        let title = report.snapshot.title
        let design = artwork.design
        let images = borderImages
        let watermark = showWatermark
        let result = await Task.detached(priority: .userInitiated) { () -> (BarcodeData, CGImage?) in
            let data = report.barcode(for: settings)
            let input = ArtworkInput(title: title, settings: settings, barcode: data, design: design, showWatermark: watermark)
            return (data, ArtworkRenderer.preview(input, borderImages: images))
        }.value
        barcode = result.0
        preview = result.1
    }

    private func loadBorderImages() async {
        var images: [String: UIImage] = [:]
        for photo in artwork.design.photos {
            if let image = borderImages[photo.assetID] {
                images[photo.assetID] = image
            } else if let asset = model.library.asset(id: photo.assetID),
                      let image = try? await model.library.image(for: asset, targetSize: CGSize(width: 600, height: 600)) {
                images[photo.assetID] = image
            }
        }
        borderImages = images
    }

    var input: ArtworkInput? {
        guard let report, let barcode else { return nil }
        return ArtworkInput(title: report.snapshot.title, settings: artwork.settings, barcode: barcode,
                            design: artwork.design, showWatermark: showWatermark)
    }

    /// Full-resolution PNG, generated only on Save or Share.
    func export(_ purpose: ExportPurpose) async {
        guard let input else { return }
        exportState = .exporting(0)
        do {
            let url = try await ArtworkRenderer.exportPNG(input, library: model.library) { fraction in
                Task { @MainActor [weak self] in
                    if case .exporting = self?.exportState { self?.exportState = .exporting(fraction) }
                }
            }
            artwork.exportPath = url.path
            model.save(artwork)
            if purpose == .photos {
                try await Self.saveToPhotos(url)
                exportState = .savedToPhotos
            } else {
                exportState = .ready(url, purpose)
            }
        } catch BorderPhotoError.unavailable(let assetID) {
            replacementNeeded = assetID
            exportState = .failed(BorderPhotoError.unavailable(assetID: assetID).localizedDescription)
        } catch PhotosSaveError.notAllowed {
            exportState = .failed("Year Barcode isn't allowed to add photos. Allow it in Settings → Privacy & Security → Photos.")
        } catch {
            exportState = .failed("The PNG could not be created: \(error.localizedDescription)")
        }
    }

    enum PhotosSaveError: Error { case notAllowed }

    /// Adds the PNG file itself to the library (lossless, keeps its 300 PPI tag).
    private static func saveToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw PhotosSaveError.notAllowed }
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = url.lastPathComponent
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: options)
        }
    }
}

extension AppModel {
    func session(for id: UUID) -> ArtworkSession {
        if let existing = sessions[id] { return existing }
        let session = ArtworkSession(generationID: id, model: self)
        sessions[id] = session
        return session
    }
}
