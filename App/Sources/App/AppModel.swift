import Foundation
import Observation
import UIKit
import YearBarcodeCore

enum Route: Hashable {
    case progress(UUID)
    case artwork(UUID)
    case customize(UUID)
}

@MainActor
@Observable
final class AppModel {
    let library: PhotoLibraryService
    let purchases = PurchaseManager()
    @ObservationIgnored let database: Database
    @ObservationIgnored let engine: GenerationEngine
    @ObservationIgnored private var runner: JobRunner!
    @ObservationIgnored var sessions: [UUID: ArtworkSession] = [:]

    var authorization: LibraryAuthorization
    var years: [Int] = []
    var isLoadingYears = false
    var generations: [GenerationRecord] = []
    var progress: [UUID: JobProgress] = [:]
    var path: [Route] = []
    var alert: String?

    init() {
        let library = PhotoLibraryService()
        self.library = library
        let database: Database
        if let opened = try? Database.openDefault() {
            database = opened
        } else {
            // Fall back to a temporary store so the app still works; results won't persist.
            database = try! Database(url: FileManager.default.temporaryDirectory.appendingPathComponent("YearBarcode-fallback.sqlite"))
        }
        self.database = database
        engine = GenerationEngine(database: database, library: library, analyzer: PhotoAnalyzer(library: library))
        authorization = library.authorization
        runner = JobRunner(engine: engine) { [weak self] id, progress in
            self?.handle(progress, for: id)
        }
    }

    func onLaunch() async {
        try? await engine.recoverAfterLaunch()
        refreshGenerations()
        if authorization.access != nil { await refreshYears() }
    }

    func onForeground() async {
        let previous = authorization
        authorization = library.authorization
        if authorization != previous, authorization.access != nil { await refreshYears() }
        refreshGenerations()
    }

    func requestAccess() async {
        authorization = await library.requestAuthorization()
        if authorization.access != nil { await refreshYears() }
    }

    func refreshYears() async {
        isLoadingYears = true
        let library = self.library
        let timeZone = TimeZone.current
        let fromLibrary = await Task.detached { library.availableYears(now: Date(), timeZone: timeZone) }.value
        let saved = generations.map(\.year)
        years = Array(Set(fromLibrary + saved)).sorted(by: >)
        isLoadingYears = false
    }

    func refreshGenerations() {
        generations = (try? database.generations()) ?? []
    }

    // MARK: - Jobs

    func generate(year: Int, settings: ArtworkSettings) async {
        guard let access = authorization.access else { return }
        do {
            let snapshot = try await engine.createGeneration(year: year, settings: settings, access: access)
            refreshGenerations()
            progress[snapshot.id] = JobProgress(phase: .analyzing, processed: 0, total: snapshot.entries.count, status: .analyzing)
            path.append(.progress(snapshot.id))
            runner.start(snapshot.id)
        } catch SnapshotError.futureYear {
            alert = "Future years are not available."
        } catch {
            alert = "Could not take a snapshot of your library: \(error.localizedDescription)"
        }
    }

    func resume(_ id: UUID, retryDownloads: Bool = false) {
        authorization = library.authorization
        guard authorization.access != nil else {
            alert = InterruptionReason.accessRevoked.message
            return
        }
        if let record = generation(id) {
            progress[id] = JobProgress(phase: .analyzing, processed: record.checkpoint, total: progress[id]?.total ?? record.checkpoint, status: .analyzing)
        }
        runner.start(id, retryDownloads: retryDownloads)
    }

    func pause(_ id: UUID) { runner.pause(id) }

    func cancel(_ id: UUID) {
        runner.cancel(id)
        refreshGenerations()
    }

    func delete(_ id: UUID) {
        runner.cancel(id)
        sessions[id] = nil
        try? database.deleteGeneration(id)
        refreshGenerations()
    }

    func generation(_ id: UUID) -> GenerationRecord? {
        generations.first { $0.id == id } ?? (try? database.generation(id))
    }

    private func handle(_ update: JobProgress, for id: UUID) {
        progress[id] = update
        if update.status != .analyzing {
            refreshGenerations()
            // Results changed; the next visit rebuilds from the database.
            sessions[id] = nil
        }
        if update.status == .finished, path.last == .progress(id) {
            path[path.count - 1] = .artwork(id)
        }
    }

    // MARK: - Results

    func report(for id: UUID) async -> GenerationReport? {
        try? await engine.report(for: id)
    }

    func artwork(for id: UUID) -> ArtworkRecord? {
        try? database.artwork(id)
    }

    func save(_ artwork: ArtworkRecord) {
        try? database.save(artwork)
    }
}
