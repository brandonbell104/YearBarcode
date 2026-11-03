import Foundation

/// An optional decorative photo in the poster border. It never affects the
/// barcode's colors or the included photo count, even when drawn on top of it.
public struct BorderPhoto: Codable, Hashable, Identifiable, Sendable {
    public var assetID: String
    /// 1 = the whole photo (no cropping); higher values zoom in, up to 4.
    public var zoom: Double
    /// Crop center in normalized photo coordinates (0...1, origin top-left).
    public var centerX: Double
    public var centerY: Double
    /// Where the photo sits on the poster. Nil uses the default slot layout.
    public var placement: BorderPlacement?
    /// The photo's own width / height, so it is shown uncropped in its original
    /// shape. Nil for photos saved before this existed (they use the slot shape).
    public var aspect: Double?

    public var id: String { assetID }

    public init(
        assetID: String,
        zoom: Double = 1,
        centerX: Double = 0.5,
        centerY: Double = 0.5,
        placement: BorderPlacement? = nil,
        aspect: Double? = nil
    ) {
        self.assetID = assetID
        self.zoom = zoom
        self.centerX = centerX
        self.centerY = centerY
        self.placement = placement
        self.aspect = aspect
    }

    public static let maxZoom = 4.0

    /// Source rectangle (in photo pixels/points) to draw into a slot of `slotAspect`
    /// (width / height). The center is clamped so the crop never leaves the photo.
    public func cropRect(imageWidth: Double, imageHeight: Double, slotAspect: Double) -> (x: Double, y: Double, width: Double, height: Double) {
        let imageAspect = imageWidth / imageHeight
        var width: Double, height: Double
        if imageAspect > slotAspect {
            height = imageHeight
            width = height * slotAspect
        } else {
            width = imageWidth
            height = width / slotAspect
        }
        let z = min(max(zoom, 1), Self.maxZoom)
        width /= z
        height /= z
        let cx = min(max(centerX * imageWidth, width / 2), imageWidth - width / 2)
        let cy = min(max(centerY * imageHeight, height / 2), imageHeight - height / 2)
        return (cx - width / 2, cy - height / 2, width, height)
    }

    /// Normalizes zoom and center to the valid range for a given photo and slot.
    public func clamped(imageWidth: Double, imageHeight: Double, slotAspect: Double) -> BorderPhoto {
        let crop = cropRect(imageWidth: imageWidth, imageHeight: imageHeight, slotAspect: slotAspect)
        return BorderPhoto(
            assetID: assetID,
            zoom: min(max(zoom, 1), Self.maxZoom),
            centerX: (crop.x + crop.width / 2) / imageWidth,
            centerY: (crop.y + crop.height / 2) / imageHeight,
            placement: placement,
            aspect: aspect
        )
    }
}

/// Free placement of a border photo, stored relative to the poster so it
/// carries over between print sizes.
public struct BorderPlacement: Codable, Hashable, Sendable {
    /// Center as a fraction of the poster width (0 = left edge).
    public var centerX: Double
    /// Center as a fraction of the poster height (0 = top edge).
    public var centerY: Double
    /// Photo width as a fraction of the poster's short side.
    public var width: Double
    /// Clockwise rotation in radians.
    public var rotation: Double

    public init(centerX: Double, centerY: Double, width: Double, rotation: Double = 0) {
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.rotation = rotation
    }

    public static let minWidth = 0.04
    public static let maxWidth = 0.6
}

/// A rotated rectangle in poster pixels.
public struct OrientedRect: Hashable, Sendable {
    public var centerX: Double
    public var centerY: Double
    public var width: Double
    public var height: Double
    public var rotation: Double

    /// Corners in clockwise order starting top-left (before rotation).
    public var corners: [(x: Double, y: Double)] {
        let c = cos(rotation), s = sin(rotation)
        return [(-width / 2, -height / 2), (width / 2, -height / 2), (width / 2, height / 2), (-width / 2, height / 2)].map { p in
            (x: centerX + p.0 * c - p.1 * s, y: centerY + p.0 * s + p.1 * c)
        }
    }

    /// Smallest pixel rectangle containing the rotated rectangle.
    public var boundingBox: PixelRect {
        let points = corners
        let minX = Int(points.map(\.x).min()!.rounded(.down)), maxX = Int(points.map(\.x).max()!.rounded(.up))
        let minY = Int(points.map(\.y).min()!.rounded(.down)), maxY = Int(points.map(\.y).max()!.rounded(.up))
        return PixelRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }

    /// Exact overlap test with an axis-aligned rectangle (separating axis theorem).
    public func intersects(_ rect: PixelRect) -> Bool {
        let a = corners
        let b: [(x: Double, y: Double)] = [
            (Double(rect.x), Double(rect.y)), (Double(rect.maxX), Double(rect.y)),
            (Double(rect.maxX), Double(rect.maxY)), (Double(rect.x), Double(rect.maxY)),
        ]
        let axes: [(Double, Double)] = [(1, 0), (0, 1), (cos(rotation), sin(rotation)), (-sin(rotation), cos(rotation))]
        for axis in axes {
            let pa = a.map { $0.x * axis.0 + $0.y * axis.1 }
            let pb = b.map { $0.x * axis.0 + $0.y * axis.1 }
            if pa.max()! <= pb.min()! || pb.max()! <= pa.min()! { return false }
        }
        return true
    }
}

extension PosterLayout {
    /// Shape of the default slots (width / height), used when a photo's own shape is unknown.
    public var photoAspect: Double { orientation == .landscape ? 4.0 / 3.0 : 4.0 / 5.0 }

    /// The photo's own shape, falling back to the slot shape.
    public func aspect(for photo: BorderPhoto) -> Double {
        if let aspect = photo.aspect, aspect.isFinite, aspect > 0 { return aspect }
        return photoAspect
    }

    /// The tidy default layout (row in landscape, side borders in portrait). The
    /// photo keeps its own shape and is sized to fit inside its slot.
    public func defaultPlacement(index: Int, count: Int, aspect: Double? = nil) -> BorderPlacement {
        let shape = aspect ?? photoAspect
        let slots = photoSlots(count: count)
        guard index < slots.count else {
            // Beyond the tidy slots: cascade from the center so each new photo is visible.
            let step = 0.03 * Double(index - slots.count)
            let width = shape >= 1 ? 0.15 : 0.15 * shape
            return BorderPlacement(
                centerX: min(0.9, 0.5 + step),
                centerY: min(0.9, 0.5 + step * Double(canvas.width) / Double(canvas.height)),
                width: width
            )
        }
        let slot = slots[index]
        let width = min(Double(slot.width), Double(slot.height) * shape)
        return BorderPlacement(
            centerX: (Double(slot.x) + Double(slot.width) / 2) / Double(canvas.width),
            centerY: (Double(slot.y) + Double(slot.height) / 2) / Double(canvas.height),
            width: width / Double(canvas.short)
        )
    }

    public func frame(for placement: BorderPlacement, aspect: Double? = nil) -> OrientedRect {
        let width = placement.width * Double(canvas.short)
        return OrientedRect(
            centerX: placement.centerX * Double(canvas.width),
            centerY: placement.centerY * Double(canvas.height),
            width: width,
            height: width / (aspect ?? photoAspect),
            rotation: placement.rotation
        )
    }

    /// Where and how big a photo is drawn, in poster pixels.
    public func frame(for photo: BorderPhoto, index: Int, count: Int) -> OrientedRect {
        frame(for: resolvedPlacement(for: photo, index: index, count: count), aspect: aspect(for: photo))
    }

    /// Photos may go anywhere, over the barcode and labels and partly past the
    /// poster edge (that part is cropped). They only need a sensible size and
    /// their center on the poster, so at least a quarter of the photo shows.
    public func isValid(_ placement: BorderPlacement) -> Bool {
        guard placement.width >= BorderPlacement.minWidth, placement.width <= BorderPlacement.maxWidth else { return false }
        return (0...1).contains(placement.centerX) && (0...1).contains(placement.centerY)
    }

    /// The placement to draw: the photo's own if still valid for this
    /// poster (sizes and orientations differ), else its default slot.
    public func resolvedPlacement(for photo: BorderPhoto, index: Int, count: Int) -> BorderPlacement {
        if let placement = photo.placement, isValid(placement) { return placement }
        return defaultPlacement(index: index, count: count, aspect: aspect(for: photo))
    }
}
