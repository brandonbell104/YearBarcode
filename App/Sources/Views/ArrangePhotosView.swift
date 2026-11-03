import SwiftUI
import YearBarcodeCore

/// Arrange border photos on the poster. Pick a photo from the thumbnails (or
/// tap it), then drag, pinch and twist anywhere on the poster: the gestures
/// always apply to the selected photo, so small photos are easy to handle.
/// The poster view can be zoomed in, and sliders give precise size and angle.
/// Photos can go anywhere, including over the barcode and partly off the edge
/// (cropped). One dragged so its center leaves the poster springs back.
struct ArrangePhotosView: View {
    @Environment(\.dismiss) private var dismiss
    let session: ArtworkSession

    @State private var placements: [BorderPlacement] = []
    @State private var background: CGImage?
    @State private var images: [String: UIImage] = [:]
    @State private var selected = 0
    @State private var gestureStart: BorderPlacement?
    /// Poster view magnification (1 = whole poster fits).
    @State private var zoom: CGFloat = 1
    /// Poster point (fractions) kept centered when zoomed in.
    @State private var focus = CGPoint(x: 0.5, y: 0.5)

    private static let zoomLevels: [CGFloat] = [1, 2, 3, 4]

    private var photos: [BorderPhoto] { session.artwork.borderPhotos }
    private var layout: PosterLayout {
        PosterLayout(printSize: session.artwork.settings.printSize, orientation: session.artwork.settings.orientation)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                GeometryReader { geometry in
                    poster(in: geometry.size)
                }
                .clipped()
                .background(Color(.secondarySystemBackground))

                thumbnails
                controls
            }
            .padding(.bottom)
            .navigationTitle("Arrange Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { save() } }
            }
            .task { await load() }
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
            ForEach(Array(placements.indices), id: \.self) { index in
                photoView(index, posterSize: size)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .offset(x: origin.x, y: origin.y)
        .frame(width: available.width, height: available.height, alignment: .topLeading)
        // Gestures work anywhere in the area and move the selected photo.
        .contentShape(Rectangle())
        .gesture(transformGesture(posterSize: size))
    }

    /// Top-left of the poster inside the view: centered when it fits, otherwise
    /// centered on `focus` but never scrolled past the poster's edges.
    private func posterOrigin(size: CGSize, in available: CGSize) -> CGPoint {
        func axis(_ length: CGFloat, _ space: CGFloat, _ focus: CGFloat) -> CGFloat {
            if length <= space { return (space - length) / 2 }
            let ideal = space / 2 - focus * length
            return min(0, max(space - length, ideal))
        }
        return CGPoint(
            x: axis(size.width, available.width, focus.x),
            y: axis(size.height, available.height, focus.y)
        )
    }

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
                style: StrokeStyle(lineWidth: 2, dash: selected == index ? [] : [4])
            )
        }
        .rotationEffect(.radians(placement.rotation))
        .contentShape(Rectangle())
        .onTapGesture { select(index) } // before .position, so only the photo itself is tappable
        .position(x: placement.centerX * posterSize.width, y: placement.centerY * posterSize.height)
        .accessibilityLabel("Border photo \(index + 1)")
    }

    private func transformGesture(posterSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .simultaneously(with: MagnifyGesture())
            .simultaneously(with: RotateGesture())
            .onChanged { value in
                guard placements.indices.contains(selected) else { return }
                if gestureStart == nil { gestureStart = placements[selected] }
                guard let start = gestureStart else { return }
                let translation = value.first?.first?.translation ?? .zero
                let magnification = value.first?.second?.magnification ?? 1
                let rotation = value.second?.rotation.radians ?? 0
                var candidate = start
                candidate.centerX = start.centerX + translation.width / posterSize.width
                candidate.centerY = start.centerY + translation.height / posterSize.height
                candidate.width = min(max(start.width * magnification, BorderPlacement.minWidth), BorderPlacement.maxWidth)
                candidate.rotation = start.rotation + rotation
                placements[selected] = candidate
            }
            .onEnded { _ in
                if let start = gestureStart, placements.indices.contains(selected), !layout.isValid(placements[selected]) {
                    withAnimation(.spring(duration: 0.35)) { placements[selected] = start }
                }
                gestureStart = nil
            }
    }

    // MARK: - Photo picker strip

    private var thumbnails: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(photos.enumerated()), id: \.offset) { index, photo in
                    Button {
                        select(index)
                    } label: {
                        Group {
                            if let image = images[photo.assetID] {
                                Image(uiImage: image).resizable().scaledToFill()
                            } else {
                                Color.gray.opacity(0.3)
                            }
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(selected == index ? Color.accentColor : Color.clear, lineWidth: 3)
                        )
                    }
                    .accessibilityLabel("Select photo \(index + 1)")
                }
            }
            .padding(.horizontal)
        }
        .frame(height: 70)
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 10) {
            if placements.indices.contains(selected) {
                HStack {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 28)
                    Slider(value: sizeBinding, in: BorderPlacement.minWidth...BorderPlacement.maxWidth)
                }
                HStack {
                    Image(systemName: "rotate.right").frame(width: 28)
                    Slider(value: rotationBinding, in: -180...180, step: 1)
                    Text("\(Int(rotationBinding.wrappedValue))°")
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
            }
            HStack {
                Button { stepZoom(-1) } label: { Image(systemName: "minus.magnifyingglass") }
                    .disabled(zoom <= Self.zoomLevels.first!)
                Text("\(Int(zoom))×").monospacedDigit().frame(width: 32)
                Button { stepZoom(1) } label: { Image(systemName: "plus.magnifyingglass") }
                    .disabled(zoom >= Self.zoomLevels.last!)
                Spacer()
                Button("Straighten") {
                    guard placements.indices.contains(selected) else { return }
                    withAnimation { placements[selected].rotation = 0 }
                }
                Button("Reset All") {
                    withAnimation { placements = defaults() }
                }
            }
            .buttonStyle(.bordered)
            Text("Pick a photo, then drag, pinch or twist anywhere on the poster. Zoom in for detail.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal)
    }

    private var sizeBinding: Binding<Double> {
        Binding(
            get: { placements.indices.contains(selected) ? placements[selected].width : BorderPlacement.minWidth },
            set: { if placements.indices.contains(selected) { placements[selected].width = $0 } }
        )
    }

    /// Degrees, normalized to -180...180 for the slider.
    private var rotationBinding: Binding<Double> {
        Binding(
            get: {
                guard placements.indices.contains(selected) else { return 0 }
                var degrees = placements[selected].rotation * 180 / .pi
                degrees = degrees.truncatingRemainder(dividingBy: 360)
                if degrees > 180 { degrees -= 360 }
                if degrees < -180 { degrees += 360 }
                return degrees
            },
            set: { if placements.indices.contains(selected) { placements[selected].rotation = $0 * .pi / 180 } }
        )
    }

    private func select(_ index: Int) {
        selected = index
        if zoom > 1, placements.indices.contains(index) {
            withAnimation { focus = CGPoint(x: placements[index].centerX, y: placements[index].centerY) }
        }
    }

    private func stepZoom(_ direction: Int) {
        guard let current = Self.zoomLevels.firstIndex(of: zoom) else { return }
        let next = min(max(current + direction, 0), Self.zoomLevels.count - 1)
        if placements.indices.contains(selected) {
            focus = CGPoint(x: placements[selected].centerX, y: placements[selected].centerY)
        }
        withAnimation { zoom = Self.zoomLevels[next] }
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
        // Sharper background so zooming in stays crisp.
        background = await Task.detached(priority: .userInitiated) {
            ArtworkRenderer.preview(input, longEdge: 2400, borderImages: borderImages, includePhotos: false)
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
        let width = max(size.width, 1), height = max(size.height, 1)
        return width / height > aspect
            ? CGSize(width: height * aspect, height: height)
            : CGSize(width: width, height: width / aspect)
    }
}
