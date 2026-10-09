import SwiftUI
import YearBarcodeCore

struct JobProgressView: View {
    @Environment(AppModel.self) private var model
    let generationID: UUID

    private var record: GenerationRecord? { model.generation(generationID) }
    private var progress: JobProgress? { model.progress[generationID] }
    private var status: JobStatus { progress?.status ?? record?.status ?? .interrupted }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            if let record {
                Text(String(record.year)).font(.system(size: 56, weight: .semibold, design: .rounded))
            }

            if let progress {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                Text("\(ArtworkText.formatted(progress.processed)) of \(ArtworkText.formatted(progress.total)) photos")
                    .font(.headline)
                    .monospacedDigit()
                Text(statusText).font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text(statusText).font(.headline)
            }

            if status == .interrupted, let reason = record?.interruption {
                Text(reason.message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            Text("You can leave the app; processing continues while iOS allows it and resumes from where it stopped.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)

            Spacer()
            controls
        }
        .padding(24)
        .navigationTitle("Analyzing")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusText: String {
        switch status {
        case .analyzing: return progress?.phase.rawValue ?? "Analyzing colors"
        case .paused: return "Paused"
        case .interrupted: return "Interrupted"
        case .cancelled: return "Cancelled"
        case .finished: return "Done"
        }
    }

    @ViewBuilder private var controls: some View {
        switch status {
        case .analyzing:
            HStack {
                Button("Pause") { model.pause(generationID) }.buttonStyle(.bordered)
                Button("Cancel", role: .destructive) { model.cancel(generationID) }.buttonStyle(.bordered)
            }
        case .paused, .interrupted:
            HStack {
                Button("Resume") { model.resume(generationID) }.buttonStyle(.borderedProminent)
                Button("Cancel", role: .destructive) { model.cancel(generationID) }.buttonStyle(.bordered)
            }
        case .finished:
            Button("View Artwork") { model.path.append(.artwork(generationID)) }.buttonStyle(.borderedProminent)
        case .cancelled:
            Button("Start Over") { model.path.removeAll() }.buttonStyle(.bordered)
        }
    }
}
