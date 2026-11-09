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
                ProgressView().tint(Theme.tertiaryText).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
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
        let settings = session.artwork.settings
        VStack(spacing: 0) {
            NavHeader(backTitle: "Years", title: String(report.snapshot.year), onBack: { model.path.removeAll() }) {
                Button {
                    var flipped = settings
                    flipped.orientation = settings.orientation == .landscape ? .portrait : .landscape
                    Task { await session.update(flipped) }
                } label: {
                    Image(systemName: "rectangle.portrait.rotate")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.primaryText)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Switch orientation")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PosterWell(image: session.preview, settings: settings)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(ArtworkText.title(year: report.snapshot.year, included: counts.included).replacingOccurrences(of: " - ", with: " · "))
                            .font(.system(size: 24, weight: .heavy))
                            .tracking(-0.5)
                            .foregroundStyle(Theme.primaryText)
                        if let barcode = session.barcode, let summary = ArtworkText.groupingSummary(barcode, mode: settings.mode) {
                            Text(summary)
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 18)

                    details(session: session, counts: counts)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                    if !counts.isComplete || report.snapshot.access == .limited {
                        warnings(report: report, counts: counts)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        PillSegmented(
                            options: BarcodeMode.allCases.map { ($0, $0.title) },
                            selection: binding(session, \.mode),
                            height: 36
                        )
                        PillSegmented(
                            options: StripeStyle.allCases.map { ($0, $0.title) },
                            selection: binding(session, \.stripeStyle),
                            height: 36
                        )
                        .disabled(!report.supportsSqueezed && settings.stripeStyle == .solid)
                        .opacity(!report.supportsSqueezed && settings.stripeStyle == .solid ? 0.5 : 1)
                        SectionLabel("Size", trailing: sizeDetail(settings)).padding(.top, 4)
                        ChipPicker(
                            options: SizeChoice.all.map { ($0, $0.title) },
                            selection: sizeBinding(session),
                            height: 40
                        )
                        if !report.supportsSqueezed {
                            Text("Squeezed stripes need photo details this poster was made without. Generate \(String(report.snapshot.year)) again to use them.")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.tertiaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if settings.stripeStyle == .squeezed {
                            Text(StripeStyle.squeezed.helpText)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if settings.mode == .everyPhoto {
                            Text(ArtworkText.capacityHint(
                                year: report.snapshot.year,
                                photoCount: counts.included,
                                capacity: PosterLayout(settings: settings).maxGroups,
                                sizeTitle: settings.wallpaper == nil ? "\(settings.sizeTitle) poster" : "wallpaper",
                                exact: true
                            ))
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(settings.mode.helpText)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 110)
                }
            }
            .scrollIndicators(.hidden)
            .overlay(alignment: .bottom) {
                Button("Customize & Export") { model.path.append(.customize(generationID)) }
                    .buttonStyle(.primary)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                    .background(
                        LinearGradient(colors: [Theme.background.opacity(0), Theme.background], startPoint: .top, endPoint: .center)
                            .ignoresSafeArea()
                    )
            }
        }
    }

    // MARK: - Details

    private func details(session: ArtworkSession, counts: GenerationCounts) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.snappy) { showDetails.toggle() }
            } label: {
                HStack {
                    Text("Details").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryText)
                        .rotationEffect(.degrees(showDetails ? 90 : 0))
                }
                .foregroundStyle(Theme.primaryText)
                .padding(.horizontal, 16)
                .frame(height: 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showDetails ? "Expanded" : "Collapsed")

            if showDetails {
                VStack(spacing: 0) {
                    ForEach(detailRows(session: session, counts: counts), id: \.0) { row in
                        HStack {
                            Text(row.0).foregroundStyle(Theme.secondaryText)
                            Spacer()
                            Text(row.1).fontWeight(.semibold).monospacedDigit().foregroundStyle(Theme.primaryText)
                        }
                        .font(.system(size: 14))
                        .frame(minHeight: 32)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
                    }
                    Text("Excluded photos are left out of this artwork only. Nothing in your library is changed.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
                .padding(.horizontal, 16)
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private func detailRows(session: ArtworkSession, counts: GenerationCounts) -> [(String, String)] {
        var rows: [(String, String)] = [("Included photos", ArtworkText.formatted(counts.included))]
        if let barcode = session.barcode {
            switch session.artwork.settings.mode {
            case .everyPhoto: rows.append(("Color groups", ArtworkText.formatted(barcode.stripes.count)))
            case .everyDay: rows.append(("Days with photos", ArtworkText.formatted(barcode.stripes.count)))
            }
        }
        rows.append(("Excluded", ArtworkText.formatted(counts.excludedTotal)))
        for reason in ExclusionReason.allCases {
            if let n = counts.excluded[reason], n > 0 { rows.append(("   \(reason.label)", ArtworkText.formatted(n))) }
        }
        rows.append(("Unavailable", ArtworkText.formatted(counts.unavailable)))
        if counts.changed > 0 { rows.append(("Edited after Generate", ArtworkText.formatted(counts.changed))) }
        if counts.missingDate + counts.invalidDate > 0 {
            rows.append(("No capture date", ArtworkText.formatted(counts.missingDate + counts.invalidDate)))
        }
        return rows
    }

    // MARK: - Warnings

    private func warnings(report: GenerationReport, counts: GenerationCounts) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if report.snapshot.access == .limited {
                warningLine("exclamationmark.triangle.fill", "Made with limited photo access. Only permitted photos are included.")
            }
            if counts.downloadFailed > 0 {
                warningLine("icloud.slash", "\(ArtworkText.formatted(counts.downloadFailed)) photos couldn't be downloaded from iCloud, so this artwork is incomplete.")
                Button("Retry Downloads") {
                    model.resume(generationID, retryDownloads: true)
                    model.path.append(.progress(generationID))
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
            }
            if counts.pending > 0 {
                warningLine("hourglass", "\(ArtworkText.formatted(counts.pending)) photos haven't been analyzed yet.")
                Button("Resume") {
                    model.resume(generationID)
                    model.path.append(.progress(generationID))
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private func warningLine(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.accent)
            Text(text).font(.system(size: 14)).foregroundStyle(Theme.bodyText)
        }
    }

    private func sizeDetail(_ settings: ArtworkSettings) -> String {
        let canvas = settings.canvas
        return settings.wallpaper == nil
            ? "inches · 300 ppi"
            : "This iPhone · \(canvas.width) × \(canvas.height)"
    }

    /// Print sizes plus a wallpaper sized to this iPhone's screen.
    private func sizeBinding(_ session: ArtworkSession) -> Binding<SizeChoice> {
        Binding(
            get: {
                let settings = session.artwork.settings
                return settings.wallpaper == nil ? .print(settings.printSize) : .wallpaper
            },
            set: { choice in
                var updated = session.artwork.settings
                switch choice {
                case .print(let size):
                    updated.printSize = size
                    updated.wallpaper = nil
                case .wallpaper:
                    updated.wallpaper = DeviceScreen.wallpaperSize
                    updated.orientation = .portrait
                }
                Task { await session.update(updated) }
            }
        )
    }

    private func binding<T>(_ session: ArtworkSession, _ keyPath: WritableKeyPath<ArtworkSettings, T>) -> Binding<T> {
        Binding(
            get: { session.artwork.settings[keyPath: keyPath] },
            set: { value in
                var updated = session.artwork.settings
                updated[keyPath: keyPath] = value
                Task { await session.update(updated) }
            }
        )
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

enum SizeChoice: Hashable {
    case print(PrintSize)
    case wallpaper

    static let all: [SizeChoice] = PrintSize.allCases.map { .print($0) } + [.wallpaper]

    var title: String {
        switch self {
        case .print(let size): return "\(size.shortInches)×\(size.longInches)"
        case .wallpaper: return "Wallpaper"
        }
    }
}

/// The exact screen of the iPhone the app is running on.
enum DeviceScreen {
    /// Upright pixel size of the display, e.g. 1179 × 2556 on iPhone 16 Pro.
    @MainActor static var wallpaperSize: PixelSize {
        let bounds = UIScreen.main.nativeBounds
        let a = Int(bounds.width.rounded()), b = Int(bounds.height.rounded())
        return PixelSize(width: min(a, b), height: max(a, b))
    }
}
