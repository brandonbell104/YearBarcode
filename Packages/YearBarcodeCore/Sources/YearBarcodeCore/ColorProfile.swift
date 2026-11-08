import Foundation

/// How each stripe is painted.
public enum StripeStyle: String, Codable, CaseIterable, Sendable {
    /// One solid average color per stripe.
    case solid
    /// "Movie barcode" style: each photo is squeezed into the stripe, keeping its
    /// color changes along the stripe (sky at the top, ground at the bottom).
    case squeezed

    public var title: String {
        switch self {
        case .solid: return "Solid"
        case .squeezed: return "Squeezed"
        }
    }

    public var helpText: String {
        switch self {
        case .solid: return "Each stripe is the average color of its photos."
        case .squeezed: return "Each photo is squeezed into its stripe like a movie barcode, keeping its colors from top to bottom."
        }
    }
}

/// A photo squeezed to a single line: average colors along its height
/// (`rows`, top to bottom) and along its width (`columns`, left to right).
public enum ColorProfile {
    /// Samples per profile (the analysis sample is 64 × 64).
    public static let length = 64

    /// Averages each row and each column of a gamma-encoded sRGB sample in linear light.
    public static func compute(
        pixels: UnsafeBufferPointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        bytesPerPixel: Int = 4
    ) -> (rows: [RGB8], columns: [RGB8]) {
        var rowSums = [ColorSum](repeating: ColorSum(), count: height)
        var columnSums = [ColorSum](repeating: ColorSum(), count: width)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * bytesPerRow + x * bytesPerPixel
                let color = LinearRGB(
                    r: SRGB.linear(fromByte: pixels[i]),
                    g: SRGB.linear(fromByte: pixels[i + 1]),
                    b: SRGB.linear(fromByte: pixels[i + 2])
                )
                rowSums[y].add(color)
                columnSums[x].add(color)
            }
        }
        return (
            rowSums.map { $0.average?.rgb8 ?? .white },
            columnSums.map { $0.average?.rgb8 ?? .white }
        )
    }

    /// Color at fraction `t` (0...1) along a profile, linearly interpolated.
    public static func sample(_ profile: [RGB8], at t: Double) -> RGB8 {
        guard profile.count > 1 else { return profile.first ?? .white }
        let position = min(max(t * Double(profile.count) - 0.5, 0), Double(profile.count - 1))
        let lower = Int(position)
        let upper = min(lower + 1, profile.count - 1)
        let f = position - Double(lower)
        let a = profile[lower], b = profile[upper]
        func mix(_ x: UInt8, _ y: UInt8) -> UInt8 { UInt8((Double(x) + (Double(y) - Double(x)) * f).rounded()) }
        return RGB8(r: mix(a.r, b.r), g: mix(a.g, b.g), b: mix(a.b, b.b))
    }
}

/// Running per-sample sums of profiles in linear light, so groups average
/// with equal weight per photo (same rule as `ColorSum`).
public struct ProfileSum: Codable, Hashable, Sendable {
    public var r: [Double]
    public var g: [Double]
    public var b: [Double]
    public var count: Int

    public init(length: Int = ColorProfile.length) {
        r = Array(repeating: 0, count: length)
        g = r
        b = r
        count = 0
    }

    public init(_ profile: [RGB8]) {
        self.init(length: profile.count)
        add(profile)
    }

    public mutating func add(_ profile: [RGB8]) {
        guard profile.count == r.count else { return }
        for (i, color) in profile.enumerated() {
            r[i] += SRGB.linear(fromByte: color.r)
            g[i] += SRGB.linear(fromByte: color.g)
            b[i] += SRGB.linear(fromByte: color.b)
        }
        count += 1
    }

    public mutating func add(_ other: ProfileSum) {
        guard other.r.count == r.count else { return }
        for i in r.indices {
            r[i] += other.r[i]
            g[i] += other.g[i]
            b[i] += other.b[i]
        }
        count += other.count
    }

    public var average: [RGB8]? {
        guard count > 0 else { return nil }
        let n = Double(count)
        return r.indices.map { LinearRGB(r: r[$0] / n, g: g[$0] / n, b: b[$0] / n).rgb8 }
    }
}
