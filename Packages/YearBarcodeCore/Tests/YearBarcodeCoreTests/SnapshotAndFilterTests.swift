import XCTest
@testable import YearBarcodeCore

final class SnapshotAndFilterTests: XCTestCase {
    let tz = TimeZone(identifier: "America/New_York")!

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, tz: TimeZone? = nil) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz ?? self.tz
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testSnapshotFreezesYearAndCutoff() throws {
        let cutoff = date(2026, 3, 1, 9)
        let assets = [
            LibraryAssetDescriptor(assetID: "b", captureDate: date(2026, 1, 1, 0), revision: "1"),
            LibraryAssetDescriptor(assetID: "a", captureDate: date(2026, 1, 1, 0), revision: "1"),
            LibraryAssetDescriptor(assetID: "late", captureDate: date(2026, 3, 1, 10), revision: "1"),
            LibraryAssetDescriptor(assetID: "last-year", captureDate: date(2025, 12, 31, 23), revision: "1"),
            LibraryAssetDescriptor(assetID: "nodate", captureDate: nil, revision: "1"),
            LibraryAssetDescriptor(assetID: "ancient", captureDate: Date(timeIntervalSince1970: -6_000_000_000), revision: "1"),
            LibraryAssetDescriptor(assetID: "a", captureDate: date(2026, 1, 1, 0), revision: "1"),
        ]
        let snapshot = try SnapshotBuilder.build(year: 2026, cutoff: cutoff, timeZone: tz, settings: .default, access: .limited, assets: assets)
        XCTAssertEqual(snapshot.entries.map(\.assetID), ["a", "b"], "Sorted by date then ID; after-cutoff and other years excluded")
        XCTAssertEqual(snapshot.missingDateCount, 1)
        XCTAssertEqual(snapshot.invalidDateCount, 1)
        XCTAssertEqual(snapshot.access, .limited)
        XCTAssertEqual(snapshot.timeZoneIdentifier, "America/New_York")
        XCTAssertEqual(snapshot.entries[0].day, DayKey(year: 2026, ordinal: 1))
    }

    func testFutureYearIsUnavailable() {
        XCTAssertThrowsError(try SnapshotBuilder.build(
            year: 2027, cutoff: date(2026, 10, 9), timeZone: tz, settings: .default, access: .full, assets: []
        )) { XCTAssertEqual($0 as? SnapshotError, .futureYear(2027)) }

        let years = SnapshotBuilder.availableYears(
            captureDates: [date(2024, 5, 1), nil, date(2026, 1, 2), date(2030, 1, 1), date(2024, 6, 1)],
            now: date(2026, 10, 9), timeZone: tz
        )
        XCTAssertEqual(years, [2026, 2024])
    }

    func testDaysUseSavedTimeZone() throws {
        // 03:00 UTC on Jan 2 is still Jan 1 in New York.
        let instant = date(2025, 1, 2, 3, tz: TimeZone(identifier: "UTC")!)
        let snapshot = try SnapshotBuilder.build(
            year: 2025, cutoff: date(2026, 1, 5), timeZone: tz, settings: .default, access: .full,
            assets: [LibraryAssetDescriptor(assetID: "x", captureDate: instant, revision: "r")]
        )
        XCTAssertEqual(snapshot.entries.first?.day, DayKey(year: 2025, ordinal: 1))
    }

    func testFilterPolicyIsConservative() {
        var s = FilterSignals()
        XCTAssertNil(FilterPolicy.decide(s).exclusion)

        s.isScreenshotMetadata = true
        XCTAssertEqual(FilterPolicy.decide(s).exclusion, .screenshot)

        s = FilterSignals()
        s.textCoverage = 0.5 // lots of text alone (e.g. a sign) is not enough
        XCTAssertNil(FilterPolicy.decide(s).exclusion)
        s.pageGeometry = 0.9
        XCTAssertEqual(FilterPolicy.decide(s).exclusion, .document)

        s = FilterSignals()
        s.captionBands = true
        XCTAssertNil(FilterPolicy.decide(s).exclusion, "Text layout alone does not prove a meme")
        s.memeClassifier = 0.65
        XCTAssertEqual(FilterPolicy.decide(s).exclusion, .meme)

        s = FilterSignals()
        s.isBurstMember = true
        XCTAssertEqual(FilterPolicy.decide(s).exclusion, .burst)

        s = FilterSignals()
        s.provenance = .camera
        s.downloadedCue = 0.95
        XCTAssertNil(FilterPolicy.decide(s).exclusion, "Camera provenance outranks visual download cues")
    }

    func testDuplicatesKeepDeterministicRepresentative() {
        let base = date(2025, 7, 4, 15)
        let fp = ImageFingerprint(differenceHash: 0b1011_0000, contentHash: 1)
        let near = ImageFingerprint(differenceHash: 0b1011_0011, contentHash: 2) // 2 bits away
        let far = ImageFingerprint(differenceHash: 0xFFFF_0000, contentHash: 3)
        let color = LinearRGB(r: 0.2, g: 0.3, b: 0.4)
        let candidates = [
            DuplicateCandidate(assetID: "z", captureDate: base, color: color, fingerprint: fp),
            DuplicateCandidate(assetID: "y", captureDate: base.addingTimeInterval(30), color: color, fingerprint: near),
            DuplicateCandidate(assetID: "x", captureDate: base.addingTimeInterval(40), color: color, fingerprint: far),
            // Same pixels saved again months later: an exact copy.
            DuplicateCandidate(assetID: "w", captureDate: base.addingTimeInterval(90 * 86_400), color: color, fingerprint: fp),
            // Similar hash but too far apart in time to be confident.
            DuplicateCandidate(assetID: "v", captureDate: base.addingTimeInterval(3600), color: color, fingerprint: near.with(content: 9)),
        ]
        let result = DuplicateResolver.resolve(candidates)
        XCTAssertEqual(result.suppressed, ["y", "w"])
        XCTAssertEqual(result.groupOf["y"], "z")
        XCTAssertEqual(result.groupOf["w"], "z")
        XCTAssertNil(result.groupOf["x"])
        XCTAssertNil(result.groupOf["v"])
        // Order of input does not matter.
        XCTAssertEqual(DuplicateResolver.resolve(candidates.reversed()), result)
    }

    func testReportCountsAndIncludesOnlyAnalyzedPhotos() throws {
        let cutoff = date(2026, 1, 1)
        let descriptors = (0..<6).map {
            LibraryAssetDescriptor(assetID: "p\($0)", captureDate: date(2025, 2, 1 + $0), revision: "r")
        }
        let snapshot = try SnapshotBuilder.build(year: 2025, cutoff: cutoff, timeZone: tz, settings: .default, access: .full, assets: descriptors)
        func analysis(_ id: String, _ exclusion: ExclusionReason? = nil, hash: UInt64) -> PhotoAnalysis {
            PhotoAnalysis(assetID: id, revision: "r", color: LinearRGB(r: 0.5, g: 0.5, b: 0.5), exclusion: exclusion, confidence: 1,
                          fingerprint: ImageFingerprint(differenceHash: hash, contentHash: hash))
        }
        let items = [
            ManifestItem(entry: snapshot.entries[0], status: .analyzed, analysis: analysis("p0", hash: 1)),
            ManifestItem(entry: snapshot.entries[1], status: .analyzed, analysis: analysis("p1", .screenshot, hash: 2)),
            ManifestItem(entry: snapshot.entries[2], status: .analyzed, analysis: analysis("p2", hash: 1)), // exact copy of p0
            ManifestItem(entry: snapshot.entries[3], status: .unavailable, analysis: nil),
            ManifestItem(entry: snapshot.entries[4], status: .downloadFailed, analysis: nil),
            ManifestItem(entry: snapshot.entries[5], status: .analyzed, analysis: analysis("p5", hash: 7)),
        ]
        let report = GenerationReport.make(snapshot: snapshot, items: items)
        XCTAssertEqual(report.included.map(\.assetID), ["p0", "p5"])
        XCTAssertEqual(report.counts.included, 2)
        XCTAssertEqual(report.counts.excluded[.screenshot], 1)
        XCTAssertEqual(report.counts.excluded[.duplicate], 1)
        XCTAssertEqual(report.counts.excludedTotal, 2)
        XCTAssertEqual(report.counts.unavailable, 1)
        XCTAssertEqual(report.counts.downloadFailed, 1)
        XCTAssertFalse(report.counts.isComplete, "A failed download must not look complete")

        let data = report.barcode(for: ArtworkSettings(mode: .everyDay, printSize: .size12x18, orientation: .portrait))
        XCTAssertEqual(data.stripes.count, 365)
        XCTAssertEqual(data.includedPhotoCount, 2)
        XCTAssertEqual(ArtworkText.title(year: 2025, included: 7842, locale: Locale(identifier: "en_US")), "2025 - 7,842 photos")
    }

    func testBorderPhotoCropStaysInsideImage() {
        let photo = BorderPhoto(assetID: "a", zoom: 2, centerX: 0.99, centerY: 0.01)
        let crop = photo.cropRect(imageWidth: 4000, imageHeight: 3000, slotAspect: 4.0 / 5.0)
        XCTAssertEqual(crop.width / crop.height, 0.8, accuracy: 1e-9)
        XCTAssertEqual(crop.height, 1500, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(crop.x, 0)
        XCTAssertGreaterThanOrEqual(crop.y, 0)
        XCTAssertLessThanOrEqual(crop.x + crop.width, 4000 + 1e-9)
        XCTAssertLessThanOrEqual(crop.y + crop.height, 3000 + 1e-9)
    }

    func testJobRecovery() {
        XCTAssertEqual(JobTransitions.recoveredOnLaunch(.analyzing).0, .interrupted)
        XCTAssertEqual(JobTransitions.recoveredOnLaunch(.analyzing).1, .appTerminated)
        XCTAssertEqual(JobTransitions.recoveredOnLaunch(.paused).0, .paused)
        XCTAssertTrue(JobTransitions.canResume(.interrupted))
        XCTAssertFalse(JobTransitions.canResume(.finished))
    }
}

private extension ImageFingerprint {
    func with(content: UInt64) -> ImageFingerprint {
        ImageFingerprint(differenceHash: differenceHash, contentHash: content)
    }
}
