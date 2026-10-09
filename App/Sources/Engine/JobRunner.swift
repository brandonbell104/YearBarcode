import BackgroundTasks
import UIKit
import YearBarcodeCore

/// Starts generation jobs from a user action and keeps them going while the
/// app is backgrounded using BGContinuedProcessingTask (iOS 26). The system
/// may queue, expire, or let the user cancel the task; every stop leaves a
/// resumable checkpoint. There are no recurring jobs.
@MainActor
final class JobRunner {
    private let engine: GenerationEngine
    private let onProgress: @MainActor (UUID, JobProgress) -> Void
    private var foregroundTasks: [UUID: Task<Void, Never>] = [:]

    init(engine: GenerationEngine, onProgress: @escaping @MainActor (UUID, JobProgress) -> Void) {
        self.engine = engine
        self.onProgress = onProgress
    }

    /// Must be called from the foreground in response to Generate or Resume.
    func start(_ id: UUID, retryDownloads: Bool = false) {
        if !submitContinuedProcessing(id, retryDownloads: retryDownloads) {
            startInForeground(id, retryDownloads: retryDownloads)
        }
    }

    func pause(_ id: UUID) {
        Task { try? await engine.requestStop(id, .pause) }
    }

    func cancel(_ id: UUID) {
        Task { try? await engine.requestStop(id, .cancel) }
    }

    // MARK: - Continued processing

    private func submitContinuedProcessing(_ id: UUID, retryDownloads: Bool) -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        // Each submission needs a fresh identifier matching the wildcard in Info.plist.
        let identifier = "\(bundleID).generation.\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.run(id, retryDownloads: retryDownloads, in: task)
            }
        }
        guard registered else { return false }

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Year Barcode",
            subtitle: "Analyzing photo colors on this iPhone"
        )
        // Start now or not at all; if the system declines, run in the foreground instead.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            return false
        }
    }

    private func run(_ id: UUID, retryDownloads: Bool, in task: BGContinuedProcessingTask) {
        let engine = self.engine
        task.progress.totalUnitCount = 1
        task.expirationHandler = {
            // System expiry or the user cancelling from the system UI: checkpoint and stop.
            Task { try? await engine.requestStop(id, .interrupt(.systemExpired)) }
        }
        Task { @MainActor in
            let status = await engine.run(id, retryDownloads: retryDownloads) { progress in
                Task { @MainActor [weak self] in
                    task.progress.totalUnitCount = Int64(max(progress.total, 1))
                    task.progress.completedUnitCount = Int64(progress.processed)
                    task.updateTitle("Year Barcode", subtitle: "\(progress.processed) of \(progress.total) photos analyzed")
                    self?.onProgress(id, progress)
                }
            }
            task.setTaskCompleted(success: status == .finished)
        }
    }

    // MARK: - Foreground fallback

    private func startInForeground(_ id: UUID, retryDownloads: Bool) {
        guard foregroundTasks[id] == nil else { return }
        let engine = self.engine
        var backgroundID: UIBackgroundTaskIdentifier = .invalid
        backgroundID = UIApplication.shared.beginBackgroundTask(withName: "Checkpoint generation") {
            // Out of time: request a checkpointed stop; Resume continues later.
            Task { try? await engine.requestStop(id, .interrupt(.systemExpired)) }
        }
        foregroundTasks[id] = Task { @MainActor [weak self] in
            _ = await engine.run(id, retryDownloads: retryDownloads) { progress in
                Task { @MainActor [weak self] in self?.onProgress(id, progress) }
            }
            self?.foregroundTasks[id] = nil
            if backgroundID != .invalid { UIApplication.shared.endBackgroundTask(backgroundID) }
        }
    }
}
