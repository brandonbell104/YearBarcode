import XCTest
@testable import YearBarcodeCore

final class GroupingTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!

    private func photos(perDay counts: [Int], year: Int = 2025) -> [IncludedPhoto] {
        let calendar = YearCalendar(timeZone: utc)
        var result: [IncludedPhoto] = []
        for (dayIndex, count) in counts.enumerated() {
            let dayStart = calendar.startOfYear(year).addingTimeInterval(Double(dayIndex) * 86_400)
            for i in 0..<count {
                let date = dayStart.addingTimeInterval(Double(i))
                let v = Double((dayIndex * 31 + i * 7) % 100) / 100
                result.append(IncludedPhoto(
                    assetID: String(format: "a%05d-%05d", dayIndex, i),
                    captureDate: date,
                    day: calendar.dayKey(for: date),
                    color: LinearRGB(r: v, g: 1 - v, b: v / 2)
                ))
            }
        }
        return result
    }

    func testCapacityTable() {
        let expected: [PrintSize: (Int, Int)] = [
            .size12x18: (4860, 2430),
            .size18x24: (6480, 3240),
            .size24x36: (9720, 4860),
        ]
        for size in PrintSize.allCases {
            for orientation in Orientation.allCases {
                let layout = PosterLayout(printSize: size, orientation: orientation)
                XCTAssertEqual(layout.barcodeLength, expected[size]!.0, "\(size) \(orientation)")
                XCTAssertEqual(layout.maxGroups, expected[size]!.1, "\(size) \(orientation)")
                XCTAssertGreaterThan(layout.maxGroups, 366)
            }
        }
        XCTAssertEqual(PrintSize.size24x36.canvas(.landscape), PixelSize(width: 10800, height: 7200))
        XCTAssertEqual(PrintSize.size24x36.canvas(.portrait), PixelSize(width: 7200, height: 10800))
        XCTAssertEqual(PrintSize.size12x18.canvas(.landscape), PixelSize(width: 5400, height: 3600))
        XCTAssertEqual(PrintSize.size18x24.canvas(.portrait), PixelSize(width: 5400, height: 7200))
    }

    func testOneStripePerPhotoWhenItFits() {
        let input = photos(perDay: [3, 0, 5, 2])
        let stripes = Grouper.everyPhoto(input, capacity: 100)
        XCTAssertEqual(stripes.count, 10)
        XCTAssertTrue(stripes.allSatisfy { $0.sum?.count == 1 })
        XCTAssertEqual(stripes.map { $0.sum!.average! }, input.map(\.color))
    }

    func testAllocationTotalsExactlyKAndRespectsCaps() {
        let cases: [([Int], Int)] = [
            ([10, 10, 10], 6),
            ([1, 1, 100], 10),
            ([1000, 1, 1, 1, 2], 20),
            ([5, 5, 5, 5], 19),
            ([7, 3, 3, 3, 3, 3, 3, 3], 9),
            (Array(repeating: 30, count: 366), 4860),
            ((0..<365).map { $0 % 17 + 1 } + [9000], 2430),
        ]
        for (counts, k) in cases {
            let allocation = Grouper.allocate(dayCounts: counts, capacity: k)
            XCTAssertEqual(allocation.reduce(0, +), k, "\(counts.prefix(5)) k=\(k)")
            for (a, n) in zip(allocation, counts) {
                XCTAssertGreaterThanOrEqual(a, 1)
                XCTAssertLessThanOrEqual(a, n)
            }
        }
    }

    func testAllocationIsProportionalWithChronologicalTies() {
        // Remaining 3 groups over equal days: earliest days win the ties.
        XCTAssertEqual(Grouper.allocate(dayCounts: [4, 4, 4, 4, 4], capacity: 8), [2, 2, 2, 1, 1])
        // A dominant day gets most extra groups; small days keep their reserved one.
        XCTAssertEqual(Grouper.allocate(dayCounts: [1, 90, 9], capacity: 12), [1, 9, 2])
        XCTAssertEqual(Grouper.allocate(dayCounts: [2, 100], capacity: 50), [2, 48])
        // The small day's share (1.5 extra) exceeds its room (1); the surplus moves to the other day.
        XCTAssertEqual(Grouper.allocate(dayCounts: [2, 10], capacity: 11), [2, 9])
    }

    func testPartitionBoundaries() {
        XCTAssertEqual(Grouper.partition(count: 10, groups: 3), [0..<3, 3..<6, 6..<10])
        for n in 1...40 {
            for k in 1...n {
                let parts = Grouper.partition(count: n, groups: k)
                XCTAssertEqual(parts.count, k)
                XCTAssertEqual(parts.first?.lowerBound, 0)
                XCTAssertEqual(parts.last?.upperBound, n)
                let sizes = parts.map(\.count)
                XCTAssertLessThanOrEqual(sizes.max()! - sizes.min()!, 1)
                for (a, b) in zip(parts, parts.dropFirst()) { XCTAssertEqual(a.upperBound, b.lowerBound) }
            }
        }
    }

    func testOverflowKeepsOrderStaysWithinDaysAndPreservesWeights() {
        let input = photos(perDay: [40, 1, 0, 25, 300, 2, 0, 0, 77])
        let k = 60
        let stripes = Grouper.everyPhoto(input, capacity: k)
        XCTAssertEqual(stripes.count, k)
        XCTAssertEqual(stripes.reduce(0) { $0 + $1.sum!.count }, input.count)

        // Walk stripes in order: each covers a contiguous run from a single day.
        var cursor = 0
        for stripe in stripes {
            let run = input[cursor..<(cursor + stripe.sum!.count)]
            XCTAssertEqual(Set(run.map(\.day)).count, 1, "Group crosses a day boundary")
            var expected = ColorSum()
            run.forEach { expected.add($0.color) }
            XCTAssertEqual(stripe.sum!.average!.r, expected.average!.r, accuracy: 1e-12)
            cursor += run.count
        }

        // Weighted group averages equal the equal-weight average of source photos.
        var total = ColorSum()
        stripes.forEach { total.add($0.sum!) }
        var direct = ColorSum()
        input.forEach { direct.add($0.color) }
        XCTAssertEqual(total.average!.g, direct.average!.g, accuracy: 1e-12)
        XCTAssertEqual(total.count, direct.count)
    }

    func testRealisticYearOnEveryPosterSize() {
        // ~15,500 photos spread unevenly across 300 days; overflows every poster size.
        var counts: [Int] = []
        var seed: UInt64 = 42
        for _ in 0..<300 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            counts.append(Int(seed >> 59) * 3 + 1 + (counts.count % 40 == 0 ? 120 : 0))
        }
        let input = photos(perDay: counts)
        for size in PrintSize.allCases {
            for orientation in Orientation.allCases {
                let layout = PosterLayout(printSize: size, orientation: orientation)
                let stripes = Grouper.everyPhoto(input, capacity: layout.maxGroups)
                XCTAssertEqual(stripes.count, min(input.count, layout.maxGroups))
                let bounds = layout.stripeBoundaries(count: stripes.count)
                for (a, b) in zip(bounds, bounds.dropFirst()) {
                    XCTAssertGreaterThanOrEqual(b - a, 2, "Stripe thinner than two pixels")
                }
                XCTAssertEqual(bounds.last, layout.barcodeLength)
            }
        }
    }

    func testEveryDaySlotsLeapYearsPartialYearsAndWhiteGaps() {
        let calendar = YearCalendar(timeZone: utc)
        XCTAssertEqual(calendar.daySlots(year: 2024, cutoff: calendar.startOfYear(2026)).count, 366)
        XCTAssertEqual(calendar.daySlots(year: 2025, cutoff: calendar.startOfYear(2026)).count, 365)
        // Current year: January 1 through the cutoff day (Feb 10 = day 41).
        let cutoff = calendar.startOfYear(2026).addingTimeInterval(40 * 86_400 + 3600)
        XCTAssertEqual(calendar.daySlots(year: 2026, cutoff: cutoff).count, 41)

        let input = photos(perDay: [2, 0, 3])
        let slots = calendar.daySlots(year: 2025, cutoff: calendar.startOfYear(2026))
        let stripes = Grouper.everyDay(input, slots: slots)
        XCTAssertEqual(stripes.count, 365)
        XCTAssertEqual(stripes[0].sum?.count, 2)
        XCTAssertNil(stripes[1].sum)
        XCTAssertEqual(stripes[1].rgb8, .white)
        XCTAssertEqual(stripes[2].sum?.count, 3)
        XCTAssertTrue(stripes[3...].allSatisfy { $0.sum == nil })
    }

    func testChangingSizeRecomputesFromOriginalPhotos() {
        let input = photos(perDay: Array(repeating: 20, count: 200)) // 4,000 photos
        let small = Grouper.everyPhoto(input, capacity: PosterLayout(printSize: .size12x18, orientation: .landscape).maxGroups)
        let large = Grouper.everyPhoto(input, capacity: PosterLayout(printSize: .size24x36, orientation: .landscape).maxGroups)
        XCTAssertEqual(small.count, 2430)
        XCTAssertEqual(large.count, 4000)
        XCTAssertTrue(large.allSatisfy { $0.sum?.count == 1 })
    }

    func testPreviewResamplingAveragesInLinearLight() {
        let black = Stripe(sum: ColorSum(LinearRGB(r: 0, g: 0, b: 0)))
        let white = Stripe(sum: ColorSum(.white))
        let colors = StripeGeometry.previewColors([black, white, black, white], pixels: 2)
        XCTAssertEqual(colors.count, 2)
        // Linear 0.5 encodes to sRGB 188, not 128.
        XCTAssertEqual(colors[0], RGB8(r: 188, g: 188, b: 188))
        XCTAssertEqual(StripeGeometry.previewColors([black, white], pixels: 10), [RGB8(r: 0, g: 0, b: 0), .white])
    }
}
