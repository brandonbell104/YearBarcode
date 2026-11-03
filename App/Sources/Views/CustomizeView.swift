import Photos
import SwiftUI
import YearBarcodeCore

struct CustomizeView: View {
    @Environment(AppModel.self) private var model
    let generationID: UUID
    @State private var session: ArtworkSession?
    @State private var showPicker = false
    @State private var cropping: BorderPhoto?
    @State private var arranging = false

    var body: some View {
        Group {
            if let session, session.report != nil {
                content(session)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Customize")
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
    private func content(_ session: ArtworkSession) -> some View {
        let purchases = model.purchases
        List {
            Section {
                PosterPreview(image: session.preview, settings: session.artwork.settings)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            }

            Section {
                BackgroundPicker(color: session.artwork.settings.background) { color in
                    var settings = session.artwork.settings
                    settings.background = color
                    Task { await session.update(settings) }
                }
            } header: {
                Text("Background")
            } footer: {
                Text("The border color around the barcode. Text switches between dark and light to stay readable.")
            }

            Section {
                ForEach(session.artwork.borderPhotos) { photo in
                    HStack(spacing: 12) {
                        AssetThumbnail(assetID: photo.assetID, side: 56)
                        Text(photo.assetID == session.replacementNeeded ? "Unavailable - replace" : "Photo")
                            .foregroundStyle(photo.assetID == session.replacementNeeded ? Color.red : Color.primary)
                        Spacer()
                        Button(photo.zoom > 1.001 ? "Cropped" : "Crop") { cropping = photo }.buttonStyle(.borderless)
                    }
                }
                .onMove { from, to in
                    var photos = session.artwork.borderPhotos
                    photos.move(fromOffsets: from, toOffset: to)
                    Task { await session.setBorderPhotos(photos) }
                }
                .onDelete { offsets in
                    var photos = session.artwork.borderPhotos
                    photos.remove(atOffsets: offsets)
                    Task { await session.setBorderPhotos(photos) }
                }
                if session.artwork.borderPhotos.count < PosterLayout.maxBorderPhotos {
                    Button {
                        showPicker = true
                    } label: {
                        Label("Add Border Photo", systemImage: "plus")
                    }
                }
                if !session.artwork.borderPhotos.isEmpty {
                    Button {
                        arranging = true
                    } label: {
                        Label("Move, Resize & Rotate", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                    }
                    if session.artwork.borderPhotos.contains(where: { $0.placement != nil }) {
                        Button("Reset Layout", role: .destructive) {
                            let photos = session.artwork.borderPhotos.map { photo -> BorderPhoto in
                                var photo = photo
                                photo.placement = nil
                                return photo
                            }
                            Task { await session.setBorderPhotos(photos) }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Border photos (optional, up to 4)")
                    Spacer()
                    if !session.artwork.borderPhotos.isEmpty { EditButton().font(.caption) }
                }
            } footer: {
                Text("Photos are decorative and can go anywhere, even over the barcode. They don't change its colors or the photo count.")
            }

            Section {
                exportButtons(session)
            } header: {
                Text("Export")
            } footer: {
                Text("A full-resolution 300 PPI PNG is created only when you save or share. Sharing sends the finished image to the destination you choose.")
            }

            Section {
                if purchases.isUnlocked {
                    Label("Watermark removed", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    Button {
                        Task { await purchases.purchase() }
                    } label: {
                        HStack {
                            Text("Remove Watermark")
                            Spacer()
                            Text(purchases.displayPrice ?? "").foregroundStyle(.secondary)
                        }
                    }
                    .disabled(purchases.state == .purchasing)
                    if purchases.state == .pending {
                        Text("Purchase pending approval. The watermark is removed once it's approved.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Button("Restore Purchases") { Task { await purchases.restore() } }
                    .disabled(purchases.state == .purchasing)
                if case .failed(let message) = purchases.state {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            } footer: {
                Text("Previews and exports are free at every size. One purchase removes the small \"\(PosterLayout.watermarkText)\" line from future renders for all years. Files you already exported stay as they are.")
            }
        }
        .sheet(isPresented: $showPicker) {
            BorderPhotoPicker(
                assetIDs: session.report?.included.map(\.assetID) ?? [],
                alreadyChosen: Set(session.artwork.borderPhotos.map(\.assetID))
            ) { assetID in
                var photos = session.artwork.borderPhotos
                if let missing = session.replacementNeeded, let index = photos.firstIndex(where: { $0.assetID == missing }) {
                    photos[index] = BorderPhoto(assetID: assetID, placement: photos[index].placement, aspect: session.aspect(of: assetID))
                    session.replacementNeeded = nil
                } else {
                    photos.append(BorderPhoto(assetID: assetID, aspect: session.aspect(of: assetID)))
                }
                Task { await session.setBorderPhotos(photos) }
            }
        }
        .sheet(item: $cropping) { photo in
            CropEditor(
                photo: photo,
                image: session.borderImages[photo.assetID],
                slotAspect: layout(session).aspect(for: photo)
            ) { updated in
                var photos = session.artwork.borderPhotos
                if let index = photos.firstIndex(where: { $0.assetID == updated.assetID }) { photos[index] = updated }
                Task { await session.setBorderPhotos(photos) }
            }
        }
        .fullScreenCover(isPresented: $arranging) {
            ArrangePhotosView(session: session)
        }
        .sheet(isPresented: Binding(
            get: { if case .ready = session.exportState { return true } else { return false } },
            set: { if !$0 { session.exportState = .idle } }
        )) {
            if case .ready(let url, let purpose) = session.exportState {
                switch purpose {
                case .files: DocumentExporter(url: url)
                case .share, .photos: ActivitySheet(items: [url])
                }
            }
        }
    }

    @ViewBuilder
    private func exportButtons(_ session: ArtworkSession) -> some View {
        switch session.exportState {
        case .exporting(let fraction):
            VStack(alignment: .leading) {
                Text("Creating full-resolution PNG…")
                ProgressView(value: fraction)
            }
        default:
            Button {
                Task { await session.export(.photos) }
            } label: {
                Label("Save to Photos", systemImage: "photo.badge.plus")
            }
            Button {
                Task { await session.export(.files) }
            } label: {
                Label("Save to Files", systemImage: "folder")
            }
            Button {
                Task { await session.export(.share) }
            } label: {
                Label("Share PNG", systemImage: "square.and.arrow.up")
            }
            switch session.exportState {
            case .savedToPhotos:
                Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                    .font(.footnote).foregroundStyle(.green)
            case .failed(let message):
                Text(message).font(.footnote).foregroundStyle(.red)
            default:
                EmptyView()
            }
        }
    }

    private func layout(_ session: ArtworkSession) -> PosterLayout {
        PosterLayout(printSize: session.artwork.settings.printSize, orientation: session.artwork.settings.orientation)
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
                            .frame(width: 34, height: 34)
                            .overlay(Circle().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1))
                            .overlay {
                                if preset.color == color {
                                    Image(systemName: "checkmark")
                                        .font(.caption.bold())
                                        .foregroundStyle(preset.color.prefersLightText ? .white : .black)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(preset.name)
                }
            }
            .padding(.vertical, 4)
        }
        ColorPicker("Custom color", selection: Binding(
            get: { Color(color) },
            set: { onChange(RGB8($0)) }
        ), supportsOpacity: false)
    }
}

extension Color {
    init(_ color: RGB8) {
        self.init(.sRGB, red: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255)
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
