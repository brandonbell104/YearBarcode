import Foundation

/// Where an image came from, as far as the platform can tell.
public enum Provenance: String, Codable, Sendable {
    case camera
    case downloaded
    case unknown
}

/// Raw evidence gathered on-device for one photo. Every score is 0...1.
/// The platform layer fills what it can; unknown values stay at zero.
public struct FilterSignals: Codable, Hashable, Sendable {
    /// Library metadata says this is a screenshot (e.g. PhotoKit `.photoScreenshot`).
    public var isScreenshotMetadata = false
    /// Visual screenshot cues (exact screen dimensions, status bar, no camera EXIF).
    public var screenshotCue = 0.0
    /// The asset belongs to a burst series.
    public var isBurstMember = false
    /// Fraction of the analysis thumbnail covered by recognized text.
    public var textCoverage = 0.0
    /// Confidence that a page-like quadrilateral fills the frame.
    public var pageGeometry = 0.0
    /// Classifier confidence for document/receipt-like content.
    public var documentClassifier = 0.0
    /// Classifier confidence for meme-like content.
    public var memeClassifier = 0.0
    /// Large text bands at the top and/or bottom of the frame (classic caption layout).
    public var captionBands = false
    public var provenance: Provenance = .unknown
    /// Visual / file cues that the image was saved from elsewhere.
    public var downloadedCue = 0.0

    public init() {}
}

public struct FilterDecision: Hashable, Sendable {
    public var exclusion: ExclusionReason?
    public var confidence: Double

    public static let include = FilterDecision(exclusion: nil, confidence: 0)
}

/// Conservative thresholds: when in doubt, keep the photo.
///
/// Detection is best effort. Some saved images will slip through and some
/// genuine photos may be excluded; thresholds should be tuned against a
/// varied, consented test set.
public enum FilterPolicy {
    public static func decide(_ s: FilterSignals) -> FilterDecision {
        if s.isScreenshotMetadata { return FilterDecision(exclusion: .screenshot, confidence: 1) }
        if s.isBurstMember { return FilterDecision(exclusion: .burst, confidence: 1) }
        if s.provenance == .downloaded { return FilterDecision(exclusion: .downloaded, confidence: 0.95) }

        // Documents: text density and page geometry together, or a very confident classifier.
        let documentScore: Double = {
            if s.documentClassifier >= 0.9 { return s.documentClassifier }
            if s.pageGeometry >= 0.8 && s.textCoverage >= 0.08 { return max(s.pageGeometry, 0.85) }
            if s.textCoverage >= 0.30 && s.documentClassifier >= 0.6 { return 0.85 }
            return 0
        }()
        if documentScore > 0 { return FilterDecision(exclusion: .document, confidence: documentScore) }

        // Memes: classifier first; caption-style text only strengthens it. Text alone never decides.
        if s.memeClassifier >= 0.85 || (s.memeClassifier >= 0.6 && s.captionBands) {
            return FilterDecision(exclusion: .meme, confidence: max(s.memeClassifier, 0.85))
        }

        if s.screenshotCue >= 0.9 { return FilterDecision(exclusion: .screenshot, confidence: s.screenshotCue) }
        if s.provenance != .camera && s.downloadedCue >= 0.9 {
            return FilterDecision(exclusion: .downloaded, confidence: s.downloadedCue)
        }
        return .include
    }
}
