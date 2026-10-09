import Foundation

/// Compact, non-reversible description of a photo's color sample used to
/// detect copies. It is all that remains of the sample after analysis.
public struct ImageFingerprint: Codable, Hashable, Sendable {
    /// 64-bit difference hash of a 9×8 grayscale reduction.
    public var differenceHash: UInt64
    /// FNV-1a hash of the exact sample bytes; equal for byte-identical renditions.
    public var contentHash: UInt64

    public init(differenceHash: UInt64, contentHash: UInt64) {
        self.differenceHash = differenceHash
        self.contentHash = contentHash
    }

    /// - Parameter pixels: gamma-encoded sRGB sample, R,G,B in the first three channels.
    public static func compute(
        pixels: UnsafeBufferPointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        bytesPerPixel: Int = 4
    ) -> ImageFingerprint {
        // FNV-1a over the RGB channels only (padding bytes may vary).
        var content: UInt64 = 0xcbf2_9ce4_8422_2325
        for y in 0..<height {
            for x in 0..<width {
                let i = y * bytesPerRow + x * bytesPerPixel
                for c in 0..<3 {
                    content ^= UInt64(pixels[i + c])
                    content = content &* 0x0000_0100_0000_01b3
                }
            }
        }

        // Box-average into a 9 × 8 luma grid.
        let gridW = 9, gridH = 8
        var grid = [Double](repeating: 0, count: gridW * gridH)
        for gy in 0..<gridH {
            let y0 = gy * height / gridH, y1 = max(y0 + 1, (gy + 1) * height / gridH)
            for gx in 0..<gridW {
                let x0 = gx * width / gridW, x1 = max(x0 + 1, (gx + 1) * width / gridW)
                var sum = 0.0
                for y in y0..<min(y1, height) {
                    for x in x0..<min(x1, width) {
                        let i = y * bytesPerRow + x * bytesPerPixel
                        sum += 0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])
                    }
                }
                grid[gy * gridW + gx] = sum / Double((min(y1, height) - y0) * (min(x1, width) - x0))
            }
        }
        var hash: UInt64 = 0
        for gy in 0..<gridH {
            for gx in 0..<(gridW - 1) {
                hash <<= 1
                if grid[gy * gridW + gx] > grid[gy * gridW + gx + 1] { hash |= 1 }
            }
        }
        return ImageFingerprint(differenceHash: hash, contentHash: content)
    }
}

public struct DuplicateCandidate: Hashable, Sendable {
    public var assetID: String
    public var captureDate: Date
    public var color: LinearRGB
    public var fingerprint: ImageFingerprint

    public init(assetID: String, captureDate: Date, color: LinearRGB, fingerprint: ImageFingerprint) {
        self.assetID = assetID
        self.captureDate = captureDate
        self.color = color
        self.fingerprint = fingerprint
    }
}

public struct DuplicateResolution: Sendable, Equatable {
    /// Group ID (the representative's asset ID) for every asset that belongs to a duplicate group.
    public var groupOf: [String: String]
    /// Non-representative members to exclude.
    public var suppressed: Set<String>
}

/// Suppresses exact or confidently near-identical copies, keeping the
/// earliest (then lowest asset ID) as the deterministic representative.
/// Thresholds are deliberately strict so distinct similar shots survive.
public enum DuplicateResolver {
    public static let maxHashDistance = 2
    public static let maxSecondsApart: TimeInterval = 120
    public static let maxColorDelta = 0.02

    public static func resolve(_ candidates: [DuplicateCandidate]) -> DuplicateResolution {
        let items = candidates.sorted {
            $0.captureDate != $1.captureDate ? $0.captureDate < $1.captureDate : $0.assetID < $1.assetID
        }
        var parent = Array(items.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            // Lower index is chronologically earlier and becomes the root.
            if ra < rb { parent[rb] = ra } else if rb < ra { parent[ra] = rb }
        }

        // Exact copies anywhere in the year.
        var firstByContent: [UInt64: Int] = [:]
        for (i, item) in items.enumerated() {
            if let first = firstByContent[item.fingerprint.contentHash] {
                union(first, i)
            } else {
                firstByContent[item.fingerprint.contentHash] = i
            }
        }

        // Near-identical copies taken close together.
        for i in items.indices {
            var j = i + 1
            while j < items.count, items[j].captureDate.timeIntervalSince(items[i].captureDate) <= maxSecondsApart {
                if isNearIdentical(items[i], items[j]) { union(i, j) }
                j += 1
            }
        }

        var members: [Int: [Int]] = [:]
        for i in items.indices { members[find(i), default: []].append(i) }
        var groupOf: [String: String] = [:]
        var suppressed = Set<String>()
        for (root, group) in members where group.count > 1 {
            let representative = items[root].assetID
            for i in group {
                groupOf[items[i].assetID] = representative
                if i != root { suppressed.insert(items[i].assetID) }
            }
        }
        return DuplicateResolution(groupOf: groupOf, suppressed: suppressed)
    }

    static func isNearIdentical(_ a: DuplicateCandidate, _ b: DuplicateCandidate) -> Bool {
        let distance = (a.fingerprint.differenceHash ^ b.fingerprint.differenceHash).nonzeroBitCount
        guard distance <= maxHashDistance else { return false }
        let delta = max(abs(a.color.r - b.color.r), abs(a.color.g - b.color.g), abs(a.color.b - b.color.b))
        return delta <= maxColorDelta
    }
}
