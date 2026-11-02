import SwiftUI
import YearBarcodeCore

/// Drag to move, pinch to resize and twist to rotate border photos directly on
/// the poster. A photo dropped where it would cover the barcode, the text or
/// the poster edge springs back to where it started.
struct ArrangePhotosView: View {
    @Environment(\.dismiss) private var dismiss
    let session: ArtworkSession

    @State private var placements: [BorderPlacement] = []
    @State private var background: CGImage?
    @State private var images: [String: UIImage] = [:]
    @State private var selected: Int?
    @State private var gestureStart: BorderPlacement?

    private var photos: [BorderPhoto] { session.artwork.borderPhotos }
    private var layout: PosterLayout {
        PosterLayout(printSize: session.artwork.settings.printSize, orientation: session.artwork.settings.orientation)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                GeometryReader { geometry in
                    let size = fit(layout.canvas, in: geometry.size)
                    ZStack(alignment: .topLeading) {
                        if let background {
                            Image(decorative: background, scale: 1)
                                .resizable()
                                .frame(width: size.width, height: size.height)
                        } else {
                            Color(session.artwork.settings.background)
                                .frame(width: size.width, height: size.height)
                                .overlay(ProgressView())
                        }
                        ForEach(Array(placements.indices), id: \.self) { index in
                            photoView(index, posterSize: size)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
                .padding(.horizontal)

                controls
            }
            .padding(.vertical)
            .navigationTitle("Arrange Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { save() } }
            }
            .task { await load() }
        }
    }

    // MARK: - Photo

    @ViewBuilder
    private func photoView(_ index: Int, posterSize: CGSize) -> some View {
        let placement = placements[index]
        let frame = layout.frame(for: placement)
        let k = posterSize.width / CGFloat(layout.canvas.width)
        let valid = layout.isValid(placement)
        let photo = photos[index]
        Group {
            if let image = images[photo.assetID] {
                Image(uiImage: image).resizable()
            } else {
                Color.gray.opacity(0.3)
            }
        }
        .frame(width: frame.width * k, height: frame.height * k)
        .overlay {
            Rectangle().strokeBorder(
                valid ? (selected == index ? Color.accentColor : Color.clear) : Color.red,
                lineWidth: 2
            )
        }
        .rotationEffect(.radians(placement.rotation))
        .contentShape(Rectangle())
        .gesture(transformGesture(index, posterSize: posterSize))
        .onTapGesture { selected = index }
        .position(x: placement.centerX * posterSize.width, y: placement.centerY * posterSize.height)
        .accessibilityLabel("Border photo \(index + 1)")
    }

    private func transformGesture(_ index: Int, posterSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .simultaneously(with: MagnifyGesture())
            .simultaneously(with: RotateGesture())
            .onChanged { value in
                if gestureStart == nil {
                    gestureStart = placements[index]
                    selected = index
                }
                guard let start = gestureStart else { return }
                let translation = value.first?.first?.translation ?? .zero
                let magnification = value.first?.second?.magnification ?? 1
                let rotation = value.second?.rotation.radians ?? 0
                var candidate = start
                candidate.centerX = start.centerX + translation.width / posterSize.width
                candidate.centerY = start.centerY + translation.height / posterSize.height
                candidate.width = min(max(start.width * magnification, BorderPlacement.minWidth), BorderPlacement.maxWidth)
                candidate.rotation = start.rotation + rotation
                placements[index] = candidate
            }
            .onEnded { _ in
                if let start = gestureStart, !layout.isValid(placements[index]) {
                    withAnimation(.spring(duration: 0.35)) { placements[index] = start }
                }
                gestureStart = nil
            }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 10) {
            Text("Drag to move, pinch to resize, twist to rotate. Photos can't cover the barcode or the text.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Straighten") {
                    guard let index = selected else { return }
                    var straight = placements[index]
                    straight.rotation = 0
                    if layout.isValid(straight) { withAnimation { placements[index] = straight } }
                }
                .disabled(selected == nil)
                Button("Reset All") {
                    withAnimation { placements = defaults() }
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
    }

    // MARK: - Data

    private func defaults() -> [BorderPlacement] {
        photos.indices.map { layout.defaultPlacement(index: $0, count: photos.count) }
    }

    private func load() async {
        let layout = self.layout
        placements = photos.enumerated().map { layout.resolvedPlacement(for: $1, index: $0, count: photos.count) }
        for photo in photos {
            if let source = session.borderImages[photo.assetID] {
                images[photo.assetID] = ArtworkRenderer.croppedImage(source, photo: photo, aspect: layout.photoAspect)
            }
        }
        guard let input = session.input else { return }
        let borderImages = session.borderImages
        background = await Task.detached(priority: .userInitiated) {
            ArtworkRenderer.preview(input, borderImages: borderImages, includePhotos: false)
        }.value
    }

    private func save() {
        let defaults = defaults()
        let updated = photos.enumerated().map { index, photo -> BorderPhoto in
            var photo = photo
            // Keep the tidy default (which adapts to every size) unless the user moved it.
            photo.placement = placements[index] == defaults[index] ? nil : placements[index]
            return photo
        }
        Task { await session.setBorderPhotos(updated) }
        dismiss()
    }

    private func fit(_ canvas: PixelSize, in size: CGSize) -> CGSize {
        let aspect = CGFloat(canvas.width) / CGFloat(canvas.height)
        return size.width / size.height > aspect
            ? CGSize(width: size.height * aspect, height: size.height)
            : CGSize(width: size.width, height: size.width / aspect)
    }
}
