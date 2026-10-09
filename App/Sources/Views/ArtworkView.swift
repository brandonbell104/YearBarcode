import SwiftUI
import YearBarcodeCore

struct ArtworkView: View {
    @Environment(AppModel.self) private var model
    let generationID: UUID
    @State private var session: ArtworkSession?
    @State private var showDetails = false

    var body: some View {
        Group {
            if let session, !session.isLoading, let report = session.report {
                content(session: session, report: report)
            } else {
                ProgressView("Loading artwork…")
            }
        }
        .navigationTitle("Artwork")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let session = model.session(for: generationID)
            self.session = session
            if session.report == nil { await session.load() }
        }
        .onChange(of: model.purchases.isUnlocked) {
            Task { await session?.rebuild() }
        }
    }

    @ViewBuilder
    private func content(session: ArtworkSession, report: GenerationReport) -> some View {
        let counts = report.counts
        List {
            Section {
                PosterPreview(image: session.preview, settings: session.artwork.settings)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                VStack(alignment: .leading, spacing: 6) {
                    Text(ArtworkText.title(year: report.snapshot.year, included: counts.included))
                        .font(.title2.bold())
                    if let barcode = session.barcode,
                       let summary = ArtworkText.groupingSummary(barcode, mode: session.artwork.settings.mode) {
                        Text(summary).font(.subheadline).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Details", isExpanded: $showDetails) {
                        VStack(alignment: .leading, spacing: 4) {
                            if let barcode = session.barcode {
                                Text(ArtworkText.details(barcode, counts: counts))
                            }
                            ForEach(ExclusionReason.allCases, id: \.self) { reason in
                                if let n = counts.excluded[reason], n > 0 {
                                    Text("\(reason.label): \(ArtworkText.formatted(n))")
                                }
                            }
                            if counts.unavailable > 0 { Text("Unavailable (deleted or no access): \(ArtworkText.formatted(counts.unavailable))") }
                            if counts.changed > 0 { Text("Edited after Generate: \(ArtworkText.formatted(counts.changed))") }
                            if counts.missingDate + counts.invalidDate > 0 {
                                Text("Skipped, no valid capture date: \(ArtworkText.formatted(counts.missingDate + counts.invalidDate))")
                            }
                            Text("Excluded photos are left out of this artwork only. Nothing in your library is changed.")
                                .foregroundStyle(.tertiary)
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }

            if !counts.isComplete || report.snapshot.access == .limited {
                Section {
                    if report.snapshot.access == .limited {
                        Label("Made with limited photo access. Only permitted photos are included.", systemImage: "exclamationmark.triangle")
                    }
                    if counts.downloadFailed > 0 {
                        Label("\(ArtworkText.formatted(counts.downloadFailed)) photos could not be downloaded from iCloud, so this artwork is incomplete.", systemImage: "icloud.slash")
                        Button("Retry Downloads") {
                            model.resume(generationID, retryDownloads: true)
                            model.path.append(.progress(generationID))
                        }
                    }
                    if counts.pending > 0 {
                        Label("\(ArtworkText.formatted(counts.pending)) photos have not been analyzed yet.", systemImage: "hourglass")
                        Button("Resume") {
                            model.resume(generationID)
                            model.path.append(.progress(generationID))
                        }
                    }
                }
                .foregroundStyle(.orange)
            }

            Section("Layout") {
                SettingsEditor(settings: session.artwork.settings) { settings in
                    Task { await session.update(settings) }
                }
            }

            Section {
                NavigationLink(value: Route.customize(generationID)) {
                    Label("Customize & Export", systemImage: "square.and.arrow.up")
                }
            }
        }
    }
}

struct SettingsEditor: View {
    let settings: ArtworkSettings
    let onChange: (ArtworkSettings) -> Void

    var body: some View {
        Picker("Mode", selection: binding(\.mode)) {
            ForEach(BarcodeMode.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        Text(settings.mode.helpText).font(.footnote).foregroundStyle(.secondary)
        Picker("Orientation", selection: binding(\.orientation)) {
            ForEach(Orientation.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Picker("Print size", selection: binding(\.printSize)) {
            ForEach(PrintSize.allCases, id: \.self) { Text($0.title).tag($0) }
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<ArtworkSettings, T>) -> Binding<T> {
        Binding(get: { settings[keyPath: keyPath] }, set: { value in
            var updated = settings
            updated[keyPath: keyPath] = value
            onChange(updated)
        })
    }
}

struct PosterPreview: View {
    let image: CGImage?
    let settings: ArtworkSettings

    var body: some View {
        let canvas = settings.printSize.canvas(settings.orientation)
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
            } else {
                Color.white.overlay(ProgressView())
            }
        }
        .aspectRatio(CGFloat(canvas.width) / CGFloat(canvas.height), contentMode: .fit)
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .frame(maxWidth: .infinity, maxHeight: 480)
        .accessibilityLabel("Barcode poster preview")
    }
}

extension ExclusionReason {
    var label: String {
        switch self {
        case .document: return "Documents and receipts"
        case .screenshot: return "Screenshots"
        case .downloaded: return "Downloaded images"
        case .meme: return "Memes"
        case .duplicate: return "Duplicates"
        case .burst: return "Burst photos"
        }
    }
}
