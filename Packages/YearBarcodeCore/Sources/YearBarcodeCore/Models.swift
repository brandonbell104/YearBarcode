import Foundation

public enum Versions {
    /// Bump when color sampling or filter rules change; cached analyses with a
    /// different version are recomputed.
    public static let analysis = 2
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
            return "One equal stripe for each day that has photos, in date order. Days without photos are skipped, so there are no gaps."
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
    /// Poster background (the border around the barcode).
    public var background: RGB8
    public var stripeStyle: StripeStyle

    public init(
        mode: BarcodeMode = .everyPhoto,
        printSize: PrintSize = .size24x36,
        orientation: Orientation = .landscape,
        background: RGB8 = .white,
        stripeStyle: StripeStyle = .solid
    ) {
        self.mode = mode
        self.printSize = printSize
        self.orientation = orientation
        self.background = background
        self.stripeStyle = stripeStyle
    }

    private enum CodingKeys: String, CodingKey {
        case mode, printSize, orientation, background, stripeStyle
    }

    /// Settings saved before `background` existed decode with a white background.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(BarcodeMode.self, forKey: .mode)
        printSize = try c.decode(PrintSize.self, forKey: .printSize)
        orientation = try c.decode(Orientation.self, forKey: .orientation)
        background = try c.decodeIfPresent(RGB8.self, forKey: .background) ?? .white
        stripeStyle = try c.decodeIfPresent(StripeStyle.self, forKey: .stripeStyle) ?? .solid
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
    /// The photo squeezed to a line: colors top to bottom and left to right
    /// (`ColorProfile.length` each). Nil for analyses made before profiles existed.
    public var rows: [RGB8]?
    public var columns: [RGB8]?

    public init(
        assetID: String,
        revision: String,
        analysisVersion: Int = Versions.analysis,
        color: LinearRGB,
        exclusion: ExclusionReason?,
        confidence: Double,
        fingerprint: ImageFingerprint,
        rows: [RGB8]? = nil,
        columns: [RGB8]? = nil
    ) {
        self.rows = rows
        self.columns = columns
        self.assetID = assetID
        self.revision = revision
        self.analysisVersion = analysisVersion
        self.color = color
        self.exclusion = exclusion
        self.confidence = confidence
        self.fingerprint = fingerprint
    }
}
