import PhotosUI
import SwiftUI
import YearBarcodeCore

struct YearsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedYear: Int?
    @State private var settings = ArtworkSettings.default
    @State private var isGenerating = false
    @State private var showSettings = false
    /// What the poster covers: a year card, a custom timeline, or an album.
    private enum Source { case year, custom, album }
    @State private var source: Source = .year
    @State private var selectedAlbumID: String?
    @State private var showAllAlbums = false
    /// New album in-app: pick photos (search a person's name), then name it.
    @State private var showPicker = false
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var pickedIDs: [String] = []
    @State private var showNameSheet = false
    @State private var newAlbumName = ""
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
                        Text("Or any days, or an album from Photos")
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
                        if source == .custom { customRangeSection }
                        if source == .album { albumSection }
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
                CustomTimelineCard(selected: source == .custom, count: source == .custom ? rangeCount : nil)
                    .onTapGesture { withAnimation(.snappy) { source = .custom } }
                AlbumSourceCard(selected: source == .album, album: source == .album ? selectedAlbum : nil)
                    .onTapGesture {
                        withAnimation(.snappy) { source = .album }
                        Task { await model.refreshAlbums() }
                    }
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
                        selected: source == .year && year == selectedYear
                    )
                    .onTapGesture {
                        withAnimation(.snappy) {
                            source = .year
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

    private var selectedAlbum: PhotoAlbum? {
        model.albums.first { $0.id == selectedAlbumID }
    }

    private var albumSection: some View {
        let albums = showAllAlbums ? model.albums : Array(model.albums.prefix(8))
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Album", trailing: selectedAlbum.map { ArtworkText.photoCount($0.count) })
            Button { showPicker = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.square.badge.plus")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 44, height: 44)
                        .background(Theme.control, in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("New Album of a Person")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.primaryText)
                        Text("Search their name and select their photos")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.tertiaryText)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 64)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            if model.isLoadingAlbums && model.albums.isEmpty {
                ProgressView().tint(Theme.tertiaryText).frame(maxWidth: .infinity, minHeight: 80)
            } else if model.albums.isEmpty {
                Text("No albums with photos yet.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
                        if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 70) }
                        AlbumRow(album: album, selected: album.id == selectedAlbumID)
                            .onTapGesture { selectedAlbumID = album.id }
                    }
                    if model.albums.count > 8 {
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                        Button(showAllAlbums ? "Show fewer" : "Show all \(model.albums.count) albums") {
                            withAnimation(.snappy) { showAllAlbums.toggle() }
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, minHeight: 46)
                    }
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
            }
            Text("In the picker, type the person's name in the search bar (the name you gave them in Photos' People) and tap their photos. The album is saved to your Photos library too.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            selectAllInPhotos.padding(.top, 6)
        }
        .onChange(of: scenePhase) { old, phase in
            // Back from Photos: pick up the album that was just made there.
            guard phase == .active, old != .active, source == .album else { return }
            let before = Set(model.albums.map(\.id))
            Task {
                await model.refreshAlbums()
                if let added = model.albums.first(where: { !before.contains($0.id) && $0.kind == .mine }) {
                    selectedAlbumID = added.id
                }
            }
        }
        .onChange(of: model.albums) { _, albums in
            if let id = selectedAlbumID, !albums.contains(where: { $0.id == id }) { selectedAlbumID = nil }
        }
        .photosPicker(
            isPresented: $showPicker,
            selection: $pickedItems,
            maxSelectionCount: nil,
            selectionBehavior: .default,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: pickedItems) { _, items in
            guard !items.isEmpty else { return }
            pickedIDs = items.compactMap(\.itemIdentifier)
            pickedItems = []
            if pickedIDs.isEmpty {
                model.alert = "Couldn't read those photos. Try again."
            } else {
                newAlbumName = ""
                showNameSheet = true
            }
        }
        .sheet(isPresented: $showNameSheet) {
            NewAlbumSheet(count: pickedIDs.count, name: $newAlbumName) {
                let album = await model.createAlbum(named: newAlbumName, assetIDs: pickedIDs)
                if let album {
                    selectedAlbumID = album.id
                    showNameSheet = false
                }
                return album != nil
            }
            .presentationDetents([.height(300)])
        }
    }

    /// Photos' People page can Select All, which the picker can't.
    private var selectAllInPhotos: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Lots of photos? Select them all in Photos")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array([
                    "Open Photos, then Collections → People & Pets → the person.",
                    "Tap Select, then Select All.",
                    "Tap ⋯ (or Share) → Add to Album → New Album, and name it.",
                    "Come back here. The new album is picked for you.",
                ].enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.background)
                            .frame(width: 20, height: 20)
                            .background(Theme.accent, in: Circle())
                        Text(step)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Button {
                if let url = URL(string: "photos-redirect://") {
                    openURL(url) { opened in
                        if !opened { model.alert = "Open the Photos app from your Home Screen, then come back." }
                    }
                }
            } label: {
                Label("Open Photos", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.secondary)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
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
        if source == .album {
            Button {
                guard let album = selectedAlbum else { return }
                isGenerating = true
                Task {
                    await model.generate(timeline: .album(id: album.id, title: album.title), settings: settings)
                    isGenerating = false
                }
            } label: {
                HStack(spacing: 10) {
                    if isGenerating {
                        ProgressView().tint(Theme.background)
                    } else {
                        Image(systemName: "rectangle.stack")
                        Text(selectedAlbum.map { "Generate \($0.title)" } ?? "Choose an album")
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.primary)
            .disabled(isGenerating || selectedAlbum == nil)
            .opacity(selectedAlbum == nil ? 0.5 : 1)
        } else if source == .custom {
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

private struct AlbumSourceCard: View {
    let selected: Bool
    let album: PhotoAlbum?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Theme.control
                VStack(spacing: 6) {
                    Image(systemName: "rectangle.stack.badge.person.crop")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(Theme.accent)
                    Text("A person or trip")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .frame(height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 2) {
                Text("Album")
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(Theme.primaryText)
                Text(album?.title ?? "From Photos")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                Text(album.map { ArtworkText.photoCount($0.count) } ?? "Pick an album")
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
        .accessibilityLabel("Album")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct NewAlbumSheet: View {
    let count: Int
    @Binding var name: String
    /// Creates the album; returns whether it worked.
    let create: () async -> Bool
    @State private var isCreating = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Name the album")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.primaryText)
            Text("\(ArtworkText.photoCount(count)) selected. The name becomes the poster's title.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryText)
            TextField("e.g. Emma", text: $name)
                .font(.system(size: 17))
                .padding(.horizontal, 14)
                .frame(minHeight: 50)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(save)
            Button(action: save) {
                if isCreating { ProgressView().tint(Theme.background) } else { Text("Create Album") }
            }
            .buttonStyle(.primary)
            .disabled(isCreating || name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(24)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.background.ignoresSafeArea())
        .onAppear { focused = true }
    }

    private func save() {
        guard !isCreating, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isCreating = true
        Task {
            _ = await create()
            isCreating = false
        }
    }
}

private struct AlbumRow: View {
    @Environment(AppModel.self) private var model
    let album: PhotoAlbum
    let selected: Bool
    @State private var cover: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Theme.control
                if let cover {
                    Image(uiImage: cover).resizable().scaledToFill()
                } else {
                    Image(systemName: album.kind == .favorites ? "heart.fill" : "photo.on.rectangle")
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Text(ArtworkText.photoCount(album.count) + (album.kind == .shared ? " · Shared" : ""))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .foregroundStyle(selected ? Theme.accent : Theme.tertiaryText)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(album.title), \(ArtworkText.photoCount(album.count))")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .task(id: album.keyAssetID) {
            guard let id = album.keyAssetID, let asset = model.library.asset(id: id) else { return }
            cover = await model.library.thumbnail(for: asset, side: 88)
        }
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
