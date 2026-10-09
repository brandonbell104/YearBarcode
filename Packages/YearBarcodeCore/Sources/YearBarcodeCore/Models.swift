import Foundation

public enum Versions {
    /// Bump when color sampling or filter rules change; cached analyses with a
    /// different version are recomputed.
    public static let analysis = 1
    /// Bump when grouping or poster geometry changes.
    public static let layout = 1
}

public enum BarcodeMode: String, Codable, CaseIterable, Sendable {
    case everyPhoto
    case everyDay

    public var title: String {
        switch self {
        case .everyPhoto: return "Every Photo"
        case .everyDay: return "Every Day"
        }
    }

    public var helpText: String {
        switch self {
        case .everyPhoto:
            return "One stripe per photo, oldest first. Large years may group neighboring photos from the same day to fit the poster."
        case .everyDay:
            return "One equal stripe per calendar day. Days without included photos stay white."
        }
    }
}

public enum Orientation: String, Codable, CaseIterable, Sendable {
    /// Vertical stripes, oldest at the left.
    case landscape
    /// Horizontal stripes, oldest at the top.
    case portrait

    public var title: String {
        switch self {
        case .landscape: return "Landscape"
        case .portrait: return "Portrait"
        }
    }
}

public enum PrintSize: String, Codable, CaseIterable, Sendable {
    case size12x18
    case size18x24
    case size24x36

    public static let pixelsPerInch = 300

    public var shortInches: Int {
        switch self {
        case .size12x18: return 12
        case .size18x24: return 18
        case .size24x36: return 24
        }
    }

    public var longInches: Int {
        switch self {
        case .size12x18: return 18
        case .size18x24: return 24
        case .size24x36: return 36
        }
    }

    public var title: String { "\(shortInches) × \(longInches) in" }

    public func canvas(_ orientation: Orientation) -> PixelSize {
        let short = shortInches * Self.pixelsPerInch
        let long = longInches * Self.pixelsPerInch
        switch orientation {
        case .landscape: return PixelSize(width: long, height: short)
        case .portrait: return PixelSize(width: short, height: long)
        }
    }
}

public struct ArtworkSettings: Codable, Hashable, Sendable {
    public var mode: BarcodeMode
    public var printSize: PrintSize
    public var orientation: Orientation

    public init(mode: BarcodeMode = .everyPhoto, printSize: PrintSize = .size24x36, orientation: Orientation = .landscape) {
        self.mode = mode
        self.printSize = printSize
        self.orientation = orientation
    }

    public static let `default` = ArtworkSettings()
}

public enum LibraryAccess: String, Codable, Sendable {
    case full
    case limited
}

/// Why a photo was left out of the artwork. Exclusions never touch originals.
public enum ExclusionReason: String, Codable, CaseIterable, Sendable {
    case document
    case screenshot
    case downloaded
    case meme
    case duplicate
    case burst
}

/// Per-job state of one manifest entry.
public enum ItemStatus: String, Codable, Sendable {
    case pending
    case analyzed
    /// Deleted, or no longer accessible (for example after access was limited).
    case unavailable
    /// Edited after the snapshot; the frozen revision can no longer be read.
    case changed
    /// Could not download the rendition (e.g. iCloud while offline). Retryable.
    case downloadFailed
}

/// One asset as frozen into a generation's manifest at Generate time.
public struct ManifestEntry: Codable, Hashable, Sendable {
    public var assetID: String
    public var revision: String
    public var captureDate: Date
    public var day: DayKey

    public init(assetID: String, revision: String, captureDate: Date, day: DayKey) {
        self.assetID = assetID
        self.revision = revision
        self.captureDate = captureDate
        self.day = day
    }
}

/// The minimal record kept after analyzing one photo revision.
public struct PhotoAnalysis: Codable, Hashable, Sendable {
    public var assetID: String
    public var revision: String
    public var analysisVersion: Int
    public var color: LinearRGB
    /// Intrinsic exclusion (everything except duplicates, which depend on
    /// neighboring photos and are resolved per generation).
    public var exclusion: ExclusionReason?
    public var confidence: Double
    public var fingerprint: ImageFingerprint

    public init(
        assetID: String,
        revision: String,
        analysisVersion: Int = Versions.analysis,
        color: LinearRGB,
        exclusion: ExclusionReason?,
        confidence: Double,
        fingerprint: ImageFingerprint
    ) {
        self.assetID = assetID
        self.revision = revision
        self.analysisVersion = analysisVersion
        self.color = color
        self.exclusion = exclusion
        self.confidence = confidence
        self.fingerprint = fingerprint
    }
}
