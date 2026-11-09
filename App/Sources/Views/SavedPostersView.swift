import SwiftUI
import YearBarcodeCore

/// Past posters as a swipeable carousel. The centered poster shows its
/// actions: open it, or edit a new version (a copy, so the original stays).
struct SavedPostersView: View {
    @Environment(AppModel.self) private var model
    @State private var focusedID: UUID?
    @State private var confirmDelete: GenerationRecord?
    @State private var sort: PosterSort = .newestCreated
    @State private var yearFilter: Int?

    enum PosterSort: String, CaseIterable {
        case newestCreated, oldestCreated, yearDescending, yearAscending

        var title: String {
            switch self {
            case .newestCreated: return "Newest first"
            case .oldestCreated: return "Oldest first"
            case .yearDescending: return "Year, newest first"
            case .yearAscending: return "Year, oldest first"
            }
        }
    }

    /// Posters after the year filter and sort.
    private var posters: [GenerationRecord] {
        let filtered = model.generations.filter { yearFilter == nil || $0.year == yearFilter }
        switch sort {
        case .newestCreated: return filtered.sorted { $0.createdAt > $1.createdAt }
        case .oldestCreated: return filtered.sorted { $0.createdAt < $1.createdAt }
        case .yearDescending: return filtered.sorted { ($0.year, $0.createdAt) > ($1.year, $1.createdAt) }
        case .yearAscending: return filtered.sorted { ($0.year, $1.createdAt) < ($1.year, $0.createdAt) }
        }
    }

    private var focused: GenerationRecord? {
        let list = posters
        return list.first { $0.id == focusedID } ?? list.first
    }

    var body: some View {
        VStack(spacing: 0) {
            NavHeader(backTitle: "Years", title: "Saved posters", onBack: {
                if !model.path.isEmpty { model.path.removeLast() }
            }) {
                filterMenu
            }

            if posters.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.split.3x1").font(.system(size: 34)).foregroundStyle(Theme.tertiaryText)
                    Text(model.generations.isEmpty ? "No posters yet" : "No posters for \(yearFilter.map(String.init) ?? "this filter")")
                        .font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.primaryText)
                    Text(model.generations.isEmpty ? "Posters you generate appear here." : "Change the filter to see more.")
                        .font(.system(size: 15)).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
            } else {
                carousel
                    .padding(.top, 8)

                pageDots.padding(.top, 10)

                if let record = focused {
                    details(record)
                        .padding(.horizontal, 24)
                        .padding(.top, 14)
                    Spacer(minLength: 12)
                    actions(record)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)
                }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { if focusedID == nil { focusedID = posters.first?.id } }
        .onChange(of: sort) { focusedID = posters.first?.id }
        .onChange(of: yearFilter) { focusedID = posters.first?.id }
        .confirmationDialog(
            "Delete this poster?",
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            presenting: confirmDelete
        ) { record in
            Button("Delete \(record.title) Poster", role: .destructive) {
                let list = posters
                let index = list.firstIndex { $0.id == record.id }
                model.delete(record.id)
                let remaining = posters
                if let index, !remaining.isEmpty {
                    focusedID = remaining[min(index, remaining.count - 1)].id
                }
            }
        } message: { _ in
            Text("Saved PNG files stay where you saved them.")
        }
    }

    // MARK: - Filter

    private var filterMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(PosterSort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Year", selection: $yearFilter) {
                Text("All years").tag(Int?.none)
                ForEach(Array(Set(model.generations.map(\.year))).sorted(by: >), id: \.self) { year in
                    Text(String(year)).tag(Int?.some(year))
                }
            }
        } label: {
            Image(systemName: yearFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(yearFilter == nil ? Theme.primaryText : Theme.accent)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Sort and filter")
    }

    // MARK: - Carousel

    private var carousel: some View {
        GeometryReader { geometry in
            let itemWidth = geometry.size.width * 0.64
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(posters) { record in
                        SavedPosterCard(record: record, focused: record.id == focused?.id)
                            .frame(width: itemWidth, height: geometry.size.height)
                            .scrollTransition(axis: .horizontal) { content, phase in
                                content
                                    .scaleEffect(phase.isIdentity ? 1 : 0.86)
                                    .opacity(phase.isIdentity ? 1 : 0.5)
                            }
                            .onTapGesture {
                                if focused?.id == record.id { open(record) } else { withAnimation { focusedID = record.id } }
                            }
                            .contextMenu {
                                Button { open(record) } label: { Label("Open/Edit", systemImage: "slider.horizontal.3") }
                                if record.status == .finished {
                                    Button { createNewVersion(record) } label: { Label("Create New Version", systemImage: "plus.square.on.square") }
                                }
                                Button(role: .destructive) { confirmDelete = record } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $focusedID, anchor: .center)
            // Equal side margins keep the selected poster centered, with neighbors peeking in.
            .contentMargins(.horizontal, (geometry.size.width - itemWidth) / 2, for: .scrollContent)
        }
        .frame(height: 340)
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(posters) { record in
                Circle()
                    .fill(record.id == focused?.id ? Theme.primaryText : Theme.hairline)
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Focused poster

    private func details(_ record: GenerationRecord) -> some View {
        let settings = model.artwork(for: record.id)?.settings ?? record.settings
        return VStack(alignment: .leading, spacing: 4) {
            Text(record.title)
                .font(.system(size: record.isCustomTimeline ? 22 : 28, weight: .heavy))
                .tracking(-0.6)
                .foregroundStyle(Theme.primaryText)
            Text([
                settings.sizeTitle,
                settings.orientation.title,
                settings.mode.title,
                settings.stripeStyle.title,
            ].joined(separator: " · "))
            .font(.system(size: 14))
            .foregroundStyle(Theme.secondaryText)
            Text(statusLine(record))
                .font(.system(size: 13))
                .foregroundStyle(record.status == .finished ? Theme.tertiaryText : Theme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func actions(_ record: GenerationRecord) -> some View {
        if record.status == .finished {
            VStack(spacing: 10) {
                Button { open(record) } label: {
                    Label("Open/Edit", systemImage: "slider.horizontal.3")
                        .font(.system(size: 19, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 64)
                }
                .buttonStyle(.primary)
                HStack(spacing: 10) {
                    Button { createNewVersion(record) } label: {
                        Label("Create New Version", systemImage: "plus.square.on.square")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .buttonStyle(.secondary)
                    Button { confirmDelete = record } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.secondary(Theme.destructive))
                    .frame(width: 64)
                    .accessibilityLabel("Delete")
                }
            }
        } else {
            HStack(spacing: 10) {
                Button(record.status == .cancelled ? "View" : "Resume") { open(record) }.buttonStyle(.primary)
                Button { confirmDelete = record } label: { Image(systemName: "trash") }
                    .buttonStyle(.secondary(Theme.destructive))
                    .frame(width: 64)
                    .accessibilityLabel("Delete")
            }
        }
    }

    private func statusLine(_ record: GenerationRecord) -> String {
        let created = record.createdAt.formatted(date: .abbreviated, time: .shortened)
        switch record.status {
        case .finished: return "Created \(created)"
        case .analyzing: return "Analyzing…"
        case .paused: return "Paused · tap Resume to continue"
        case .interrupted: return "Interrupted · tap Resume to continue"
        case .cancelled: return "Cancelled"
        }
    }

    private func open(_ record: GenerationRecord) {
        model.path.append(record.status == .finished ? .artwork(record.id) : .progress(record.id))
    }

    /// Copies the poster and opens the copy for editing; the original is untouched.
    private func createNewVersion(_ record: GenerationRecord) {
        guard let newID = model.duplicate(record.id) else { return }
        focusedID = newID
        model.path.append(.artwork(newID))
        model.path.append(.customize(newID))
    }
}

/// One poster in the carousel: its real preview once loaded.
private struct SavedPosterCard: View {
    @Environment(AppModel.self) private var model
    let record: GenerationRecord
    let focused: Bool
    @State private var session: ArtworkSession?

    var body: some View {
        let settings = session?.artwork.settings ?? model.artwork(for: record.id)?.settings ?? record.settings
        let canvas = settings.canvas
        Group {
            if record.status == .finished, let image = session?.preview {
                Image(decorative: image, scale: 1).resizable().interpolation(.medium)
            } else if record.status == .finished {
                Color(settings.background).overlay(ProgressView().tint(Color(hex: 0x8E8E93)))
            } else {
                Color.white.overlay {
                    VStack(spacing: 6) {
                        StripesView(colors: DecorativeStripes.placeholder(40)).frame(height: 60).padding(.horizontal, 20)
                        Text(record.status == .cancelled ? "Cancelled" : "Not finished")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x6E6E73))
                    }
                }
            }
        }
        .aspectRatio(CGFloat(canvas.width) / CGFloat(canvas.height), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        // The highlight hugs the poster itself.
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(focused ? Theme.accent : .clear, lineWidth: 3).padding(-5))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .task(id: record.id) {
            guard record.status == .finished else { return }
            let session = model.session(for: record.id)
            self.session = session
            if session.report == nil { await session.load() }
        }
        .accessibilityElement()
        .accessibilityLabel("\(record.title) poster")
        .accessibilityHint(focused ? "Double tap to open" : "Double tap to select")
    }
}
