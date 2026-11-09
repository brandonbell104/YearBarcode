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
    /// A custom timeline: start of the first day and start of the last day
    /// (inclusive). Nil for a whole calendar year.
    public var rangeStart: Date?
    public var rangeEnd: Date?

    public init(
        id: UUID,
        year: Int,
        cutoff: Date,
        timeZoneIdentifier: String,
        settings: ArtworkSettings,
        access: LibraryAccess,
        analysisVersion: Int,
        layoutVersion: Int,
        entries: [ManifestEntry],
        missingDateCount: Int,
        invalidDateCount: Int,
        rangeStart: Date? = nil,
        rangeEnd: Date? = nil
    ) {
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
        self.id = id
        self.year = year
        self.cutoff = cutoff
        self.timeZoneIdentifier = timeZoneIdentifier
        self.settings = settings
        self.access = access
        self.analysisVersion = analysisVersion
        self.layoutVersion = layoutVersion
        self.entries = entries
        self.missingDateCount = missingDateCount
        self.invalidDateCount = invalidDateCount
    }

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(identifier: "UTC")! }
    public var calendar: YearCalendar { YearCalendar(timeZone: timeZone) }

    /// "2025", or for a custom timeline "Mar 3 – Jun 8, 2025".
    public var title: String {
        TimelineTitle.make(year: year, start: rangeStart, end: rangeEnd, timeZone: timeZone)
    }
}

/// Display names for what a poster covers.
public enum TimelineTitle {
    public static func make(year: Int, start: Date?, end: Date?, timeZone: TimeZone, locale: Locale = .current) -> String {
        guard let start, let end else { return String(year) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func format(_ template: String, _ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter.string(from: date)
        }
        let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: end)
        if calendar.isDate(start, inSameDayAs: end) { return format("MMMdyyyy", start) }
        return sameYear
            ? "\(format("MMMd", start)) – \(format("MMMdyyyy", end))"
            : "\(format("MMMdyyyy", start)) – \(format("MMMdyyyy", end))"
    }
}

public enum SnapshotError: Error, Equatable, Sendable {
    case futureYear(Int)
    /// The custom timeline ends before it starts, or starts after today.
    case invalidRange
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

    /// Number of photos per year (valid capture dates only, no future years).
    public static func yearCounts<S: Sequence>(captureDates: S, now: Date, timeZone: TimeZone) -> [Int: Int] where S.Element == Date? {
        let calendar = YearCalendar(timeZone: timeZone)
        let currentYear = calendar.year(of: now)
        var counts: [Int: Int] = [:]
        for case let date? in captureDates where date >= earliestValidDate && date <= now {
            let year = calendar.year(of: date)
            if year <= currentYear { counts[year, default: 0] += 1 }
        }
        return counts
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
        return collect(
            id: id, year: year, start: calendar.startOfYear(year), end: calendar.startOfYear(year + 1),
            range: nil, cutoff: cutoff, timeZone: timeZone, settings: settings, access: access, assets: assets
        )
    }

    /// A custom timeline: every photo captured from the start of `first`'s day
    /// through the end of `last`'s day (and never after `cutoff`).
    public static func build<S: Sequence>(
        id: UUID = UUID(),
        from first: Date,
        through last: Date,
        cutoff: Date,
        timeZone: TimeZone,
        settings: ArtworkSettings,
        access: LibraryAccess,
        assets: S
    ) throws -> GenerationSnapshot where S.Element == LibraryAssetDescriptor {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: first)
        let lastDay = calendar.startOfDay(for: last)
        guard lastDay >= start, start <= cutoff,
              let end = calendar.date(byAdding: .day, value: 1, to: lastDay) else { throw SnapshotError.invalidRange }
        return collect(
            id: id, year: calendar.component(.year, from: start), start: start, end: end,
            range: (start, lastDay), cutoff: cutoff, timeZone: timeZone, settings: settings, access: access, assets: assets
        )
    }

    private static func collect<S: Sequence>(
        id: UUID,
        year: Int,
        start: Date,
        end: Date,
        range: (Date, Date)?,
        cutoff: Date,
        timeZone: TimeZone,
        settings: ArtworkSettings,
        access: LibraryAccess,
        assets: S
    ) -> GenerationSnapshot where S.Element == LibraryAssetDescriptor {
        let calendar = YearCalendar(timeZone: timeZone)
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
            invalidDateCount: invalid,
            rangeStart: range?.0,
            rangeEnd: range?.1
        )
    }

    /// Capture timestamp, then stable asset ID.
    public static func chronological(_ a: ManifestEntry, _ b: ManifestEntry) -> Bool {
        if a.captureDate != b.captureDate { return a.captureDate < b.captureDate }
        return a.assetID < b.assetID
    }
}
