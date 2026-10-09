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

    public var id: String { assetID }

    public init(assetID: String, zoom: Double = 1, centerX: Double = 0.5, centerY: Double = 0.5) {
        self.assetID = assetID
        self.zoom = zoom
        self.centerX = centerX
        self.centerY = centerY
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
            centerY: (crop.y + crop.height / 2) / imageHeight
        )
    }
}
