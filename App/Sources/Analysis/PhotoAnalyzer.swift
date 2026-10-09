import CoreML
import ImageIO
import Photos
import UIKit
import Vision
import YearBarcodeCore

/// Analyzes one photo entirely on the device: a tiny color sample for the
/// stripe color, and a larger, short-lived thumbnail for filtering. Only the
/// minimal `PhotoAnalysis` record survives.
final class PhotoAnalyzer: @unchecked Sendable {
    static let colorSampleSize = 64
    static let filterThumbnailLongEdge: CGFloat = 1024

    private let library: PhotoLibraryService
    private let classifier = BundledClassifier()
    private let screenPixelSizes: Set<String>

    @MainActor
    init(library: PhotoLibraryService) {
        self.library = library
        let bounds = UIScreen.main.nativeBounds
        let w = Int(bounds.width), h = Int(bounds.height)
        screenPixelSizes = ["\(w)x\(h)", "\(h)x\(w)"]
    }

    func analyze(asset: PHAsset, revision: String) async throws -> PhotoAnalysis {
        let n = Self.colorSampleSize
        let sampleImage = try await library.image(for: asset, targetSize: CGSize(width: n * 2, height: n * 2), contentMode: .aspectFit)
        let sample = PixelSampler.rgbx(of: sampleImage, width: n, height: n)
        let (color, fingerprint) = sample.withUnsafeBufferPointer { pixels in
            (ColorAverager.averageLinear(pixels: pixels, width: n, height: n, bytesPerRow: n * 4),
             ImageFingerprint.compute(pixels: pixels, width: n, height: n, bytesPerRow: n * 4))
        }

        var signals = FilterSignals()
        signals.isScreenshotMetadata = asset.mediaSubtypes.contains(.photoScreenshot)
        signals.isBurstMember = asset.burstIdentifier != nil

        // Skip the expensive pass when metadata already decides.
        if !signals.isScreenshotMetadata && !signals.isBurstMember {
            await addProvenance(to: &signals, asset: asset)
            let edge = Self.filterThumbnailLongEdge
            let thumbnail = try await library.image(for: asset, targetSize: CGSize(width: edge, height: edge), contentMode: .aspectFit)
            addVisionSignals(to: &signals, image: thumbnail)
            if screenPixelSizes.contains("\(asset.pixelWidth)x\(asset.pixelHeight)") && signals.provenance != .camera {
                signals.screenshotCue = max(signals.screenshotCue, 0.92)
            }
        }

        let decision = FilterPolicy.decide(signals)
        return PhotoAnalysis(
            assetID: asset.localIdentifier, revision: revision, color: color,
            exclusion: decision.exclusion, confidence: decision.confidence, fingerprint: fingerprint
        )
    }

    // MARK: - Provenance

    private static let cameraFilename = try! NSRegularExpression(pattern: "^(IMG|DSC|DSCN|DSCF|PXL|MVIMG|P\\d{3}|_DSC|GOPR|DJI)[_-]?\\d", options: [.caseInsensitive])

    /// There is no universal "downloaded" flag. Camera EXIF is reliable
    /// evidence of a camera; its absence is only a cue.
    private func addProvenance(to signals: inout FilterSignals, asset: PHAsset) async {
        guard let local = await library.localImageData(for: asset),
              let source = CGImageSourceCreateWithData(local.data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return } // Not on device: provenance stays unknown.

        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let hasCamera = tiff?[kCGImagePropertyTIFFMake] != nil || tiff?[kCGImagePropertyTIFFModel] != nil || exif?[kCGImagePropertyExifLensModel] != nil
        if hasCamera {
            signals.provenance = .camera
            return
        }
        var cue = 0.0
        if exif?[kCGImagePropertyExifDateTimeOriginal] == nil { cue += 0.6 }
        if let uti = local.uti, ["com.compuserve.gif", "org.webmproject.webp"].contains(uti) { cue += 0.35 }
        if let name = library.originalFilename(for: asset) {
            let range = NSRange(name.startIndex..., in: name)
            if Self.cameraFilename.firstMatch(in: name, range: range) == nil { cue += 0.1 }
        }
        signals.downloadedCue = min(cue, 1)
    }

    // MARK: - Vision

    private static let documentLabels: Set<String> = ["document", "receipt", "paper", "text", "handwriting", "menu", "printed_page"]

    private func addVisionSignals(to signals: inout FilterSignals, image: UIImage) {
        guard let cgImage = image.cgImage else { return }
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: CGImagePropertyOrientation(image.imageOrientation), options: [:])

        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        text.usesLanguageCorrection = false
        let document = VNDetectDocumentSegmentationRequest()
        let classify = VNClassifyImageRequest()
        var requests: [VNRequest] = [text, document, classify]
        let custom = classifier.request()
        if let custom { requests.append(custom) }

        do {
            try handler.perform(requests)
        } catch {
            return // Filtering is best effort; keep the photo.
        }

        let boxes = (text.results ?? []).map(\.boundingBox)
        signals.textCoverage = Double(min(1, boxes.reduce(CGFloat(0)) { $0 + $1.width * $1.height }))
        // Caption layout: wide text near the top and/or bottom edge (Vision origin is bottom-left).
        let topWidth = boxes.filter { $0.midY > 0.78 }.reduce(CGFloat(0)) { $0 + $1.width }
        let bottomWidth = boxes.filter { $0.midY < 0.22 }.reduce(CGFloat(0)) { $0 + $1.width }
        signals.captionBands = topWidth >= 0.5 || bottomWidth >= 0.5

        if let page = document.results?.first {
            let area = page.boundingBox.width * page.boundingBox.height
            signals.pageGeometry = area >= 0.35 ? Double(page.confidence) : 0
        }

        for observation in classify.results ?? [] where observation.confidence > 0.1 {
            let label = observation.identifier.lowercased()
            if Self.documentLabels.contains(label) {
                signals.documentClassifier = max(signals.documentClassifier, Double(observation.confidence))
            }
            if label == "screenshot" {
                signals.screenshotCue = max(signals.screenshotCue, Double(observation.confidence) * 0.9)
            }
        }

        if let custom, let scores = BundledClassifier.scores(from: custom) {
            signals.memeClassifier = scores["meme"] ?? 0
            signals.documentClassifier = max(signals.documentClassifier, scores["document"] ?? 0)
            signals.screenshotCue = max(signals.screenshotCue, scores["screenshot"] ?? 0)
        }
    }
}

/// Optional bundled Core ML image classifier ("YearBarcodeFilter.mlmodelc")
/// with labels such as `photo`, `document`, `meme`, `screenshot`. When no model
/// is bundled, filtering falls back to Vision's built-in requests.
final class BundledClassifier: @unchecked Sendable {
    private let model: VNCoreMLModel?

    init() {
        if let url = Bundle.main.url(forResource: "YearBarcodeFilter", withExtension: "mlmodelc"),
           let model = try? MLModel(contentsOf: url) {
            self.model = try? VNCoreMLModel(for: model)
        } else {
            model = nil
        }
    }

    func request() -> VNCoreMLRequest? {
        guard let model else { return nil }
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFit
        return request
    }

    static func scores(from request: VNCoreMLRequest) -> [String: Double]? {
        guard let results = request.results as? [VNClassificationObservation] else { return nil }
        return Dictionary(results.map { ($0.identifier.lowercased(), Double($0.confidence)) }, uniquingKeysWith: max)
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
