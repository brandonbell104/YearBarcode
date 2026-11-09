import SwiftUI
import YearBarcodeCore

/// Full-screen poster viewer: renders a sharper preview than the inline one,
/// with pinch to zoom, drag to pan, double-tap to zoom, and a rotate button
/// so landscape posters can use the whole screen.
struct PosterViewer: View {
    @Environment(\.dismiss) private var dismiss
    let session: ArtworkSession

    @State private var detailed: CGImage?
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var rotated = false

    private static let maxScale: CGFloat = 8

    var body: some View {
        let settings = session.artwork.settings
        let canvas = settings.canvas
        GeometryReader { geometry in
            let aspect = CGFloat(canvas.width) / CGFloat(canvas.height)
            // Rotating swaps which way the poster has to fit.
            let fitted = fit(aspect: rotated ? 1 / aspect : aspect, in: geometry.size)
            let size = rotated ? CGSize(width: fitted.height, height: fitted.width) : fitted
            ZStack {
                Color.black.ignoresSafeArea()
                Group {
                    if let image = detailed ?? session.preview {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(scale > 1.5 ? .none : .high)
                    } else {
                        Color(settings.background).overlay(ProgressView())
                    }
                }
                .frame(width: size.width, height: size.height)
                .rotationEffect(.degrees(rotated ? 90 : 0))
                .scaleEffect(scale)
                .offset(offset)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                .accessibilityLabel("Poster, full screen")
                .accessibilityHint("Pinch to zoom, double-tap to zoom in or out")
            }
            .contentShape(Rectangle())
            .gesture(zoomAndPan(viewSize: geometry.size, contentSize: fitted))
            .onTapGesture(count: 2) { location in
                withAnimation(.snappy) {
                    if scale > 1.01 {
                        reset()
                    } else {
                        // Zoom toward the tapped point.
                        let target: CGFloat = 3
                        let dx = (geometry.size.width / 2 - location.x) * (target - 1)
                        let dy = (geometry.size.height / 2 - location.y) * (target - 1)
                        scale = target
                        baseScale = target
                        offset = clamp(CGSize(width: dx, height: dy), scale: target, viewSize: geometry.size, contentSize: fitted)
                        baseOffset = offset
                    }
                }
            }
        }
        .overlay(alignment: .top) { toolbar }
        .statusBarHidden()
        .task { await renderDetailed() }
    }

    private var toolbar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .accessibilityLabel("Close")
            Spacer()
            if detailed == nil {
                ProgressView().tint(.white).padding(.trailing, 8)
            }
            Button {
                withAnimation(.snappy) {
                    rotated.toggle()
                    reset()
                }
            } label: {
                Image(systemName: "rotate.right")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .accessibilityLabel("Rotate view")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Gestures

    private func zoomAndPan(viewSize: CGSize, contentSize: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(baseScale * value.magnification, 1), Self.maxScale)
                offset = clamp(baseOffset, scale: scale, viewSize: viewSize, contentSize: contentSize)
            }
            .onEnded { _ in
                baseScale = scale
                baseOffset = offset
                if scale <= 1.01 { withAnimation(.snappy) { reset() } }
            }
            .simultaneously(with: DragGesture(minimumDistance: 1)
                .onChanged { value in
                    guard scale > 1.01 else { return }
                    let proposed = CGSize(
                        width: baseOffset.width + value.translation.width,
                        height: baseOffset.height + value.translation.height
                    )
                    offset = clamp(proposed, scale: scale, viewSize: viewSize, contentSize: contentSize)
                }
                .onEnded { _ in baseOffset = offset }
            )
    }

    /// Keeps the zoomed poster covering the screen instead of sliding away.
    private func clamp(_ proposed: CGSize, scale: CGFloat, viewSize: CGSize, contentSize: CGSize) -> CGSize {
        let maxX = max(0, (contentSize.width * scale - viewSize.width) / 2)
        let maxY = max(0, (contentSize.height * scale - viewSize.height) / 2)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }

    private func reset() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
    }

    private func fit(aspect: CGFloat, in size: CGSize) -> CGSize {
        let width = max(size.width, 1), height = max(size.height, 1)
        return width / height > aspect
            ? CGSize(width: height * aspect, height: height)
            : CGSize(width: width, height: width / aspect)
    }

    // MARK: - Rendering

    /// A larger render than the inline preview so zooming shows real detail.
    private func renderDetailed() async {
        guard let input = session.input else { return }
        let images = session.borderImages
        detailed = await Task.detached(priority: .userInitiated) {
            ArtworkRenderer.preview(input, longEdge: 3600, borderImages: images)
        }.value
    }
}
