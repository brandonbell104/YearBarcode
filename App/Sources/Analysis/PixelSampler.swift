import CoreGraphics
import UIKit
import YearBarcodeCore

/// Draws images into sRGB bitmaps with correct orientation and color management.
enum PixelSampler {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// RGBX bytes (4 per pixel), flattened onto opaque white.
    static func rgbx(of image: UIImage, width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return }
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            // UIKit drawing (which honors imageOrientation) expects a top-left origin.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(context)
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
            UIGraphicsPopContext()
        }
        return pixels
    }

    /// Tightly packed RGB for a poster overlay.
    static func rgb(fromRGBX rgbx: [UInt8], width: Int, height: Int) -> [UInt8] {
        var rgb = [UInt8](repeating: 255, count: width * height * 3)
        for i in 0..<(width * height) {
            rgb[i * 3] = rgbx[i * 4]
            rgb[i * 3 + 1] = rgbx[i * 4 + 1]
            rgb[i * 3 + 2] = rgbx[i * 4 + 2]
        }
        return rgb
    }

    /// Renders with a drawing closure (UIKit coordinates, origin top-left) into an RGB overlay.
    static func overlay(rect: PixelRect, draw: (CGContext, CGSize) -> Void) -> RasterOverlay {
        let width = rect.width, height = rect.height
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return }
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(context)
            draw(context, CGSize(width: width, height: height))
            UIGraphicsPopContext()
        }
        return RasterOverlay(rect: rect, pixels: rgb(fromRGBX: pixels, width: width, height: height))
    }

    /// CGImage from packed RGB (for on-screen previews).
    static func cgImage(rgb: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgb) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
            space: sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
