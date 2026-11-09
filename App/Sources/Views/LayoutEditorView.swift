import SwiftUI
import UniformTypeIdentifiers
import YearBarcodeCore

/// Edit everything placed on the poster: photos and text blocks (including the
/// year and photo count). Select a layer from the strip or by tapping it, then
/// drag, pinch and twist anywhere on the poster. Drag tiles in the strip to
/// change which layer is on top. The barcode and watermark are not layers.
struct LayoutEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let session: ArtworkSession

    @State private var design = PosterDesign.standard()
    @State private var selectedID: String?
    @State private var gestureStart: PosterLayer?
    @State private var background: CGImage?
    /// Source photos (uncropped) and their cropped display copies.
    @State private var sources: [String: UIImage] = [:]
    @State private var displays: [String: UIImage] = [:]
    @State private var zoom: CGFloat = 1
    @State private var focus = CGPoint(x: 0.5, y: 0.5)
    @State private var draggingID: String?
    @State private var showPhotoPicker = false
    @State private var cropping: BorderPhoto?
    @State private var loaded = false

    private static let zoomLevels: [CGFloat] = [1, 2, 3, 4]

    private var layout: PosterLayout {
        PosterLayout(settings: session.artwork.settings)
    }
    private var year: Int { session.report?.snapshot.year ?? 0 }
    private var includedPhotos: Int { session.barcode?.includedPhotoCount ?? 0 }

    private var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return design.layers.firstIndex { $0.id == selectedID }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                GeometryReader { geometry in
                    poster(in: geometry.size)
                }
                .clipped()
                .background(Theme.posterWell)

                layerStrip
                ScrollView { inspector.padding(.horizontal) }
                    .frame(maxHeight: 230)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Edit Layout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { save() } }
            }
            .task { if !loaded { await load() } }
            .sheet(isPresented: $showPhotoPicker) {
                BorderPhotoPicker(
                    assetIDs: session.report?.included.map(\.assetID) ?? [],
                    alreadyChosen: Set(design.photos.map(\.assetID))
                ) { assetID in
                    Task { await addPhoto(assetID) }
                }
            }
            .sheet(item: $cropping) { photo in
                CropEditor(photo: photo, image: sources[photo.assetID], slotAspect: layout.aspect(for: photo)) { updated in
                    replace(.photo(updated))
                    refreshDisplay(for: updated)
                }
            }
        }
    }

    // MARK: - Poster

    @ViewBuilder
    private func poster(in available: CGSize) -> some View {
        let fitted = fit(layout.canvas, in: CGSize(width: available.width - 24, height: available.height - 24))
        let size = CGSize(width: fitted.width * zoom, height: fitted.height * zoom)
        let origin = posterOrigin(size: size, in: available)
        ZStack(alignment: .topLeading) {
            if let background {
                Image(decorative: background, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: size.width, height: size.height)
            } else {
                Color(session.artwork.settings.background)
                    .frame(width: size.width, height: size.height)
                    .overlay(ProgressView())
            }
            ForEach(design.layers) { layer in
                layerView(layer, posterSize: size)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .offset(x: origin.x, y: origin.y)
        .frame(width: available.width, height: available.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(transformGesture(posterSize: size))
    }

    @ViewBuilder
    private func layerView(_ layer: PosterLayer, posterSize: CGSize) -> some View {
        let k = posterSize.width / CGFloat(layout.canvas.width)
        let isSelected = layer.id == selectedID
        switch layer {
        case .photo(let photo):
            let index = design.photoIndex(of: photo.assetID) ?? 0
            let frame = layout.frame(for: photo, index: index, count: design.photos.count)
            Group {
                if let image = displays[photo.assetID] {
                    Image(uiImage: image).resizable()
                } else {
                    Color.gray.opacity(0.3)
                }
            }
            .frame(width: frame.width * k, height: frame.height * k)
            .overlay { selectionBox(isSelected, valid: layout.isValid(layout.resolvedPlacement(for: photo, index: index, count: design.photos.count))) }
            .rotationEffect(.radians(frame.rotation))
            .contentShape(Rectangle())
            .onTapGesture { select(layer.id) }
            .position(x: frame.centerX * k, y: frame.centerY * k)
        case .text(let text):
            let position = layout.position(for: text)
            let string = text.displayText(year: year, includedPhotos: includedPhotos)
            let uiFont = ArtworkRenderer.font(text.font, bold: text.bold, size: layout.fontSize(for: text) * Double(k))
            Text(string.isEmpty ? " " : string)
                .font(Font(uiFont as CTFont))
                .kerning(uiFont.pointSize * 0.02)
                .foregroundStyle(Color(uiColor: ArtworkRenderer.textColor(text, background: session.artwork.settings.background)))
                .fixedSize()
                .padding(2)
                .overlay { selectionBox(isSelected, valid: true) }
                .rotationEffect(.radians(position.rotation))
                .contentShape(Rectangle())
                .onTapGesture { select(layer.id) }
                .position(x: position.centerX * posterSize.width, y: position.centerY * posterSize.height)
        }
    }

    private func selectionBox(_ selected: Bool, valid: Bool) -> some View {
        Rectangle().strokeBorder(
            valid ? (selected ? Color.accentColor : Color.clear) : Color.red,
            style: StrokeStyle(lineWidth: 2)
        )
    }

    private func posterOrigin(size: CGSize, in available: CGSize) -> CGPoint {
        func axis(_ length: CGFloat, _ space: CGFloat, _ focus: CGFloat) -> CGFloat {
            if length <= space { return (space - length) / 2 }
            let ideal = space / 2 - focus * length
            return min(0, max(space - length, ideal))
        }
        return CGPoint(x: axis(size.width, available.width, focus.x), y: axis(size.height, available.height, focus.y))
    }

    // MARK: - Gestures (always act on the selected layer)

    private func transformGesture(posterSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .simultaneously(with: MagnifyGesture())
            .simultaneously(with: RotateGesture())
            .onChanged { value in
                guard let index = selectedIndex else { return }
                if gestureStart == nil { gestureStart = design.layers[index] }
                guard let start = gestureStart else { return }
                let dx = Double((value.first?.first?.translation.width ?? 0) / posterSize.width)
                let dy = Double((value.first?.first?.translation.height ?? 0) / posterSize.height)
                let scale = Double(value.first?.second?.magnification ?? 1)
                let turn = value.second?.rotation.radians ?? 0
                switch start {
                case .photo(var photo):
                    guard var placement = photo.placement else { return }
                    placement.centerX += dx
                    placement.centerY += dy
                    placement.width = min(max(placement.width * scale, BorderPlacement.minWidth), BorderPlacement.maxWidth)
                    placement.rotation += turn
                    photo.placement = placement
                    design.layers[index] = .photo(photo)
                case .text(var text):
                    guard var position = text.position, let size = text.size else { return }
                    position.centerX += dx
                    position.centerY += dy
                    position.rotation += turn
                    text.position = position
                    text.size = min(max(size * scale, TextLayer.minSize), TextLayer.maxSize)
                    design.layers[index] = .text(text)
                }
            }
            .onEnded { _ in
                if let start = gestureStart, let index = selectedIndex, !isOnPoster(design.layers[index]) {
                    withAnimation(.spring(duration: 0.35)) { design.layers[index] = start }
                }
                gestureStart = nil
            }
    }

    private func isOnPoster(_ layer: PosterLayer) -> Bool {
        switch layer {
        case .photo(let photo): return photo.placement.map(layout.isValid) ?? true
        case .text(let text):
            guard let position = text.position else { return true }
            return (0...1).contains(position.centerX) && (0...1).contains(position.centerY)
        }
    }

    // MARK: - Layer strip (drag tiles to reorder; right = on top)

    private var layerStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Layers").font(.caption.bold())
                Text("Drag to reorder · right is on top").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { showPhotoPicker = true } label: { Label("Photo", systemImage: "photo.badge.plus") }
                    .disabled(design.photos.count >= PosterDesign.maxPhotos)
                Button { addText() } label: { Label("Text", systemImage: "textformat") }
            }
            .font(.caption)
            .buttonStyle(.bordered)
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(design.layers) { layer in
                        layerTile(layer)
                            .onTapGesture { select(layer.id) }
                            .onDrag {
                                draggingID = layer.id
                                return NSItemProvider(object: layer.id as NSString)
                            }
                            .onDrop(of: [UTType.text], delegate: LayerDropDelegate(
                                targetID: layer.id, layers: $design.layers, draggingID: $draggingID
                            ))
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func layerTile(_ layer: PosterLayer) -> some View {
        let selected = layer.id == selectedID
        Group {
            switch layer {
            case .photo(let photo):
                if let image = displays[photo.assetID] {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color.gray.opacity(0.3)
                }
            case .text(let text):
                ZStack {
                    Color(.tertiarySystemFill)
                    VStack(spacing: 2) {
                        Image(systemName: "textformat").font(.caption)
                        Text(text.displayText(year: year, includedPhotos: includedPhotos))
                            .font(.system(size: 9))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 2)
                    }
                }
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 3))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(accessibilityName(layer))
    }

    // MARK: - Inspector for the selected layer

    @ViewBuilder
    private var inspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let index = selectedIndex {
                switch design.layers[index] {
                case .photo(let photo):
                    sliders(index: index)
                    HStack {
                        Button(photo.zoom > 1.001 ? "Cropped" : "Crop") { cropping = photo }
                        stackButtons(index)
                        Spacer()
                        Button(role: .destructive) { delete(index) } label: { Image(systemName: "trash") }
                    }
                    .buttonStyle(.bordered)
                case .text(let text):
                    textControls(text, index: index)
                    sliders(index: index)
                    HStack {
                        stackButtons(index)
                        Spacer()
                        Button(role: .destructive) { delete(index) } label: { Image(systemName: "trash") }
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Text("Select a layer to edit it.").foregroundStyle(.secondary)
            }

            HStack {
                Button { stepZoom(-1) } label: { Image(systemName: "minus.magnifyingglass") }
                    .disabled(zoom <= Self.zoomLevels.first!)
                Text("\(Int(zoom))×").monospacedDigit().frame(width: 32)
                Button { stepZoom(1) } label: { Image(systemName: "plus.magnifyingglass") }
                    .disabled(zoom >= Self.zoomLevels.last!)
                Spacer()
                Text("Drag, pinch or twist anywhere on the poster.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func textControls(_ text: TextLayer, index: Int) -> some View {
        TextField("Text", text: Binding(
            get: { text.displayText(year: year, includedPhotos: includedPhotos) },
            set: { newValue in updateText(index) { $0.text = newValue } }
        ))
        .textFieldStyle(.roundedBorder)
        HStack {
            Picker("Font", selection: Binding(
                get: { text.font },
                set: { newValue in updateText(index) { $0.font = newValue } }
            )) {
                ForEach(FontStyle.allCases, id: \.self) { style in
                    Text(style.title).font(Font(ArtworkRenderer.font(style, bold: false, size: 16) as CTFont)).tag(style)
                }
            }
            .pickerStyle(.menu)
            Toggle("Bold", isOn: Binding(
                get: { text.bold },
                set: { newValue in updateText(index) { $0.bold = newValue } }
            ))
            .toggleStyle(.button)
            ColorPicker("Color", selection: Binding(
                get: { Color(uiColor: ArtworkRenderer.textColor(text, background: session.artwork.settings.background)) },
                set: { newValue in updateText(index) { $0.color = RGB8(newValue) } }
            ), supportsOpacity: false)
            .labelsHidden()
            if text.color != nil {
                Button("Auto Color") { updateText(index) { $0.color = nil } }
                    .font(.caption)
            }
        }
        if text.role != .custom, text.text != nil {
            Button(text.role == .year ? "Use the Year" : "Use the Photo Count") {
                updateText(index) { $0.text = nil }
            }
            .font(.caption)
        }
    }

    private func sliders(index: Int) -> some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 28)
                Slider(value: sizeBinding(index), in: sizeRange(index))
            }
            HStack {
                Image(systemName: "rotate.right").frame(width: 28)
                Slider(value: rotationBinding(index), in: -180...180, step: 1)
                Text("\(Int(rotationBinding(index).wrappedValue))°")
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private func stackButtons(_ index: Int) -> some View {
        Button { moveLayer(index, by: -1) } label: { Image(systemName: "square.2.layers.3d.bottom.filled") }
            .disabled(index == 0)
            .accessibilityLabel("Send backward")
        Button { moveLayer(index, by: 1) } label: { Image(systemName: "square.2.layers.3d.top.filled") }
            .disabled(index == design.layers.count - 1)
            .accessibilityLabel("Bring forward")
    }

    // MARK: - Bindings

    private func sizeRange(_ index: Int) -> ClosedRange<Double> {
        if case .text = design.layers[index] { return TextLayer.minSize...0.15 }
        return BorderPlacement.minWidth...BorderPlacement.maxWidth
    }

    private func sizeBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: {
                guard design.layers.indices.contains(index) else { return 0.1 }
                switch design.layers[index] {
                case .photo(let photo): return photo.placement?.width ?? 0.1
                case .text(let text): return text.size ?? 0.04
                }
            },
            set: { value in
                guard design.layers.indices.contains(index) else { return }
                switch design.layers[index] {
                case .photo(var photo):
                    photo.placement?.width = value
                    design.layers[index] = .photo(photo)
                case .text(var text):
                    text.size = value
                    design.layers[index] = .text(text)
                }
            }
        )
    }

    /// Degrees, normalized to -180...180.
    private func rotationBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: {
                guard design.layers.indices.contains(index) else { return 0 }
                let radians: Double
                switch design.layers[index] {
                case .photo(let photo): radians = photo.placement?.rotation ?? 0
                case .text(let text): radians = text.position?.rotation ?? 0
                }
                var degrees = (radians * 180 / .pi).truncatingRemainder(dividingBy: 360)
                if degrees > 180 { degrees -= 360 }
                if degrees < -180 { degrees += 360 }
                return degrees
            },
            set: { degrees in
                guard design.layers.indices.contains(index) else { return }
                let radians = degrees * .pi / 180
                switch design.layers[index] {
                case .photo(var photo):
                    photo.placement?.rotation = radians
                    design.layers[index] = .photo(photo)
                case .text(var text):
                    text.position?.rotation = radians
                    design.layers[index] = .text(text)
                }
            }
        )
    }

    // MARK: - Actions

    private func select(_ id: String) {
        selectedID = id
        guard zoom > 1, let index = selectedIndex else { return }
        withAnimation { focus = center(of: design.layers[index]) }
    }

    private func center(of layer: PosterLayer) -> CGPoint {
        switch layer {
        case .photo(let photo):
            let p = photo.placement ?? BorderPlacement(centerX: 0.5, centerY: 0.5, width: 0.1)
            return CGPoint(x: p.centerX, y: p.centerY)
        case .text(let text):
            let p = layout.position(for: text)
            return CGPoint(x: p.centerX, y: p.centerY)
        }
    }

    private func stepZoom(_ direction: Int) {
        guard let current = Self.zoomLevels.firstIndex(of: zoom) else { return }
        let next = min(max(current + direction, 0), Self.zoomLevels.count - 1)
        if let index = selectedIndex { focus = center(of: design.layers[index]) }
        withAnimation { zoom = Self.zoomLevels[next] }
    }

    private func updateText(_ index: Int, _ change: (inout TextLayer) -> Void) {
        guard design.layers.indices.contains(index), case .text(var text) = design.layers[index] else { return }
        change(&text)
        design.layers[index] = .text(text)
    }

    private func replace(_ layer: PosterLayer) {
        if let index = design.layers.firstIndex(where: { $0.id == layer.id }) { design.layers[index] = layer }
    }

    private func moveLayer(_ index: Int, by offset: Int) {
        withAnimation { design.move(from: index, to: index + offset) }
    }

    private func delete(_ index: Int) {
        guard design.layers.indices.contains(index) else { return }
        _ = withAnimation { design.layers.remove(at: index) }
        selectedID = nil
    }

    private func addText() {
        var text = TextLayer(role: .custom, text: "Your text", bold: true)
        text.size = layout.defaultTextSize(for: .custom)
        text.position = TextPosition(centerX: 0.5, centerY: 0.5)
        design.layers.append(.text(text))
        select(PosterLayer.text(text).id)
    }

    private func addPhoto(_ assetID: String) async {
        guard design.photos.count < PosterDesign.maxPhotos else { return }
        var photo = BorderPhoto(assetID: assetID, aspect: session.aspect(of: assetID))
        let count = design.photos.count + 1
        photo.placement = layout.defaultPlacement(index: count - 1, count: count, aspect: layout.aspect(for: photo))
        design.layers.append(.photo(photo))
        select(PosterLayer.photo(photo).id)
        if let image = await session.displayImage(for: assetID) {
            sources[assetID] = image
            refreshDisplay(for: photo)
        }
    }

    private func refreshDisplay(for photo: BorderPhoto) {
        guard let source = sources[photo.assetID] else { return }
        displays[photo.assetID] = ArtworkRenderer.croppedImage(source, photo: photo, aspect: layout.aspect(for: photo))
    }

    // MARK: - Load & save

    /// Works on explicit positions so gestures always have a starting point.
    private func load() async {
        loaded = true
        let layout = self.layout
        var working = session.artwork.design
        let photos = working.photos
        working.layers = working.layers.map { layer in
            switch layer {
            case .photo(var photo):
                let index = photos.firstIndex { $0.assetID == photo.assetID } ?? 0
                photo.placement = layout.resolvedPlacement(for: photo, index: index, count: photos.count)
                return .photo(photo)
            case .text(var text):
                text.position = layout.position(for: text)
                text.size = layout.fontSize(for: text) / Double(layout.canvas.short)
                return .text(text)
            }
        }
        design = working
        selectedID = working.layers.last?.id

        for photo in working.photos {
            if let image = await session.displayImage(for: photo.assetID) {
                sources[photo.assetID] = image
                refreshDisplay(for: photo)
            }
        }
        guard let input = session.input else { return }
        let borderImages = session.borderImages
        background = await Task.detached(priority: .userInitiated) {
            ArtworkRenderer.preview(input, longEdge: 2400, borderImages: borderImages, includeLayers: false)
        }.value
    }

    /// Positions and sizes still at their defaults are saved as "default", so
    /// they keep adapting when the print size or orientation changes.
    private func save() {
        let layout = self.layout
        let photos = design.photos
        let normalized = PosterDesign(layers: design.layers.map { layer in
            switch layer {
            case .photo(var photo):
                let index = photos.firstIndex { $0.assetID == photo.assetID } ?? 0
                if photo.placement == layout.defaultPlacement(index: index, count: photos.count, aspect: layout.aspect(for: photo)) {
                    photo.placement = nil
                }
                return .photo(photo)
            case .text(var text):
                if text.position == layout.defaultTextPosition(for: text.role) { text.position = nil }
                if let size = text.size, abs(size - layout.defaultTextSize(for: text.role)) < 1e-9 { text.size = nil }
                return .text(text)
            }
        })
        Task { await session.setDesign(normalized) }
        dismiss()
    }

    private func accessibilityName(_ layer: PosterLayer) -> String {
        switch layer {
        case .photo: return "Photo layer"
        case .text(let text): return "Text: \(text.displayText(year: year, includedPhotos: includedPhotos))"
        }
    }

    private func fit(_ canvas: PixelSize, in size: CGSize) -> CGSize {
        let aspect = CGFloat(canvas.width) / CGFloat(canvas.height)
        let width = max(size.width, 1), height = max(size.height, 1)
        return width / height > aspect
            ? CGSize(width: height * aspect, height: height)
            : CGSize(width: width, height: width / aspect)
    }
}

/// Reorders layers live while a tile is dragged over another tile.
private struct LayerDropDelegate: DropDelegate {
    let targetID: String
    @Binding var layers: [PosterLayer]
    @Binding var draggingID: String?

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingID, dragging != targetID,
              let from = layers.firstIndex(where: { $0.id == dragging }),
              let to = layers.firstIndex(where: { $0.id == targetID }) else { return }
        withAnimation {
            layers.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }
}
