import Foundation

/// A photo that survived filtering, with its cached linear color.
public struct IncludedPhoto: Hashable, Sendable {
    public var assetID: String
    public var captureDate: Date
    public var day: DayKey
    public var color: LinearRGB
    public var rows: [RGB8]?
    public var columns: [RGB8]?

    public init(assetID: String, captureDate: Date, day: DayKey, color: LinearRGB, rows: [RGB8]? = nil, columns: [RGB8]? = nil) {
        self.assetID = assetID
        self.captureDate = captureDate
        self.day = day
        self.color = color
        self.rows = rows
        self.columns = columns
    }
}

/// One stripe. `sum` is nil for an Every-Day slot with no photos (drawn white).
public struct Stripe: Codable, Hashable, Sendable {
    public var sum: ColorSum?
    /// Squeezed-photo profiles of the stripe's photos (top to bottom, left to
    /// right), when every photo in it has one.
    public var rows: ProfileSum?
    public var columns: ProfileSum?

    public init(sum: ColorSum?, rows: ProfileSum? = nil, columns: ProfileSum? = nil) {
        self.sum = sum
        self.rows = rows
        self.columns = columns
    }

    /// Equal-weight stripe from a run of photos.
    public init<C: Collection>(photos: C) where C.Element == IncludedPhoto {
        var sum = ColorSum()
        var rows: ProfileSum?
        var columns: ProfileSum?
        var profiled = true
        for photo in photos {
            sum.add(photo.color)
            if profiled, let r = photo.rows, let c = photo.columns {
                if rows == nil { rows = ProfileSum(length: r.count); columns = ProfileSum(length: c.count) }
                rows?.add(r)
                columns?.add(c)
            } else {
                profiled = false
            }
        }
        self.init(sum: sum, rows: profiled ? rows : nil, columns: profiled ? columns : nil)
    }

    /// The profile along the stripe for an orientation: landscape stripes run
    /// top to bottom, portrait stripes left to right.
    public func profile(for orientation: Orientation) -> [RGB8]? {
        (orientation == .landscape ? rows : columns)?.average
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
        capacity: Int
    ) -> BarcodeData {
        let sorted = photos.sorted {
            $0.captureDate != $1.captureDate ? $0.captureDate < $1.captureDate : $0.assetID < $1.assetID
        }
        switch mode {
        case .everyPhoto:
            let stripes = everyPhoto(sorted, capacity: capacity)
            return BarcodeData(stripes: stripes, includedPhotoCount: sorted.count, groupedToFit: sorted.count > capacity)
        case .everyDay:
            return BarcodeData(stripes: everyDay(sorted), includedPhotoCount: sorted.count, groupedToFit: false)
        }
    }

    /// One stripe per photo when it fits; otherwise exactly `capacity` groups
    /// that keep chronological order and never cross a day boundary.
    public static func everyPhoto(_ sorted: [IncludedPhoto], capacity: Int) -> [Stripe] {
        if sorted.count <= capacity {
            return sorted.map { Stripe(photos: [$0]) }
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
                stripes.append(Stripe(photos: photos[range]))
            }
        }
        return stripes
    }

    /// One equal stripe per day that has photos, in date order. Days without
    /// photos are left out, so the barcode has no gaps and never invents a color.
    public static func everyDay(_ photos: [IncludedPhoto]) -> [Stripe] {
        var days: [DayKey: [IncludedPhoto]] = [:]
        for photo in photos { days[photo.day, default: []].append(photo) }
        return days.keys.sorted().map { Stripe(photos: days[$0]!) }
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

extension StripeGeometry {
    /// Screen-preview profiles matching `previewColors`: each pixel averages the
    /// profiles of the stripes it covers. Empty when stripes have no profiles.
    public static func previewProfiles(_ stripes: [Stripe], pixels: Int, orientation: Orientation) -> [[RGB8]] {
        func sum(_ stripe: Stripe) -> ProfileSum? { orientation == .landscape ? stripe.rows : stripe.columns }
        guard !stripes.isEmpty, stripes.allSatisfy({ sum($0) != nil }) else { return [] }
        guard stripes.count > pixels, pixels > 0 else { return stripes.map { sum($0)?.average ?? [] } }
        return (0..<pixels).map { p in
            let lower = p * stripes.count / pixels
            let upper = max(lower + 1, (p + 1) * stripes.count / pixels)
            var total = ProfileSum(length: sum(stripes[lower])!.r.count)
            for stripe in stripes[lower..<upper] {
                // Weight each stripe equally, like previewColors.
                if let average = sum(stripe)?.average { total.add(average) }
            }
            return total.average ?? []
        }
    }
}
