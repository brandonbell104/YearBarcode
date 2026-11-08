import SwiftUI
import YearBarcodeCore

struct YearsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var selectedYear: Int?
    @State private var settings = ArtworkSettings.default
    @State private var isGenerating = false
    @State private var showSaved = false

    private var currentYear: Int { Calendar.current.component(.year, from: Date()) }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Spacer()
                        Button { showSaved = true } label: {
                            Image(systemName: "rectangle.split.3x1")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(Theme.primaryText)
                                .frame(width: 44, height: 44)
                                .background(Theme.control, in: Circle())
                        }
                        .accessibilityLabel("Saved posters")
                    }
                    .padding(.horizontal, 16)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Choose a year")
                            .font(.system(size: 34, weight: .heavy))
                            .tracking(-0.8)
                        Text("From the capture dates in your library")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .foregroundStyle(Theme.primaryText)
                    .padding(.horizontal, 24)

                    if model.authorization == .limited {
                        limitedBanner.padding(.horizontal, 24).padding(.top, 14)
                    }

                    yearCards.padding(.top, 18)

                    VStack(alignment: .leading, spacing: 22) {
                        modeSection
                        orientationSection
                        sizeSection
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 120)
                }
            }
            .scrollIndicators(.hidden)

            generateButton
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .background(
                    LinearGradient(colors: [Theme.background.opacity(0), Theme.background], startPoint: .top, endPoint: .center)
                        .ignoresSafeArea()
                )
        }
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await model.refreshYears() }
        .onChange(of: model.years, initial: true) { _, years in
            if selectedYear == nil || !years.contains(selectedYear!) { selectedYear = years.first }
        }
        .sheet(isPresented: $showSaved) { SavedPostersView() }
    }

    // MARK: - Sections

    private var yearCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                if model.isLoadingYears && model.years.isEmpty {
                    ProgressView().tint(Theme.tertiaryText).frame(width: 148, height: 180)
                } else if model.years.isEmpty {
                    Text("No dated photos found.")
                        .foregroundStyle(Theme.secondaryText)
                        .frame(height: 180)
                }
                ForEach(model.years, id: \.self) { year in
                    YearCard(
                        year: year,
                        count: model.yearCounts[year],
                        colors: model.yearPreviews[year] ?? [],
                        tag: tag(for: year),
                        tagIsAccent: year == currentYear,
                        selected: year == selectedYear
                    )
                    .onTapGesture { selectedYear = year }
                    .task { await model.loadYearPreview(year) }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 6)
        }
    }

    private func tag(for year: Int) -> String? {
        if year == currentYear { return "Through today" }
        if model.generations.contains(where: { $0.year == year && $0.status == .finished }) { return "Saved poster" }
        return nil
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Mode")
            PillSegmented(options: BarcodeMode.allCases.map { ($0, $0.title) }, selection: $settings.mode)
            Text(modeHelp)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modeHelp: String {
        guard settings.mode == .everyPhoto, let year = selectedYear, let count = model.yearCounts[year] else {
            return settings.mode.helpText
        }
        return ArtworkText.capacityHint(
            year: year, photoCount: count,
            capacity: PosterLayout(printSize: settings.printSize, orientation: settings.orientation).maxGroups,
            size: settings.printSize, exact: false
        )
    }

    private var orientationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Orientation")
            HStack(spacing: 10) {
                ForEach(Orientation.allCases, id: \.self) { orientation in
                    OrientationCard(orientation: orientation, selected: settings.orientation == orientation)
                        .onTapGesture { settings.orientation = orientation }
                }
            }
        }
    }

    private var sizeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Print size", trailing: "inches · 300 ppi")
            ChipPicker(
                options: PrintSize.allCases.map { ($0, "\($0.shortInches) × \($0.longInches)") },
                selection: $settings.printSize
            )
        }
    }

    private var limitedBanner: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.accent)
                Text("Limited photo access: only the photos you allowed are included. Tap to change in Settings.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.bodyText)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var generateButton: some View {
        Button {
            guard let year = selectedYear else { return }
            isGenerating = true
            Task {
                await model.generate(year: year, settings: settings)
                isGenerating = false
            }
        } label: {
            HStack(spacing: 10) {
                if isGenerating {
                    ProgressView().tint(Theme.background)
                } else {
                    Image(systemName: "barcode")
                    Text("Generate \(selectedYear.map(String.init) ?? "")")
                }
            }
        }
        .buttonStyle(.primary)
        .disabled(selectedYear == nil || isGenerating)
        .opacity(selectedYear == nil ? 0.5 : 1)
    }
}

// MARK: - Cards

private struct YearCard: View {
    let year: Int
    let count: Int?
    let colors: [RGB8]
    let tag: String?
    let tagIsAccent: Bool
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Color.white
                if colors.isEmpty {
                    StripesView(colors: Array(repeating: Color(hex: 0xE5E5EA), count: 1))
                        .padding(10)
                } else {
                    StripesView(colors: colors.map { Color($0) }).padding(10)
                }
            }
            .frame(height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 2) {
                Text(String(year))
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(Theme.primaryText)
                Text(count.map { ArtworkText.photoCount($0) } ?? " ")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                Text(tag ?? " ")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tagIsAccent ? Theme.accent : Theme.tertiaryText)
            }
            .padding(.horizontal, 4)
        }
        .padding(EdgeInsets(top: 8, leading: 8, bottom: 12, trailing: 8))
        .frame(width: 148)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: 22))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct OrientationCard: View {
    let orientation: Orientation
    let selected: Bool

    private let sample: [Color] = [0x6E8FA8, 0x7FA35A, 0xD9A441, 0xC2552E, 0x3E4A5C].map { Color(hex: $0) }

    var body: some View {
        let landscape = orientation == .landscape
        HStack(spacing: 12) {
            StripesView(colors: sample, vertical: landscape)
                .padding(4)
                .frame(width: landscape ? 40 : 28, height: landscape ? 28 : 40)
                .background(.white, in: RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 2) {
                Text(orientation.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.primaryText)
                Text(landscape ? "Oldest at left" : "Oldest at top").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 76)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Saved posters

struct SavedPostersView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.generations.isEmpty {
                    Text("Posters you generate appear here.")
                        .foregroundStyle(Theme.secondaryText)
                        .listRowBackground(Theme.card)
                }
                ForEach(model.generations) { record in
                    Button {
                        dismiss()
                        model.path = [record.status == .finished ? .artwork(record.id) : .progress(record.id)]
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(record.year)).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.primaryText)
                                Text(subtitle(record)).font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(Theme.tertiaryText)
                        }
                    }
                    .listRowBackground(Theme.card)
                }
                .onDelete { offsets in
                    for index in offsets { model.delete(model.generations[index].id) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Saved posters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.tint(Theme.accent) }
            }
        }
    }

    private func subtitle(_ record: GenerationRecord) -> String {
        let created = record.createdAt.formatted(date: .abbreviated, time: .shortened)
        switch record.status {
        case .finished: return "\(record.settings.printSize.shortInches) × \(record.settings.printSize.longInches) · \(created)"
        case .analyzing: return "Analyzing…"
        case .paused: return "Paused"
        case .interrupted: return "Interrupted · tap to resume"
        case .cancelled: return "Cancelled"
        }
    }
}
