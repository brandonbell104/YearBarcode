import SwiftUI
import YearBarcodeCore

/// Past posters as a swipeable carousel. The centered poster shows its
/// actions: open it, or edit a new version (a copy, so the original stays).
struct SavedPostersView: View {
    @Environment(AppModel.self) private var model
    @State private var focusedID: UUID?
    @State private var confirmDelete: GenerationRecord?

    private var focused: GenerationRecord? {
        guard let focusedID else { return model.generations.first }
        return model.generations.first { $0.id == focusedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavHeader(backTitle: "Years", title: "Saved posters", onBack: {
                if !model.path.isEmpty { model.path.removeLast() }
            })

            if model.generations.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.split.3x1").font(.system(size: 34)).foregroundStyle(Theme.tertiaryText)
                    Text("No posters yet").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.primaryText)
                    Text("Posters you generate appear here.").font(.system(size: 15)).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
            } else {
                carousel
                    .padding(.top, 12)

                if let record = focused {
                    details(record)
                        .padding(.horizontal, 24)
                        .padding(.top, 18)
                    Spacer(minLength: 12)
                    actions(record)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)
                }

                pageDots.padding(.bottom, 8)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { if focusedID == nil { focusedID = model.generations.first?.id } }
        .confirmationDialog(
            "Delete this poster?",
            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
            presenting: confirmDelete
        ) { record in
            Button("Delete \(String(record.year)) Poster", role: .destructive) {
                let index = model.generations.firstIndex { $0.id == record.id }
                model.delete(record.id)
                if let index, !model.generations.isEmpty {
                    focusedID = model.generations[min(index, model.generations.count - 1)].id
                }
            }
        } message: { _ in
            Text("Saved PNG files stay where you saved them.")
        }
    }

    // MARK: - Carousel

    private var carousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 14) {
                ForEach(model.generations) { record in
                    SavedPosterCard(record: record, focused: record.id == (focusedID ?? model.generations.first?.id))
                        .containerRelativeFrame(.horizontal) { width, _ in width * 0.78 }
                        .scrollTransition(axis: .horizontal) { content, phase in
                            content
                                .scaleEffect(phase.isIdentity ? 1 : 0.88)
                                .opacity(phase.isIdentity ? 1 : 0.55)
                        }
                        .onTapGesture {
                            if focusedID == record.id { open(record) } else { withAnimation { focusedID = record.id } }
                        }
                        .contextMenu {
                            Button { open(record) } label: { Label("Open", systemImage: "arrow.up.right") }
                            if record.status == .finished {
                                Button { editNewVersion(record) } label: { Label("Edit New Version", systemImage: "plus.square.on.square") }
                            }
                            Button(role: .destructive) { confirmDelete = record } label: { Label("Delete", systemImage: "trash") }
                        }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $focusedID)
        .contentMargins(.horizontal, 40, for: .scrollContent)
        .frame(height: 360)
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(model.generations) { record in
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
            Text(String(record.year))
                .font(.system(size: 28, weight: .heavy))
                .tracking(-0.6)
                .foregroundStyle(Theme.primaryText)
            Text([
                "\(settings.printSize.shortInches) × \(settings.printSize.longInches)",
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
                Button { editNewVersion(record) } label: {
                    Label("Edit New Version", systemImage: "plus.square.on.square")
                }
                .buttonStyle(.primary)
                HStack(spacing: 10) {
                    Button("Open") { open(record) }.buttonStyle(.secondary)
                    Button("Delete") { confirmDelete = record }.buttonStyle(.secondary(Theme.destructive))
                }
            }
        } else {
            HStack(spacing: 10) {
                Button(record.status == .cancelled ? "View" : "Resume") { open(record) }.buttonStyle(.primary)
                Button("Delete") { confirmDelete = record }.buttonStyle(.secondary(Theme.destructive))
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
    private func editNewVersion(_ record: GenerationRecord) {
        guard let newID = model.duplicate(record.id) else { return }
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
        let settings = session?.artwork.settings ?? record.settings
        let canvas = settings.printSize.canvas(settings.orientation)
        RoundedRectangle(cornerRadius: 24)
            .fill(Theme.posterWell)
            .overlay {
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
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .shadow(color: .black.opacity(0.4), radius: 18, y: 10)
                .padding(18)
            }
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(focused ? Theme.accent : .clear, lineWidth: 2))
            .task(id: record.id) {
                guard record.status == .finished else { return }
                let session = model.session(for: record.id)
                self.session = session
                if session.report == nil { await session.load() }
            }
            .accessibilityElement()
            .accessibilityLabel("\(String(record.year)) poster")
            .accessibilityHint(focused ? "Double tap to open" : "Double tap to select")
    }
}
