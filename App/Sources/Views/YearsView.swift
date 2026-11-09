import SwiftUI
import YearBarcodeCore

struct YearsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var selectedYear: Int?
    @State private var settings = ArtworkSettings.default
    @State private var isGenerating = false
    @State private var showSettings = false
    /// Custom timeline: pick any first and last day instead of a year.
    @State private var customSelected = false
    @State private var rangeStart = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var rangeEnd = Date()
    @State private var rangeCount: Int?

    private var currentYear: Int { Calendar.current.component(.year, from: Date()) }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(Theme.primaryText)
                                .frame(width: 44, height: 44)
                                .background(Theme.control, in: Circle())
                        }
                        .accessibilityLabel("Settings")
                        Spacer()
                        Button { model.path.append(.saved) } label: {
                            Image(systemName: "rectangle.split.3x1")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(Theme.primaryText)
                                .frame(width: 44, height: 44)
                                .background(Theme.control, in: Circle())
                                .overlay(alignment: .topTrailing) {
                                    if !model.generations.isEmpty {
                                        Text("\(model.generations.count)")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(Theme.background)
                                            .padding(.horizontal, 5)
                                            .frame(minWidth: 18, minHeight: 18)
                                            .background(Theme.accent, in: Capsule())
                                            .offset(x: 4, y: -4)
                                    }
                                }
                        }
                        .accessibilityLabel("Saved posters, \(model.generations.count)")
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
                        if customSelected { customRangeSection }
                        styleSection
                        orientationSection
                        Text("Mode, print size, border and wallpaper can be changed after generating.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.tertiaryText)
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
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    // MARK: - Sections

    private var yearCards: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                CustomTimelineCard(selected: customSelected, count: customSelected ? rangeCount : nil)
                    .onTapGesture { withAnimation(.snappy) { customSelected = true } }
                if model.isLoadingYears && model.years.isEmpty {
                    ProgressView().tint(Theme.tertiaryText).frame(width: 148, height: 180)
                } else if model.years.isEmpty {
                    Text("No dated photos found.")
                        .foregroundStyle(Theme.secondaryText)
                        .frame(height: 180)
                }
                ForEach(model.years, id: \.self) { year in
                    let latest = model.latestFinished(year: year)
                    YearCard(
                        year: year,
                        count: model.yearCounts[year],
                        colors: latest == nil ? nil : model.yearBarcodes[year],
                        generated: latest != nil,
                        tag: tag(for: year),
                        selected: !customSelected && year == selectedYear
                    )
                    .onTapGesture {
                        withAnimation(.snappy) {
                            customSelected = false
                            selectedYear = year
                        }
                    }
                    .task(id: latest?.id) { await model.loadYearBarcode(year) }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 6)
        }
    }

    private var customRangeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Custom timeline", trailing: rangeCount.map { ArtworkText.photoCount($0) })
            VStack(spacing: 0) {
                DatePicker("From", selection: $rangeStart, in: ...Date(), displayedComponents: .date)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 50)
                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 14)
                DatePicker("To", selection: $rangeEnd, in: rangeStart...Date(), displayedComponents: .date)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 50)
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.primaryText)
            .tint(Theme.accent)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
            Text("Uses every photo taken from the start of the first day through the end of the last day.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
        }
        .onChange(of: rangeStart) { _, start in
            if rangeEnd < start { rangeEnd = start }
        }
        .task(id: [rangeStart, rangeEnd]) {
            let library = model.library
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: rangeStart)
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: rangeEnd)) ?? start
            rangeCount = await Task.detached { library.count(from: start, before: end) }.value
        }
    }

    private func tag(for year: Int) -> String? {
        if let latest = model.latestFinished(year: year) {
            return "Generated " + latest.createdAt.formatted(.dateTime.month(.abbreviated).day())
        }
        if year == currentYear { return "Through today" }
        return "Not generated yet"
    }

    private var styleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Stripe style")
            PillSegmented(options: StripeStyle.allCases.map { ($0, $0.title) }, selection: $settings.stripeStyle)
            Text(settings.stripeStyle.helpText)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
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

    @ViewBuilder
    private var generateButton: some View {
        if customSelected {
            Button {
                isGenerating = true
                Task {
                    await model.generate(timeline: .range(rangeStart, rangeEnd), settings: settings)
                    isGenerating = false
                }
            } label: {
                HStack(spacing: 10) {
                    if isGenerating {
                        ProgressView().tint(Theme.background)
                    } else {
                        Image(systemName: "calendar")
                        Text("Generate Custom Timeline")
                    }
                }
            }
            .buttonStyle(.primary)
            .disabled(isGenerating || rangeCount == 0)
            .opacity(rangeCount == 0 ? 0.5 : 1)
        } else if let year = selectedYear, let latest = model.latestFinished(year: year) {
            HStack(spacing: 10) {
                Button("View \(String(year)) Poster") { model.path.append(.artwork(latest.id)) }
                    .buttonStyle(.primary)
                Button { generate(year) } label: {
                    if isGenerating { ProgressView() } else { Text("Generate again") }
                }
                .buttonStyle(.secondary)
                .frame(maxWidth: 150)
                .disabled(isGenerating)
            }
        } else {
            Button {
                if let year = selectedYear { generate(year) }
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

    private func generate(_ year: Int) {
        isGenerating = true
        Task {
            await model.generate(year: year, settings: settings)
            isGenerating = false
        }
    }
}

// MARK: - Cards

private struct CustomTimelineCard: View {
    let selected: Bool
    let count: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Theme.control
                VStack(spacing: 6) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(Theme.accent)
                    Text("Any days")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .frame(height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 2) {
                Text("Custom")
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(Theme.primaryText)
                Text("Timeline")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                Text(count.map { ArtworkText.photoCount($0) } ?? "Pick from and to")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? Theme.accent : Theme.tertiaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .padding(EdgeInsets(top: 8, leading: 8, bottom: 12, trailing: 8))
        .frame(width: 148)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: 22))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Custom timeline")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct YearCard: View {
    let year: Int
    let count: Int?
    /// Real barcode colors (generated years); nil shows the placeholder.
    let colors: [RGB8]?
    let generated: Bool
    let tag: String?
    let selected: Bool

    private static let placeholder = DecorativeStripes.placeholder(60)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Color.white
                if generated, let colors, !colors.isEmpty {
                    StripesView(colors: colors.map { Color($0) }).padding(10)
                } else if generated {
                    ProgressView().tint(Color(hex: 0x8E8E93))
                } else {
                    StripesView(colors: Self.placeholder).padding(10)
                    Text("Preview")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x6E6E73))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.9), in: Capsule())
                }
            }
            .frame(height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .topTrailing) {
                if generated {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Theme.accent)
                        .padding(6)
                        .accessibilityHidden(true)
                }
            }

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
                    .foregroundStyle(generated ? Theme.accent : Theme.tertiaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .padding(EdgeInsets(top: 8, leading: 8, bottom: 12, trailing: 8))
        .frame(width: 148)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: 22))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(year), \(generated ? "generated" : "not generated yet")")
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
