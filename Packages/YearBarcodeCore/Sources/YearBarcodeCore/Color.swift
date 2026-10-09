import Foundation

/// A color in linear-light sRGB primaries. Components are nominally 0...1.
///
/// All averaging happens in this space; values convert back to gamma-encoded
/// sRGB only when a final stripe color is drawn.
public struct LinearRGB: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public static let white = LinearRGB(r: 1, g: 1, b: 1)

    /// Gamma-encoded 8-bit sRGB for drawing.
    public var rgb8: RGB8 {
        RGB8(r: SRGB.encodeByte(r), g: SRGB.encodeByte(g), b: SRGB.encodeByte(b))
    }
}

/// An 8-bit gamma-encoded sRGB color.
public struct RGB8: Codable, Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    public static let white = RGB8(r: 255, g: 255, b: 255)
}

/// sRGB transfer functions (IEC 61966-2-1).
public enum SRGB {
    public static func toLinear(_ encoded: Double) -> Double {
        encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
    }

    public static func toEncoded(_ linear: Double) -> Double {
        let l = min(max(linear, 0), 1)
        return l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055
    }

    private static let byteToLinear: [Double] = (0...255).map { toLinear(Double($0) / 255) }

    public static func linear(fromByte byte: UInt8) -> Double {
        byteToLinear[Int(byte)]
    }

    public static func encodeByte(_ linear: Double) -> UInt8 {
        UInt8((toEncoded(linear) * 255).rounded())
    }
}

/// Running sum of linear colors with an explicit photo count.
///
/// Groups keep sums rather than averages so that combining groups always
/// weights every source photo equally.
public struct ColorSum: Codable, Hashable, Sendable {
    public var r: Double = 0
    public var g: Double = 0
    public var b: Double = 0
    public var count: Int = 0

    public init() {}

    public init(_ color: LinearRGB) {
        add(color)
    }

    public mutating func add(_ color: LinearRGB) {
        r += color.r
        g += color.g
        b += color.b
        count += 1
    }

    public mutating func add(_ other: ColorSum) {
        r += other.r
        g += other.g
        b += other.b
        count += other.count
    }

    /// Equal-weight mean of every photo in the sum, or nil when empty.
    public var average: LinearRGB? {
        guard count > 0 else { return nil }
        let n = Double(count)
        return LinearRGB(r: r / n, g: g / n, b: b / n)
    }
}

/// Averages a small color sample. The sample must already be rendered into
/// gamma-encoded sRGB with correct orientation (the platform layer does that).
public enum ColorAverager {
    /// - Parameters:
    ///   - pixels: Interleaved 8-bit pixels whose first three channels are R, G, B.
    ///   - bytesPerPixel: 3 for RGB, 4 for RGBX/RGBA (alpha is ignored; flatten first).
    public static func averageLinear(
        pixels: UnsafeBufferPointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        bytesPerPixel: Int = 4
    ) -> LinearRGB {
        precondition(width > 0 && height > 0, "Empty sample")
        precondition(bytesPerPixel >= 3)
        var r = 0.0, g = 0.0, b = 0.0
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                let i = row + x * bytesPerPixel
                r += SRGB.linear(fromByte: pixels[i])
                g += SRGB.linear(fromByte: pixels[i + 1])
                b += SRGB.linear(fromByte: pixels[i + 2])
            }
        }
        let n = Double(width * height)
        return LinearRGB(r: r / n, g: g / n, b: b / n)
    }
}
