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
        XCTAssertEqual(data.stripes.count, 2, "Two days have included photos")
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

extension SnapshotAndFilterTests {
    func testYearCountsSkipFutureAndUndatedPhotos() {
        let counts = SnapshotBuilder.yearCounts(
            captureDates: [date(2024, 5, 1), nil, date(2026, 1, 2), date(2026, 3, 1), date(2030, 1, 1), date(2024, 6, 1)],
            now: date(2026, 10, 9), timeZone: tz
        )
        XCTAssertEqual(counts, [2024: 2, 2026: 2])
    }

    func testSettingsWithoutBackgroundDecodeAsWhite() throws {
        let legacy = Data(#"{"mode":"everyDay","printSize":"size18x24","orientation":"portrait"}"#.utf8)
        let settings = try JSONDecoder().decode(ArtworkSettings.self, from: legacy)
        XCTAssertEqual(settings.background, .white)
        XCTAssertEqual(settings.mode, .everyDay)

        var dark = settings
        dark.background = RGB8(r: 20, g: 24, b: 30)
        let roundTrip = try JSONDecoder().decode(ArtworkSettings.self, from: JSONEncoder().encode(dark))
        XCTAssertEqual(roundTrip, dark)
        XCTAssertTrue(dark.background.prefersLightText)
        XCTAssertFalse(RGB8.white.prefersLightText)

        // Border photos saved before free placement existed still decode.
        let photo = try JSONDecoder().decode(BorderPhoto.self, from: Data(#"{"assetID":"a","zoom":1,"centerX":0.5,"centerY":0.5}"#.utf8))
        XCTAssertNil(photo.placement)
    }
}

private extension ImageFingerprint {
    func with(content: UInt64) -> ImageFingerprint {
        ImageFingerprint(differenceHash: differenceHash, contentHash: content)
    }
}

final class PosterDesignTests: XCTestCase {
    func testLegacyPhotoListBecomesStandardDesign() throws {
        let legacy = try JSONEncoder().encode([BorderPhoto(assetID: "a"), BorderPhoto(assetID: "b")])
        let design = PosterDesign.decode(legacy)
        XCTAssertEqual(design.layers.map(\.id), ["text:year", "text:count", "photo:a", "photo:b"])
        XCTAssertEqual(design.photos.map(\.assetID), ["a", "b"])

        let roundTrip = PosterDesign.decode(try JSONEncoder().encode(design))
        XCTAssertEqual(roundTrip, design)
        XCTAssertEqual(PosterDesign.decode(Data("garbage".utf8)), .standard())
    }

    func testReorderingLayers() {
        var design = PosterDesign.standard(photos: [BorderPhoto(assetID: "a"), BorderPhoto(assetID: "b")])
        design.move(from: 3, to: 0) // photo b to the bottom
        XCTAssertEqual(design.layers.map(\.id), ["photo:b", "text:year", "text:count", "photo:a"])
        design.move(from: 0, to: 3) // and back to the top
        XCTAssertEqual(design.layers.map(\.id), ["text:year", "text:count", "photo:a", "photo:b"])
        design.move(from: 9, to: 0) // out of range is ignored
        XCTAssertEqual(design.layers.count, 4)
    }

    func testTextLayerDefaultsMatchTheClassicLabels() {
        let layout = PosterLayout(printSize: .size24x36, orientation: .landscape)
        let year = TextLayer(id: "year", role: .year)
        XCTAssertEqual(year.displayText(year: 2025, includedPhotos: 10), "2025")
        XCTAssertEqual(TextLayer(role: .photoCount).displayText(year: 2025, includedPhotos: 7842, locale: Locale(identifier: "en_US")), "7,842 photos")
        XCTAssertEqual(TextLayer(role: .year, text: "Our year").displayText(year: 2025, includedPhotos: 1), "Our year")

        let position = layout.position(for: year)
        XCTAssertEqual(position.centerY * 7200, Double(layout.yearLabel.y) + Double(layout.yearLabel.height) / 2, accuracy: 1)
        XCTAssertEqual(layout.fontSize(for: year), Double(layout.yearLabel.height) / 1.25, accuracy: 1)
        // Sizes are clamped.
        XCTAssertEqual(layout.fontSize(for: TextLayer(role: .custom, size: 5)), TextLayer.maxSize * 7200, accuracy: 1e-6)
    }

    func testPhotosBeyondTheDefaultSlotsStayOnThePoster() {
        let layout = PosterLayout(printSize: .size18x24, orientation: .portrait)
        for index in 0..<PosterDesign.maxPhotos {
            let placement = layout.defaultPlacement(index: index, count: PosterDesign.maxPhotos, aspect: 0.75)
            XCTAssertTrue(layout.isValid(placement), "photo \(index)")
        }
    }
}

final class CustomTimelineTests: XCTestCase {
    let tz = TimeZone(identifier: "America/New_York")!

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testRangeIncludesWholeFirstAndLastDaysAcrossYears() throws {
        let assets = [
            LibraryAssetDescriptor(assetID: "before", captureDate: date(2024, 12, 19, 23), revision: "r"),
            LibraryAssetDescriptor(assetID: "first", captureDate: date(2024, 12, 20, 0), revision: "r"),
            LibraryAssetDescriptor(assetID: "newyear", captureDate: date(2025, 1, 1, 9), revision: "r"),
            LibraryAssetDescriptor(assetID: "last", captureDate: date(2025, 1, 5, 23), revision: "r"),
            LibraryAssetDescriptor(assetID: "after", captureDate: date(2025, 1, 6, 0), revision: "r"),
        ]
        let snapshot = try SnapshotBuilder.build(
            from: date(2024, 12, 20, 15), through: date(2025, 1, 5, 8), cutoff: date(2026, 1, 1),
            timeZone: tz, settings: .default, access: .full, assets: assets
        )
        XCTAssertEqual(snapshot.entries.map(\.assetID), ["first", "newyear", "last"])
        XCTAssertEqual(snapshot.year, 2024)
        XCTAssertNotNil(snapshot.rangeStart)
        XCTAssertEqual(
            TimelineTitle.make(year: 2024, start: snapshot.rangeStart, end: snapshot.rangeEnd, timeZone: tz, locale: Locale(identifier: "en_US")),
            "Dec 20, 2024 – Jan 5, 2025"
        )
        XCTAssertEqual(
            TimelineTitle.make(year: 2025, start: date(2025, 3, 3), end: date(2025, 6, 8), timeZone: tz, locale: Locale(identifier: "en_US")),
            "Mar 3 – Jun 8, 2025"
        )
        XCTAssertEqual(TimelineTitle.make(year: 2025, start: nil, end: nil, timeZone: tz), "2025")
    }

    func testAlbumUsesEveryDatedPhotoAcrossYearsAndItsName() throws {
        let assets = [
            LibraryAssetDescriptor(assetID: "old", captureDate: date(2019, 7, 4, 12), revision: "r"),
            LibraryAssetDescriptor(assetID: "new", captureDate: date(2025, 2, 1, 8), revision: "r"),
            LibraryAssetDescriptor(assetID: "undated", captureDate: nil, revision: "r"),
            LibraryAssetDescriptor(assetID: "future", captureDate: date(2026, 6, 1), revision: "r"),
            LibraryAssetDescriptor(assetID: "old", captureDate: date(2019, 7, 4, 12), revision: "r"),
        ]
        let snapshot = try SnapshotBuilder.build(
            album: "  Emma ", cutoff: date(2026, 1, 1), timeZone: tz, settings: .default, access: .full, assets: assets
        )
        XCTAssertEqual(snapshot.entries.map(\.assetID), ["old", "new"])
        XCTAssertEqual(snapshot.missingDateCount, 1)
        XCTAssertEqual(snapshot.year, 2019)
        XCTAssertEqual(snapshot.title, "Emma")
        XCTAssertNotNil(snapshot.rangeStart)

        // Survives a round trip (older snapshots without the field still decode).
        let decoded = try JSONDecoder().decode(GenerationSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.albumTitle, "Emma")

        XCTAssertThrowsError(try SnapshotBuilder.build(
            album: "Empty", cutoff: date(2026, 1, 1), timeZone: tz, settings: .default, access: .full,
            assets: [LibraryAssetDescriptor(assetID: "u", captureDate: nil, revision: "r")]
        )) { XCTAssertEqual($0 as? SnapshotError, .emptyAlbum) }
    }

    func testInvalidRanges() {
        XCTAssertThrowsError(try SnapshotBuilder.build(
            from: date(2025, 5, 2), through: date(2025, 5, 1), cutoff: date(2026, 1, 1),
            timeZone: tz, settings: .default, access: .full, assets: []
        )) { XCTAssertEqual($0 as? SnapshotError, .invalidRange) }
        XCTAssertThrowsError(try SnapshotBuilder.build(
            from: date(2027, 1, 1), through: date(2027, 2, 1), cutoff: date(2026, 1, 1),
            timeZone: tz, settings: .default, access: .full, assets: []
        )) { XCTAssertEqual($0 as? SnapshotError, .invalidRange) }
    }

    func testMoreDaysThanStripesStillFits() {
        let calendar = YearCalendar(timeZone: tz)
        // 50 days with 3 photos each, but only 20 stripes available.
        var photos: [IncludedPhoto] = []
        for d in 0..<50 {
            for i in 0..<3 {
                let when = calendar.startOfYear(2025).addingTimeInterval(Double(d) * 86_400 + Double(i) * 60 + 3600)
                photos.append(IncludedPhoto(assetID: "\(d)-\(i)", captureDate: when, day: calendar.dayKey(for: when), color: LinearRGB(r: 0.5, g: 0.5, b: 0.5)))
            }
        }
        let everyPhoto = Grouper.barcode(photos: photos, mode: .everyPhoto, capacity: 20)
        XCTAssertEqual(everyPhoto.stripes.count, 20)
        XCTAssertEqual(everyPhoto.stripes.reduce(0) { $0 + ($1.sum?.count ?? 0) }, 150)
        let everyDay = Grouper.barcode(photos: photos, mode: .everyDay, capacity: 20)
        XCTAssertEqual(everyDay.stripes.count, 20)
        XCTAssertTrue(everyDay.groupedToFit)
        XCTAssertEqual(everyDay.stripes.reduce(0) { $0 + ($1.sum?.count ?? 0) }, 150)
    }
}
