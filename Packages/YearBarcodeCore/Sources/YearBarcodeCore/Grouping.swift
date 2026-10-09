import Foundation

/// A photo that survived filtering, with its cached linear color.
public struct IncludedPhoto: Hashable, Sendable {
    public var assetID: String
    public var captureDate: Date
    public var day: DayKey
    public var color: LinearRGB

    public init(assetID: String, captureDate: Date, day: DayKey, color: LinearRGB) {
        self.assetID = assetID
        self.captureDate = captureDate
        self.day = day
        self.color = color
    }
}

/// One stripe. `sum` is nil for an Every-Day slot with no photos (drawn white).
public struct Stripe: Codable, Hashable, Sendable {
    public var sum: ColorSum?

    public init(sum: ColorSum?) {
        self.sum = sum
    }

    public var rgb8: RGB8 { sum?.average?.rgb8 ?? .white }
}

public struct BarcodeData: Hashable, Sendable {
    public var stripes: [Stripe]
    public var includedPhotoCount: Int
    /// True when Every Photo had to combine photos to respect the two-pixel minimum.
    public var groupedToFit: Bool
}

public enum Grouper {
    /// Builds stripes from the original per-photo colors. Always recompute from
    /// photos; never feed a previous result back in.
    public static func barcode(
        photos: [IncludedPhoto],
        mode: BarcodeMode,
        capacity: Int,
        daySlots: [DayKey]
    ) -> BarcodeData {
        let sorted = photos.sorted {
            $0.captureDate != $1.captureDate ? $0.captureDate < $1.captureDate : $0.assetID < $1.assetID
        }
        switch mode {
        case .everyPhoto:
            let stripes = everyPhoto(sorted, capacity: capacity)
            return BarcodeData(stripes: stripes, includedPhotoCount: sorted.count, groupedToFit: sorted.count > capacity)
        case .everyDay:
            return BarcodeData(stripes: everyDay(sorted, slots: daySlots), includedPhotoCount: sorted.count, groupedToFit: false)
        }
    }

    /// One stripe per photo when it fits; otherwise exactly `capacity` groups
    /// that keep chronological order and never cross a day boundary.
    public static func everyPhoto(_ sorted: [IncludedPhoto], capacity: Int) -> [Stripe] {
        if sorted.count <= capacity {
            return sorted.map { Stripe(sum: ColorSum($0.color)) }
        }
        var days: [[IncludedPhoto]] = []
        for photo in sorted {
            if let last = days.last?.last, last.day == photo.day {
                days[days.count - 1].append(photo)
            } else {
                days.append([photo])
            }
        }
        let allocation = allocate(dayCounts: days.map(\.count), capacity: capacity)
        var stripes: [Stripe] = []
        stripes.reserveCapacity(capacity)
        for (photos, groups) in zip(days, allocation) {
            for range in partition(count: photos.count, groups: groups) {
                var sum = ColorSum()
                for photo in photos[range] { sum.add(photo.color) }
                stripes.append(Stripe(sum: sum))
            }
        }
        return stripes
    }

    /// One equal slot per calendar day; empty days are white, never borrowed.
    public static func everyDay(_ photos: [IncludedPhoto], slots: [DayKey]) -> [Stripe] {
        var sums: [DayKey: ColorSum] = [:]
        for photo in photos { sums[photo.day, default: ColorSum()].add(photo.color) }
        return slots.map { Stripe(sum: sums[$0]) }
    }

    /// Capped proportional allocation of `capacity` groups across days.
    ///
    /// Every nonempty day gets one group; the rest are shared in proportion to
    /// photo counts, capping each day at its photo count and redistributing the
    /// surplus. Leftovers go to the largest fractional remainders, earlier days
    /// first on ties. Uses exact integer arithmetic.
    ///
    /// - Precondition: `dayCounts.count <= capacity < dayCounts.sum()`, all counts > 0.
    public static func allocate(dayCounts: [Int], capacity: Int) -> [Int] {
        let total = dayCounts.reduce(0, +)
        precondition(dayCounts.allSatisfy { $0 > 0 }, "Days must be nonempty")
        precondition(dayCounts.count <= capacity, "More days than groups")
        if total <= capacity { return dayCounts }

        var result = [Int](repeating: 1, count: dayCounts.count)
        var remaining = capacity - dayCounts.count
        // Extra groups a day can still take beyond its reserved one.
        var active = dayCounts.indices.filter { dayCounts[$0] > 1 }

        // Water-filling: cap days whose proportional share exceeds their room.
        while true {
            let weight = active.reduce(0) { $0 + dayCounts[$1] }
            guard weight > 0, remaining > 0 else { break }
            let capped = active.filter { remaining * dayCounts[$0] > (dayCounts[$0] - 1) * weight }
            if capped.isEmpty { break }
            for d in capped {
                remaining -= dayCounts[d] - 1
                result[d] = dayCounts[d]
            }
            let cappedSet = Set(capped)
            active.removeAll { cappedSet.contains($0) }
        }

        guard remaining > 0 else { return result }
        let weight = active.reduce(0) { $0 + dayCounts[$1] }
        var remainders: [(day: Int, remainder: Int)] = []
        var assigned = 0
        for d in active {
            let share = remaining * dayCounts[d]
            result[d] += share / weight
            assigned += share / weight
            remainders.append((d, share % weight))
        }
        let leftover = remaining - assigned
        remainders.sort { $0.remainder != $1.remainder ? $0.remainder > $1.remainder : $0.day < $1.day }
        for entry in remainders.prefix(leftover) { result[entry.day] += 1 }
        return result
    }

    /// Contiguous index ranges for `groups` groups over `count` items; group j
    /// spans floor(j*n/k) ..< floor((j+1)*n/k), so sizes differ by at most one.
    public static func partition(count n: Int, groups k: Int) -> [Range<Int>] {
        precondition(k >= 1 && k <= n)
        return (0..<k).map { j in (j * n / k)..<((j + 1) * n / k) }
    }
}

public enum StripeGeometry {
    /// Integer boundaries for M stripes over L pixels: boundary i = floor(i*L/M).
    public static func boundaries(count m: Int, length l: Int) -> [Int] {
        guard m > 0 else { return [0, l] }
        return (0...m).map { $0 * l / m }
    }
}

extension StripeGeometry {
    /// Screen-preview colors when there are more stripes than pixels: each
    /// pixel averages (in linear light) the stripes it covers. Exports never use this.
    public static func previewColors(_ stripes: [Stripe], pixels: Int) -> [RGB8] {
        guard stripes.count > pixels, pixels > 0 else { return stripes.map(\.rgb8) }
        return (0..<pixels).map { p in
            let lower = p * stripes.count / pixels
            let upper = max(lower + 1, (p + 1) * stripes.count / pixels)
            var sum = ColorSum()
            for stripe in stripes[lower..<upper] { sum.add(stripe.sum?.average ?? .white) }
            return sum.average?.rgb8 ?? .white
        }
    }
}
