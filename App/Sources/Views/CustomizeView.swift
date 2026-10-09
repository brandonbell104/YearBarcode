import Photos
import SwiftUI
import YearBarcodeCore

struct CustomizeView: View {
    @Environment(AppModel.self) private var model
    let generationID: UUID
    @State private var session: ArtworkSession?
    @State private var showPicker = false
    @State private var cropping: BorderPhoto?

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
                ForEach(session.artwork.borderPhotos) { photo in
                    HStack(spacing: 12) {
                        AssetThumbnail(assetID: photo.assetID, side: 56)
                        Text(photo.assetID == session.replacementNeeded ? "Unavailable - replace" : "Photo")
                            .foregroundStyle(photo.assetID == session.replacementNeeded ? Color.red : Color.primary)
                        Spacer()
                        Button("Crop") { cropping = photo }.buttonStyle(.borderless)
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
            } header: {
                HStack {
                    Text("Border photos (optional, up to 4)")
                    Spacer()
                    if !session.artwork.borderPhotos.isEmpty { EditButton().font(.caption) }
                }
            } footer: {
                Text("Border photos are decorative. They don't change the barcode or the photo count.")
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
                    photos[index] = BorderPhoto(assetID: assetID)
                    session.replacementNeeded = nil
                } else {
                    photos.append(BorderPhoto(assetID: assetID))
                }
                Task { await session.setBorderPhotos(photos) }
            }
        }
        .sheet(item: $cropping) { photo in
            CropEditor(
                photo: photo,
                image: session.borderImages[photo.assetID],
                slotAspect: slotAspect(session)
            ) { updated in
                var photos = session.artwork.borderPhotos
                if let index = photos.firstIndex(where: { $0.assetID == updated.assetID }) { photos[index] = updated }
                Task { await session.setBorderPhotos(photos) }
            }
        }
        .sheet(isPresented: Binding(
            get: { if case .ready = session.exportState { return true } else { return false } },
            set: { if !$0 { session.exportState = .idle } }
        )) {
            if case .ready(let url, let purpose) = session.exportState {
                switch purpose {
                case .save: DocumentExporter(url: url)
                case .share: ActivitySheet(items: [url])
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
                Task { await session.export(.save) }
            } label: {
                Label("Save PNG", systemImage: "square.and.arrow.down")
            }
            Button {
                Task { await session.export(.share) }
            } label: {
                Label("Share PNG", systemImage: "square.and.arrow.up")
            }
            if case .failed(let message) = session.exportState {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func slotAspect(_ session: ArtworkSession) -> Double {
        let layout = PosterLayout(printSize: session.artwork.settings.printSize, orientation: session.artwork.settings.orientation)
        let slot = layout.photoSlots(count: 1)[0]
        return Double(slot.width) / Double(slot.height)
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
