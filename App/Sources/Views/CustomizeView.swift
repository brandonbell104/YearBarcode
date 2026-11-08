import Photos
import SwiftUI
import YearBarcodeCore

struct CustomizeView: View {
    @Environment(AppModel.self) private var model
    let generationID: UUID
    @State private var session: ArtworkSession?
    @State private var editing = false
    @State private var showPhotoPicker = false

    var body: some View {
        Group {
            if let session, session.report != nil {
                content(session)
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
    private func content(_ session: ArtworkSession) -> some View {
        let settings = session.artwork.settings
        let design = session.artwork.design
        VStack(spacing: 0) {
            NavHeader(backTitle: "Artwork", title: "Customize", onBack: {
                if !model.path.isEmpty { model.path.removeLast() }
            })

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PosterWell(image: session.preview, settings: settings, height: 256)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                    photosSection(session, design: design)
                        .padding(.horizontal, 16)
                        .padding(.top, 20)

                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Background").padding(.horizontal, 8)
                        BackgroundPicker(color: settings.background) { color in
                            var updated = settings
                            updated.background = color
                            Task { await session.update(updated) }
                        }
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)

                    watermarkCard
                        .padding(.horizontal, 16)
                        .padding(.top, 18)
                        .padding(.bottom, 150)
                }
            }
            .scrollIndicators(.hidden)
            .overlay(alignment: .bottom) {
                exportBar(session)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .background(
                        LinearGradient(colors: [Theme.background.opacity(0), Theme.background], startPoint: .top, endPoint: .init(x: 0.5, y: 0.35))
                            .ignoresSafeArea()
                    )
            }
        }
        .sheet(isPresented: $showPhotoPicker) {
            BorderPhotoPicker(
                assetIDs: session.report?.included.map(\.assetID) ?? [],
                alreadyChosen: Set(design.photos.map(\.assetID))
            ) { assetID in
                var updated = session.artwork.design
                if let missing = session.replacementNeeded,
                   let index = updated.layers.firstIndex(where: { $0.id == "photo:" + missing }),
                   case .photo(let old) = updated.layers[index] {
                    updated.layers[index] = .photo(BorderPhoto(assetID: assetID, placement: old.placement, aspect: session.aspect(of: assetID)))
                    session.replacementNeeded = nil
                } else {
                    updated.layers.append(.photo(BorderPhoto(assetID: assetID, aspect: session.aspect(of: assetID))))
                }
                Task { await session.setDesign(updated) }
            }
        }
        .fullScreenCover(isPresented: $editing) {
            LayoutEditorView(session: session)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .sheet(isPresented: Binding(
            get: { if case .ready = session.exportState { return true } else { return false } },
            set: { if !$0 { session.exportState = .idle } }
        )) {
            if case .ready(let url, _) = session.exportState {
                ActivitySheet(items: [url])
            }
        }
    }

    // MARK: - Photos & text

    private func photosSection(_ session: ArtworkSession, design: PosterDesign) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Photos & Text", trailing: layoutSummary(design)).padding(.horizontal, 8)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(design.photos) { photo in
                    AssetThumbnail(assetID: photo.assetID, side: 80)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay {
                            if photo.assetID == session.replacementNeeded {
                                RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.destructive, lineWidth: 2)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            Button {
                                var updated = session.artwork.design
                                updated.layers.removeAll { $0.id == PosterLayer.photo(photo).id }
                                if session.replacementNeeded == photo.assetID { session.replacementNeeded = nil }
                                Task { await session.setDesign(updated) }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .heavy))
                                    .foregroundStyle(Theme.primaryText)
                                    .frame(width: 26, height: 26)
                                    .background(Theme.controlSelected, in: Circle())
                                    .overlay(Circle().strokeBorder(Theme.background, lineWidth: 2))
                            }
                            .offset(x: 6, y: -6)
                            .accessibilityLabel("Remove photo")
                        }
                }
                if design.photos.count < PosterDesign.maxPhotos {
                    Button { showPhotoPicker = true } label: {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color(hex: 0x48484A), style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.secondaryText))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add photo")
                }
            }

            Button { editing = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.on.square.dashed")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Edit Layout").font(.system(size: 15, weight: .semibold))
                        Text("Move, resize, reorder, add & style text")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.tertiaryText)
                }
                .foregroundStyle(Theme.primaryText)
                .padding(14)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)

            if let missing = session.replacementNeeded, !missing.isEmpty {
                Text("A photo on the poster is no longer available. Remove it or tap + to choose a replacement.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.destructive)
                    .padding(.horizontal, 8)
            }
            if design != resetDesign(design) {
                Button("Reset positions & sizes") {
                    Task { await session.setDesign(resetDesign(design)) }
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 8)
            }
        }
    }

    // MARK: - Watermark

    private var watermarkCard: some View {
        let purchases = model.purchases
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: purchases.isUnlocked ? "checkmark.seal" : "star")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 40)
                    .background(Theme.hairline, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(purchases.isUnlocked ? "Watermark removed" : "Remove watermark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                    Text(purchases.isUnlocked ? "Unlocked for every year and size" : "One-time purchase · every year and size")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer(minLength: 0)
                if !purchases.isUnlocked {
                    Button {
                        Task { await purchases.purchase() }
                    } label: {
                        Group {
                            if purchases.state == .purchasing {
                                ProgressView().tint(Theme.background)
                            } else {
                                Text(purchases.displayPrice ?? "Buy")
                            }
                        }
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.background)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(Theme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(purchases.state == .purchasing)
                }
            }
            if purchases.state == .pending {
                Text("Purchase pending approval. The watermark is removed once it's approved.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
            if case .failed(let message) = purchases.state {
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.destructive)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 14))
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    // MARK: - Export

    @ViewBuilder
    private func exportBar(_ session: ArtworkSession) -> some View {
        let canvas = session.artwork.settings.printSize.canvas(session.artwork.settings.orientation)
        VStack(spacing: 10) {
            switch session.exportState {
            case .exporting(let fraction):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Creating full-resolution PNG…")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                    ProgressView(value: fraction).tint(Theme.accent)
                }
                .padding(16)
                .frame(minHeight: 56)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
            default:
                HStack(spacing: 10) {
                    Button {
                        Task { await session.export(.photos) }
                    } label: {
                        Label("Save PNG", systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(.primary)
                    Button {
                        Task { await session.export(.share) }
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.secondary)
                }
            }
            switch session.exportState {
            case .savedToPhotos:
                Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x30D158))
            case .failed(let message):
                Text(message).font(.system(size: 12)).foregroundStyle(Theme.destructive)
            default:
                EmptyView()
            }
            HStack {
                Text("\(canvas.width) × \(canvas.height) PNG · sRGB · 300 ppi")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiaryText)
                Spacer()
                Button("Restore Purchases") { Task { await model.purchases.restore() } }
                    .font(.system(size: 12))
                    .underline()
                    .foregroundStyle(Theme.secondaryText)
                    .disabled(model.purchases.state == .purchasing)
            }
            .padding(.horizontal, 4)
        }
    }

    private func layoutSummary(_ design: PosterDesign) -> String {
        let photos = design.photos.count
        let texts = design.layers.count - photos
        return "\(photos) \(photos == 1 ? "photo" : "photos") · \(texts) text"
    }

    /// Same layers, contents and styles, back in their default spots and sizes.
    private func resetDesign(_ design: PosterDesign) -> PosterDesign {
        PosterDesign(layers: design.layers.map { layer in
            switch layer {
            case .photo(var photo):
                photo.placement = nil
                return .photo(photo)
            case .text(var text):
                text.position = nil
                text.size = nil
                return .text(text)
            }
        })
    }
}

// MARK: - Background color

struct BackgroundPicker: View {
    let color: RGB8
    let onChange: (RGB8) -> Void

    static let presets: [(name: String, color: RGB8)] = [
        ("White", .white),
        ("Paper", RGB8(r: 246, g: 241, b: 232)),
        ("Stone", RGB8(r: 214, g: 210, b: 202)),
        ("Sage", RGB8(r: 205, g: 214, b: 196)),
        ("Blush", RGB8(r: 240, g: 216, b: 210)),
        ("Navy", RGB8(r: 24, g: 36, b: 64)),
        ("Charcoal", RGB8(r: 40, g: 40, b: 42)),
        ("Black", .black),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Self.presets, id: \.name) { preset in
                    Button {
                        onChange(preset.color)
                    } label: {
                        Circle()
                            .fill(Color(preset.color))
                            .frame(width: 36, height: 36)
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                            .overlay(Circle().strokeBorder(preset.color == color ? Theme.accent : .clear, lineWidth: 2).padding(-4))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(preset.name)
                    .accessibilityAddTraits(preset.color == color ? .isSelected : [])
                }
                ColorPicker("Custom color", selection: Binding(
                    get: { Color(color) },
                    set: { onChange(RGB8($0)) }
                ), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 36, height: 36)
            }
            .padding(6)
        }
    }
}

extension RGB8 {
    /// Converts a picked color to 8-bit sRGB (colors outside sRGB are clamped).
    init(_ color: Color) {
        let resolved = color.resolve(in: EnvironmentValues())
        func byte(_ linear: Float) -> UInt8 {
            UInt8((SRGB.toEncoded(Double(linear)) * 255).rounded())
        }
        self.init(r: byte(resolved.linearRed), g: byte(resolved.linearGreen), b: byte(resolved.linearBlue))
    }
}

// MARK: - Thumbnails and picker

struct AssetThumbnail: View {
    @Environment(AppModel.self) private var model
    let assetID: String
    let side: CGFloat
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(.secondarySystemFill)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: assetID) {
            guard let asset = model.library.asset(id: assetID) else { return }
            image = await model.library.thumbnail(for: asset, side: side * 2)
        }
    }
}

/// Explicit thumbnail choice from the snapshot year's included photos.
struct BorderPhotoPicker: View {
    @Environment(\.dismiss) private var dismiss
    let assetIDs: [String]
    let alreadyChosen: Set<String>
    let onPick: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 90), spacing: 2)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(assetIDs, id: \.self) { id in
                        Button {
                            onPick(id)
                            dismiss()
                        } label: {
                            AssetThumbnail(assetID: id, side: 90)
                                .overlay(alignment: .topTrailing) {
                                    if alreadyChosen.contains(id) {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .blue).padding(4)
                                    }
                                }
                        }
                        .disabled(alreadyChosen.contains(id))
                    }
                }
            }
            .navigationTitle("Choose a Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

// MARK: - Crop

/// Simple pan/zoom crop inside the slot's aspect ratio.
struct CropEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var photo: BorderPhoto
    let image: UIImage?
    let slotAspect: Double
    let onDone: (BorderPhoto) -> Void

    @State private var dragStart: BorderPhoto?
    @State private var zoomStart: Double?

    var body: some View {
        NavigationStack {
            VStack {
                if let image {
                    GeometryReader { geometry in
                        let frame = fit(in: geometry.size)
                        let crop = photo.cropRect(imageWidth: image.size.width, imageHeight: image.size.height, slotAspect: slotAspect)
                        let scale = frame.width / crop.width
                        Image(uiImage: image)
                            .resizable()
                            .frame(width: image.size.width * scale, height: image.size.height * scale)
                            .offset(x: -crop.x * scale, y: -crop.y * scale)
                            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                            .clipped()
                            .contentShape(Rectangle())
                            .gesture(drag(scale: scale, image: image).simultaneously(with: magnify(image: image)))
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    }
                    .padding()
                    Text("Drag to move. Pinch to zoom.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView("Photo unavailable", systemImage: "photo", description: Text("Remove it and choose another photo."))
                }
            }
            .navigationTitle("Crop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone(photo)
                        dismiss()
                    }
                }
            }
        }
    }

    private func fit(in size: CGSize) -> CGSize {
        let aspect = CGFloat(slotAspect)
        return size.width / size.height > aspect
            ? CGSize(width: size.height * aspect, height: size.height)
            : CGSize(width: size.width, height: size.width / aspect)
    }

    private func drag(scale: CGFloat, image: UIImage) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragStart ?? photo
                dragStart = start
                var updated = start
                updated.centerX = start.centerX - value.translation.width / scale / image.size.width
                updated.centerY = start.centerY - value.translation.height / scale / image.size.height
                photo = updated.clamped(imageWidth: image.size.width, imageHeight: image.size.height, slotAspect: slotAspect)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func magnify(image: UIImage) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = zoomStart ?? photo.zoom
                zoomStart = start
                var updated = photo
                updated.zoom = start * value.magnification
                photo = updated.clamped(imageWidth: image.size.width, imageHeight: image.size.height, slotAspect: slotAspect)
            }
            .onEnded { _ in zoomStart = nil }
    }
}

// MARK: - System sheets

struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct DocumentExporter: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}
