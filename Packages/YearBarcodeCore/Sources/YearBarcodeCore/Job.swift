import Foundation

/// Lifecycle of one generation job. Every non-terminal state is resumable
/// from the manifest checkpoint.
public enum JobStatus: String, Codable, Sendable {
    case analyzing
    case paused
    /// Stopped by something outside the user's control; Resume continues.
    case interrupted
    case cancelled
    /// All items reached a final state (some may still be retryable downloads).
    case finished
}

public enum InterruptionReason: String, Codable, Sendable {
    case accessRevoked
    case systemExpired
    case appTerminated
    case storageFull
    case failed

    public var message: String {
        switch self {
        case .accessRevoked: return "Photo access was turned off or limited. Allow access in Settings, then resume."
        case .systemExpired: return "The system stopped background processing. Open the app to resume."
        case .appTerminated: return "Processing stopped when the app was closed. Resume to continue where it left off."
        case .storageFull: return "The device is out of storage. Free some space, then resume."
        case .failed: return "Something went wrong. Resume to try again."
        }
    }
}

public enum JobPhase: String, Codable, Sendable {
    case snapshot = "Taking snapshot"
    case analyzing = "Analyzing colors"
    case grouping = "Building barcode"
    case done = "Done"
}

public struct JobProgress: Sendable, Equatable {
    public var phase: JobPhase
    public var processed: Int
    public var total: Int
    public var status: JobStatus

    public init(phase: JobPhase, processed: Int, total: Int, status: JobStatus) {
        self.phase = phase
        self.processed = processed
        self.total = total
        self.status = status
    }

    public var fraction: Double { total == 0 ? 1 : Double(processed) / Double(total) }
}

/// Valid user-facing transitions.
public enum JobTransitions {
    public static func canResume(_ status: JobStatus) -> Bool {
        status == .paused || status == .interrupted
    }

    public static func canPause(_ status: JobStatus) -> Bool {
        status == .analyzing
    }

    public static func canCancel(_ status: JobStatus) -> Bool {
        status == .analyzing || status == .paused || status == .interrupted
    }

    /// On launch, a job still marked analyzing was killed (force quit, crash, OS).
    public static func recoveredOnLaunch(_ status: JobStatus) -> (JobStatus, InterruptionReason?) {
        status == .analyzing ? (.interrupted, .appTerminated) : (status, nil)
    }
}
