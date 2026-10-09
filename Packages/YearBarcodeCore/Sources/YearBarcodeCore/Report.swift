import Foundation

/// A manifest entry with its current job status and (if analyzed) its cached analysis.
public struct ManifestItem: Sendable {
    public var entry: ManifestEntry
    public var status: ItemStatus
    public var analysis: PhotoAnalysis?

    public init(entry: ManifestEntry, status: ItemStatus, analysis: PhotoAnalysis?) {
        self.entry = entry
        self.status = status
        self.analysis = analysis
    }
}

/// Totals shown to the user. Excluded photos have no gallery in V1; only counts.
public struct GenerationCounts: Codable, Hashable, Sendable {
    public var manifest = 0
    public var included = 0
    public var excluded: [ExclusionReason: Int] = [:]
    public var pending = 0
    public var unavailable = 0
    public var changed = 0
    public var downloadFailed = 0
    public var missingDate = 0
    public var invalidDate = 0

    public init() {}

    public var excludedTotal: Int { excluded.values.reduce(0, +) }
    /// Items that could not be analyzed at all.
    public var notAnalyzed: Int { unavailable + changed + downloadFailed }
    /// A result is complete only when nothing is pending or retryable.
    public var isComplete: Bool { pending == 0 && downloadFailed == 0 }
}

public struct GenerationReport: Sendable {
    public var snapshot: GenerationSnapshot
    public var included: [IncludedPhoto]
    public var counts: GenerationCounts
    public var duplicateGroups: [String: String]

    public static func make(snapshot: GenerationSnapshot, items: [ManifestItem]) -> GenerationReport {
        var counts = GenerationCounts()
        counts.manifest = items.count
        counts.missingDate = snapshot.missingDateCount
        counts.invalidDate = snapshot.invalidDateCount

        var candidates: [DuplicateCandidate] = []
        var survivors: [ManifestItem] = []
        for item in items {
            switch item.status {
            case .pending: counts.pending += 1
            case .unavailable: counts.unavailable += 1
            case .changed: counts.changed += 1
            case .downloadFailed: counts.downloadFailed += 1
            case .analyzed:
                guard let analysis = item.analysis else {
                    counts.pending += 1
                    continue
                }
                if let reason = analysis.exclusion {
                    counts.excluded[reason, default: 0] += 1
                } else {
                    survivors.append(item)
                    candidates.append(DuplicateCandidate(
                        assetID: item.entry.assetID,
                        captureDate: item.entry.captureDate,
                        color: analysis.color,
                        fingerprint: analysis.fingerprint
                    ))
                }
            }
        }

        let duplicates = DuplicateResolver.resolve(candidates)
        var included: [IncludedPhoto] = []
        for item in survivors {
            if duplicates.suppressed.contains(item.entry.assetID) {
                counts.excluded[.duplicate, default: 0] += 1
            } else {
                included.append(IncludedPhoto(
                    assetID: item.entry.assetID,
                    captureDate: item.entry.captureDate,
                    day: item.entry.day,
                    color: item.analysis!.color
                ))
            }
        }
        counts.included = included.count
        return GenerationReport(snapshot: snapshot, included: included, counts: counts, duplicateGroups: duplicates.groupOf)
    }

    /// Stripes for any mode/size/orientation, recomputed from per-photo colors.
    public func barcode(for settings: ArtworkSettings) -> BarcodeData {
        let layout = PosterLayout(printSize: settings.printSize, orientation: settings.orientation)
        return Grouper.barcode(
            photos: included,
            mode: settings.mode,
            capacity: layout.maxGroups,
            daySlots: snapshot.calendar.daySlots(year: snapshot.year, cutoff: snapshot.cutoff)
        )
    }
}

/// Plain-language text for the artwork and status screens.
public enum ArtworkText {
    public static func formatted(_ n: Int, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? String(n)
    }

    public static func photoCount(_ n: Int, locale: Locale = .current) -> String {
        "\(formatted(n, locale: locale)) \(n == 1 ? "photo" : "photos")"
    }

    /// "2025 - 7,842 photos"
    public static func title(year: Int, included: Int, locale: Locale = .current) -> String {
        "\(year) - \(photoCount(included, locale: locale))"
    }

    public static func groupingSummary(_ data: BarcodeData, mode: BarcodeMode) -> String? {
        switch mode {
        case .everyPhoto:
            return data.groupedToFit ? "Some photos were grouped to fit this poster." : nil
        case .everyDay:
            let empty = data.stripes.filter { $0.sum == nil }.count
            return empty > 0 ? "\(empty) \(empty == 1 ? "day has" : "days have") no included photos and \(empty == 1 ? "is" : "are") shown in white." : nil
        }
    }

    /// "7,842 included photos, 4,860 color groups, 236 excluded."
    public static func details(_ data: BarcodeData, counts: GenerationCounts, locale: Locale = .current) -> String {
        "\(formatted(counts.included, locale: locale)) included photos, \(formatted(data.stripes.count, locale: locale)) color groups, \(formatted(counts.excludedTotal, locale: locale)) excluded."
    }
}
