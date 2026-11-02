import Foundation

/// An optional decorative photo in the poster border. It never affects the
/// barcode or the included photo count.
public struct BorderPhoto: Codable, Hashable, Identifiable, Sendable {
    public var assetID: String
    /// 1 = the largest crop of the slot's aspect ratio that fits the photo; up to 4.
    public var zoom: Double
    /// Crop center in normalized photo coordinates (0...1, origin top-left).
    public var centerX: Double
    public var centerY: Double
    /// Where the photo sits on the poster. Nil uses the default slot layout.
    public var placement: BorderPlacement?

    public var id: String { assetID }

    public init(assetID: String, zoom: Double = 1, centerX: Double = 0.5, centerY: Double = 0.5, placement: BorderPlacement? = nil) {
        self.assetID = assetID
        self.zoom = zoom
        self.centerX = centerX
        self.centerY = centerY
        self.placement = placement
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
            placement: placement
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
    /// Width / height of border photos.
    public var photoAspect: Double { orientation == .landscape ? 4.0 / 3.0 : 4.0 / 5.0 }

    /// Areas photos may never cover.
    public var reservedRects: [PixelRect] { [barcode, yearLabel, countLabel, watermark] }

    /// The tidy default layout (row in landscape, side borders in portrait).
    public func defaultPlacement(index: Int, count: Int) -> BorderPlacement {
        let slots = photoSlots(count: count)
        let slot = slots[min(index, slots.count - 1)]
        return BorderPlacement(
            centerX: (Double(slot.x) + Double(slot.width) / 2) / Double(canvas.width),
            centerY: (Double(slot.y) + Double(slot.height) / 2) / Double(canvas.height),
            width: Double(slot.width) / Double(canvas.short)
        )
    }

    public func frame(for placement: BorderPlacement) -> OrientedRect {
        let width = placement.width * Double(canvas.short)
        return OrientedRect(
            centerX: placement.centerX * Double(canvas.width),
            centerY: placement.centerY * Double(canvas.height),
            width: width,
            height: width / photoAspect,
            rotation: placement.rotation
        )
    }

    /// On the poster, a sensible size, and clear of the barcode and every label.
    public func isValid(_ placement: BorderPlacement) -> Bool {
        guard placement.width >= BorderPlacement.minWidth, placement.width <= BorderPlacement.maxWidth else { return false }
        let box = frame(for: placement)
        let w = Double(canvas.width), h = Double(canvas.height)
        guard box.corners.allSatisfy({ $0.x >= 0 && $0.y >= 0 && $0.x <= w && $0.y <= h }) else { return false }
        return !reservedRects.contains { box.intersects($0) }
    }

    /// The placement to draw: the photo's own if still valid for this
    /// poster (sizes and orientations differ), else its default slot.
    public func resolvedPlacement(for photo: BorderPhoto, index: Int, count: Int) -> BorderPlacement {
        if let placement = photo.placement, isValid(placement) { return placement }
        return defaultPlacement(index: index, count: count)
    }
}
