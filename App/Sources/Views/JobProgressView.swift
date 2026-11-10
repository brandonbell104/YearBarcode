import SwiftUI
import YearBarcodeCore

struct JobProgressView: View {
    @Environment(AppModel.self) private var model
    let generationID: UUID

    /// For the time-remaining estimate.
    @State private var started: (date: Date, processed: Int)?

    private var record: GenerationRecord? { model.generation(generationID) }
    private var progress: JobProgress? { model.progress[generationID] }
    private var status: JobStatus { progress?.status ?? record?.status ?? .interrupted }
    private let barCount = 200

    var body: some View {
        VStack(spacing: 0) {
            NavHeader(backTitle: "Years", title: record.map { $0.isCustomTimeline && !$0.isAlbum ? "Custom Timeline" : $0.title } ?? "", onBack: { model.path.removeAll() })

            liveBarcode.padding(.top, 14)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ArtworkText.formatted(progress?.processed ?? record?.checkpoint ?? 0))
                        .font(.system(size: 52, weight: .heavy))
                        .tracking(-1.8)
                        .monospacedDigit()
                        .foregroundStyle(Theme.primaryText)
                    if let total = progress?.total, total > 0 {
                        Text("of \(ArtworkText.formatted(total))")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
                Text(phaseLine)
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.bodyText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 28)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairline)
                    Capsule()
                        .fill(status == .analyzing ? Theme.accent : Theme.tertiaryText)
                        .frame(width: geometry.size.width * (progress?.fraction ?? 0))
                }
            }
            .frame(height: 6)
            .padding(.top, 16)
            .animation(.easeOut, value: progress?.processed)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(steps.enumerated()), id: \.offset) { item in
                    StepRow(label: item.element.0, state: item.element.1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 26)

            if status == .interrupted, let reason = record?.interruption {
                Text(reason.message)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 18)
            }

            Spacer(minLength: 16)

            Text("You can leave the app. Progress is saved, and you can resume anytime.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.tertiaryText)
                .multilineTextAlignment(.center)
                .padding(.bottom, 16)
            controls
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: status, initial: true) { _, newStatus in
            if newStatus == .analyzing, started == nil {
                started = (Date(), progress?.processed ?? 0)
            } else if newStatus != .analyzing {
                started = nil
            }
        }
    }

    // MARK: - Live barcode

    private var liveBarcode: some View {
        let colors = model.liveColors[generationID] ?? []
        let fraction = progress?.fraction ?? 0
        let filled = min(barCount, Int((Double(barCount) * fraction).rounded()))
        let painted: [Color] = (0..<barCount).map { i in
            guard i < filled, !colors.isEmpty else { return Color(hex: 0xDADADF).opacity(0.6) }
            // Spread the colors we have over the filled part, oldest first.
            return Color(colors[min(colors.count - 1, i * colors.count / max(filled, 1))])
        }
        // Match the chosen poster: landscape fills left to right, portrait top to bottom.
        let portrait = record?.settings.orientation == .portrait
        return StripesView(colors: painted, vertical: !portrait)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .padding(portrait ? 16 : 20)
            .frame(width: portrait ? 190 : nil, height: portrait ? 280 : 260)
            .frame(maxWidth: portrait ? nil : .infinity)
            .background(Color(record?.settings.background ?? .white), in: RoundedRectangle(cornerRadius: portrait ? 18 : 24))
            .shadow(color: .black.opacity(0.55), radius: 30, y: 30)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Barcode filling in as colors are read")
    }

    // MARK: - Text

    private var phaseLine: String {
        switch status {
        case .analyzing:
            if let eta = remaining { return "Reading colors · \(eta)" }
            return "Reading colors"
        case .paused: return "Paused. Tap Resume to continue."
        case .interrupted: return "Interrupted. Tap Resume to continue."
        case .cancelled: return "Cancelled."
        case .finished: return "Done."
        }
    }

    private var remaining: String? {
        guard let started, let progress, progress.total > 0 else { return nil }
        let done = progress.processed - started.processed
        let elapsed = Date().timeIntervalSince(started.date)
        guard done > 20, elapsed > 5 else { return nil }
        let seconds = Double(progress.total - progress.processed) / (Double(done) / elapsed)
        if seconds < 60 { return "less than a minute left" }
        let minutes = Int((seconds / 60).rounded())
        return minutes == 1 ? "about 1 min left" : "about \(minutes) min left"
    }

    private var steps: [(String, StepRow.Phase)] {
        let span = record.map { $0.isAlbum ? "the \($0.title) album" : $0.isCustomTimeline ? $0.title : String($0.year) } ?? "the year"
        var reading = StepRow.Phase.paused
        var building = StepRow.Phase.next
        switch status {
        case .finished:
            reading = .done
            building = .done
        case .analyzing:
            reading = .now
        default:
            break
        }
        return [
            ("Finding photos from \(span)", .done),
            ("Reading colors, skipping screenshots, documents & duplicates", reading),
            ("Building your artwork", building),
        ]
    }

    // MARK: - Controls

    @ViewBuilder private var controls: some View {
        switch status {
        case .analyzing:
            HStack(spacing: 12) {
                Button("Pause") { model.pause(generationID) }.buttonStyle(.secondary)
                Button("Cancel") { model.cancel(generationID) }.buttonStyle(.secondary(Theme.destructive))
            }
        case .paused, .interrupted:
            HStack(spacing: 12) {
                Button("Resume") { model.resume(generationID) }.buttonStyle(.primary)
                Button("Cancel") { model.cancel(generationID) }.buttonStyle(.secondary(Theme.destructive))
            }
        case .finished:
            Button("View Artwork") { model.path.append(.artwork(generationID)) }.buttonStyle(.primary)
        case .cancelled:
            Button("Back to Years") { model.path.removeAll() }.buttonStyle(.secondary)
        }
    }
}

private struct StepRow: View {
    enum Phase { case done, now, paused, next }
    let label: String
    let state: Phase

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(state == .done ? Theme.primaryText : .clear)
                Circle()
                    .strokeBorder(ring, lineWidth: 2)
                if state == .done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(Theme.background)
                }
            }
            .frame(width: 22, height: 22)
            Text(label)
                .font(.system(size: 15, weight: state == .now ? .semibold : .medium))
                .foregroundStyle(state == .done ? Theme.secondaryText : (state == .now ? Theme.primaryText : Theme.tertiaryText))
        }
    }

    private var ring: Color {
        switch state {
        case .done: return Theme.primaryText
        case .now: return Theme.accent
        case .paused: return Theme.tertiaryText
        case .next: return Color(hex: 0x48484A)
        }
    }
}
