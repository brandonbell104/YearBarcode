import Foundation
import Observation
import UIKit
import YearBarcodeCore

/// Loaded state for one saved generation: the report built from cached
/// analyses, the user's artwork choices, and the current preview.
@MainActor
@Observable
final class ArtworkSession {
    enum ExportPurpose { case save, share }

    enum ExportState {
        case idle
        case exporting(Double)
        case ready(URL, ExportPurpose)
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
            ?? ArtworkRecord(generationID: generationID, settings: model.generation(generationID)?.settings ?? .default, borderPhotos: [], exportPath: nil)
    }

    var showWatermark: Bool { !model.purchases.isUnlocked }

    func load() async {
        isLoading = true
        report = await model.report(for: generationID)
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

    func setBorderPhotos(_ photos: [BorderPhoto]) async {
        artwork.borderPhotos = Array(photos.prefix(PosterLayout.maxBorderPhotos))
        model.save(artwork)
        await loadBorderImages()
        await rebuild()
    }

    /// Recomputes groups from the original per-photo colors, then the preview.
    func rebuild() async {
        guard let report else { return }
        let settings = artwork.settings
        let year = report.snapshot.year
        let photos = artwork.borderPhotos
        let images = borderImages
        let watermark = showWatermark
        let result = await Task.detached(priority: .userInitiated) { () -> (BarcodeData, CGImage?) in
            let data = report.barcode(for: settings)
            let input = ArtworkInput(year: year, settings: settings, barcode: data, borderPhotos: photos, showWatermark: watermark)
            return (data, ArtworkRenderer.preview(input, borderImages: images))
        }.value
        barcode = result.0
        preview = result.1
    }

    private func loadBorderImages() async {
        var images: [String: UIImage] = [:]
        for photo in artwork.borderPhotos {
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
        return ArtworkInput(year: report.snapshot.year, settings: artwork.settings, barcode: barcode,
                            borderPhotos: artwork.borderPhotos, showWatermark: showWatermark)
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
            exportState = .ready(url, purpose)
        } catch BorderPhotoError.unavailable(let assetID) {
            replacementNeeded = assetID
            exportState = .failed(BorderPhotoError.unavailable(assetID: assetID).localizedDescription)
        } catch {
            exportState = .failed("The PNG could not be created: \(error.localizedDescription)")
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
