import Foundation

/// What the platform library adapter reports for each accessible asset.
public struct LibraryAssetDescriptor: Hashable, Sendable {
    public var assetID: String
    /// Capture date as reported by the library. Nil when unknown; never
    /// substitute an import date.
    public var captureDate: Date?
    public var revision: String

    public init(assetID: String, captureDate: Date?, revision: String) {
        self.assetID = assetID
        self.captureDate = captureDate
        self.revision = revision
    }
}

/// A fixed snapshot created when the user taps Generate.
public struct GenerationSnapshot: Codable, Hashable, Sendable {
    public var id: UUID
    public var year: Int
    public var cutoff: Date
    public var timeZoneIdentifier: String
    public var settings: ArtworkSettings
    public var access: LibraryAccess
    public var analysisVersion: Int
    public var layoutVersion: Int
    /// Sorted by capture date, then asset ID.
    public var entries: [ManifestEntry]
    public var missingDateCount: Int
    public var invalidDateCount: Int

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(identifier: "UTC")! }
    public var calendar: YearCalendar { YearCalendar(timeZone: timeZone) }
}

public enum SnapshotError: Error, Equatable, Sendable {
    case futureYear(Int)
}

public enum SnapshotBuilder {
    /// Earliest plausible capture date; anything before the first photograph is invalid metadata.
    public static let earliestValidDate = Date(timeIntervalSince1970: -4_575_744_000) // 1825-01-01

    /// Years with at least one valid capture date, newest first, excluding
    /// years after `now`.
    public static func availableYears<S: Sequence>(captureDates: S, now: Date, timeZone: TimeZone) -> [Int] where S.Element == Date? {
        let calendar = YearCalendar(timeZone: timeZone)
        let currentYear = calendar.year(of: now)
        var years = Set<Int>()
        for case let date? in captureDates where date >= earliestValidDate {
            let year = calendar.year(of: date)
            if year <= currentYear { years.insert(year) }
        }
        return years.sorted(by: >)
    }

    /// Freezes asset membership for a generation.
    ///
    /// - Includes capture dates from January 1 of `year` through the end of the
    ///   year, stopping at `cutoff` (anything captured or dated later never joins).
    /// - Assets without a capture date are skipped and counted; the caller
    ///   should pass every accessible still image whose date is nil so the count
    ///   is truthful.
    public static func build<S: Sequence>(
        id: UUID = UUID(),
        year: Int,
        cutoff: Date,
        timeZone: TimeZone,
        settings: ArtworkSettings,
        access: LibraryAccess,
        assets: S
    ) throws -> GenerationSnapshot where S.Element == LibraryAssetDescriptor {
        let calendar = YearCalendar(timeZone: timeZone)
        guard year <= calendar.year(of: cutoff) else { throw SnapshotError.futureYear(year) }

        let start = calendar.startOfYear(year)
        let end = calendar.startOfYear(year + 1)
        var entries: [ManifestEntry] = []
        var seen = Set<String>()
        var missing = 0
        var invalid = 0

        for asset in assets {
            guard seen.insert(asset.assetID).inserted else { continue }
            guard let date = asset.captureDate else {
                missing += 1
                continue
            }
            guard date.timeIntervalSince1970.isFinite, date >= earliestValidDate else {
                invalid += 1
                continue
            }
            guard date >= start, date < end, date <= cutoff else { continue }
            entries.append(ManifestEntry(
                assetID: asset.assetID,
                revision: asset.revision,
                captureDate: date,
                day: calendar.dayKey(for: date)
            ))
        }

        entries.sort(by: chronological)

        return GenerationSnapshot(
            id: id,
            year: year,
            cutoff: cutoff,
            timeZoneIdentifier: timeZone.identifier,
            settings: settings,
            access: access,
            analysisVersion: Versions.analysis,
            layoutVersion: Versions.layout,
            entries: entries,
            missingDateCount: missing,
            invalidDateCount: invalid
        )
    }

    /// Capture timestamp, then stable asset ID.
    public static func chronological(_ a: ManifestEntry, _ b: ManifestEntry) -> Bool {
        if a.captureDate != b.captureDate { return a.captureDate < b.captureDate }
        return a.assetID < b.assetID
    }
}
