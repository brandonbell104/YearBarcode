import Foundation
import Photos
import YearBarcodeCore

enum StopRequest: Equatable {
    case pause
    case cancel
    case interrupt(InterruptionReason)
}

/// Runs a generation as a resumable job: freeze the snapshot, then analyze
/// manifest items in order, checkpointing every small batch to SQLite.
/// Nothing runs on a schedule; a job runs only after the user taps Generate
/// or Resume.
actor GenerationEngine {
    static let batchSize = 12
    static let parallelism = 3

    private let database: Database
    private let library: PhotoLibraryService
    private let analyzer: PhotoAnalyzer
    private var running: Set<UUID> = []
    private var stopRequests: [UUID: StopRequest] = [:]

    init(database: Database, library: PhotoLibraryService, analyzer: PhotoAnalyzer) {
        self.database = database
        self.library = library
        self.analyzer = analyzer
    }

    // MARK: - Snapshot

    /// Saves the cutoff, time zone, settings and asset manifest at button press.
    func createGeneration(year: Int, settings: ArtworkSettings, access: LibraryAccess) throws -> GenerationSnapshot {
        let cutoff = Date()
        let timeZone = TimeZone.current
        let descriptors = library.descriptors(year: year, cutoff: cutoff, timeZone: timeZone)
        let snapshot = try SnapshotBuilder.build(
            year: year, cutoff: cutoff, timeZone: timeZone, settings: settings, access: access, assets: descriptors
        )
        try database.insert(snapshot: snapshot)
        return snapshot
    }

    /// Marks jobs that were running when the process died as interrupted.
    func recoverAfterLaunch() throws {
        for record in try database.generations() {
            let (status, reason) = JobTransitions.recoveredOnLaunch(record.status)
            if status != record.status { try database.setStatus(status, interruption: reason, for: record.id) }
        }
    }

    func isRunning(_ id: UUID) -> Bool { running.contains(id) }

    func requestStop(_ id: UUID, _ request: StopRequest) throws {
        if running.contains(id) {
            stopRequests[id] = request
        } else if request == .cancel {
            try database.setStatus(.cancelled, for: id)
        }
    }

    // MARK: - Run

    /// Processes pending items until done or stopped. Safe to call again to resume.
    @discardableResult
    func run(_ id: UUID, retryDownloads: Bool = false, progress: @escaping @Sendable (JobProgress) -> Void) async -> JobStatus {
        guard !running.contains(id), let record = try? database.generation(id) else {
            return (try? database.generation(id))?.status ?? .interrupted
        }
        running.insert(id)
        stopRequests[id] = nil
        defer {
            running.remove(id)
            stopRequests[id] = nil
        }

        do {
            if retryDownloads { try database.resetRetryable(id) }
            try database.setStatus(.analyzing, for: id)
            let manifest = try database.manifest(id)
            let total = manifest.count
            var processed = manifest.filter { $0.status != .pending }.count
            let pending = manifest.filter { $0.status == .pending }
            progress(JobProgress(phase: .analyzing, processed: processed, total: total, status: .analyzing))

            var index = 0
            while index < pending.count {
                if let stop = stopRequests[id] { return try finish(id, stop: stop, processed: processed, total: total, progress: progress) }
                if library.authorization == .denied {
                    return try finish(id, stop: .interrupt(.accessRevoked), processed: processed, total: total, progress: progress)
                }
                if Task.isCancelled {
                    return try finish(id, stop: .interrupt(.systemExpired), processed: processed, total: total, progress: progress)
                }

                let batch = Array(pending[index..<min(index + Self.batchSize, pending.count)])
                let updates = await analyze(batch, analysisVersion: record.analysisVersion)
                do {
                    try database.checkpoint(id, updates: updates)
                } catch {
                    return try finish(id, stop: .interrupt(.storageFull), processed: processed, total: total, progress: progress)
                }
                index += batch.count
                processed += batch.count
                progress(JobProgress(phase: .analyzing, processed: processed, total: total, status: .analyzing))
            }

            try database.setStatus(.finished, for: id)
            progress(JobProgress(phase: .done, processed: total, total: total, status: .finished))
            return .finished
        } catch {
            try? database.setStatus(.interrupted, interruption: .failed, for: id)
            progress(JobProgress(phase: .analyzing, processed: 0, total: 0, status: .interrupted))
            return .interrupted
        }
    }

    private func finish(_ id: UUID, stop: StopRequest, processed: Int, total: Int, progress: @Sendable (JobProgress) -> Void) throws -> JobStatus {
        let status: JobStatus
        switch stop {
        case .pause:
            status = .paused
            try database.setStatus(.paused, for: id)
        case .cancel:
            status = .cancelled
            try database.setStatus(.cancelled, for: id)
        case .interrupt(let reason):
            status = .interrupted
            try database.setStatus(.interrupted, interruption: reason, for: id)
        }
        progress(JobProgress(phase: .analyzing, processed: processed, total: total, status: status))
        return status
    }

    /// Analyzes a batch with bounded parallelism. Results keep manifest positions.
    private func analyze(
        _ batch: [(position: Int, entry: ManifestEntry, status: ItemStatus)],
        analysisVersion: Int
    ) async -> [(position: Int, status: ItemStatus, analysis: PhotoAnalysis?)] {
        let assets = library.assets(ids: batch.map { $0.entry.assetID })
        let database = self.database
        let analyzer = self.analyzer

        return await withTaskGroup(of: (Int, ItemStatus, PhotoAnalysis?).self) { group in
            var results: [(position: Int, status: ItemStatus, analysis: PhotoAnalysis?)] = []
            for (offset, item) in batch.enumerated() {
                if offset >= Self.parallelism, let done = await group.next() {
                    results.append((position: done.0, status: done.1, analysis: done.2))
                }
                let asset = assets[item.entry.assetID]
                group.addTask {
                    // Deleted, or hidden by limited access since the snapshot.
                    guard let asset else { return (item.position, .unavailable, nil) }
                    // Edited after the snapshot: report rather than silently using the new version.
                    let current = PhotoLibraryService.revision(of: asset)
                    guard current == item.entry.revision else { return (item.position, .changed, nil) }
                    if let cached = try? database.analysis(assetID: item.entry.assetID, revision: current, version: analysisVersion) {
                        return (item.position, .analyzed, cached)
                    }
                    do {
                        let analysis = try await analyzer.analyze(asset: asset, revision: current)
                        return (item.position, .analyzed, analysis)
                    } catch ImageRequestError.unavailable {
                        return (item.position, .unavailable, nil)
                    } catch {
                        return (item.position, .downloadFailed, nil)
                    }
                }
            }
            for await (position, status, analysis) in group {
                results.append((position: position, status: status, analysis: analysis))
            }
            return results
        }
    }

    // MARK: - Results

    func report(for id: UUID) throws -> GenerationReport? {
        guard let record = try database.generation(id) else { return nil }
        let snapshot = try database.snapshot(for: record)
        return GenerationReport.make(snapshot: snapshot, items: try database.items(for: record))
    }
}
