import CZlib
import Foundation

public enum PNGWriterError: Error, Sendable {
    case zlib(Int32)
    case wrongRowLength(expected: Int, got: Int)
    case wrongRowCount(expected: Int, got: Int)
}

/// Streams an opaque 8-bit RGB PNG to disk row by row.
///
/// Embeds an sRGB chunk and pHYs resolution (default 300 PPI) and nothing else:
/// no EXIF, location, or camera metadata. Rows use the PNG "Up" filter, which
/// turns repeated barcode rows into zeros that deflate compresses to almost nothing.
public final class StreamingPNGWriter {
    public let width: Int
    public let height: Int

    private let handle: FileHandle
    private var stream = z_stream()
    private let outCapacity = 256 * 1024
    private let outBuffer: UnsafeMutablePointer<UInt8>
    private var previousRow: [UInt8]
    private var filtered: [UInt8]
    private var rowsWritten = 0
    private var streamReady = false
    private var finished = false
    private var closed = false

    public init(url: URL, width: Int, height: Int, pixelsPerInch: Int = PrintSize.pixelsPerInch, compressionLevel: Int32 = 6) throws {
        precondition(width > 0 && height > 0)
        self.width = width
        self.height = height
        previousRow = [UInt8](repeating: 0, count: width * 3)
        filtered = [UInt8](repeating: 0, count: width * 3 + 1)
        outBuffer = .allocate(capacity: outCapacity)

        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)

        let status = deflateInit_(&stream, compressionLevel, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw PNGWriterError.zlib(status) }
        streamReady = true
        stream.next_out = outBuffer
        stream.avail_out = uInt(outCapacity)

        try handle.write(contentsOf: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))

        var ihdr = Data()
        ihdr.appendBigEndian(UInt32(width))
        ihdr.appendBigEndian(UInt32(height))
        ihdr.append(contentsOf: [8, 2, 0, 0, 0]) // 8-bit, truecolor RGB, deflate, adaptive filtering, no interlace
        try writeChunk("IHDR", ihdr)

        try writeChunk("sRGB", Data([0])) // perceptual rendering intent

        let pixelsPerMeter = UInt32((Double(pixelsPerInch) / 0.0254).rounded(.down))
        var phys = Data()
        phys.appendBigEndian(pixelsPerMeter)
        phys.appendBigEndian(pixelsPerMeter)
        phys.append(1) // unit: meter
        try writeChunk("pHYs", phys)
    }

    deinit {
        if streamReady && !finished { deflateEnd(&stream) }
        outBuffer.deallocate()
        if !closed { try? handle.close() }
    }

    /// Appends one row of `width * 3` RGB bytes.
    public func append(row: UnsafeBufferPointer<UInt8>) throws {
        guard row.count == width * 3 else { throw PNGWriterError.wrongRowLength(expected: width * 3, got: row.count) }
        filtered[0] = 2 // Up
        for i in 0..<row.count {
            filtered[i + 1] = row[i] &- previousRow[i]
            previousRow[i] = row[i]
        }
        try filtered.withUnsafeMutableBufferPointer { buffer in
            stream.next_in = buffer.baseAddress
            stream.avail_in = uInt(buffer.count)
            while stream.avail_in > 0 {
                try deflateStep(flush: Z_NO_FLUSH)
            }
            stream.next_in = nil
        }
        rowsWritten += 1
    }

    public func finish() throws {
        guard !finished else { return }
        guard rowsWritten == height else { throw PNGWriterError.wrongRowCount(expected: height, got: rowsWritten) }
        var status: Int32 = Z_OK
        repeat {
            status = deflate(&stream, Z_FINISH)
            guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else { throw PNGWriterError.zlib(status) }
            if stream.avail_out == 0 || status == Z_STREAM_END { try flushOutput() }
        } while status != Z_STREAM_END
        deflateEnd(&stream)
        finished = true
        try writeChunk("IEND", Data())
        try handle.synchronize()
        closed = true
        try handle.close()
    }

    private func deflateStep(flush: Int32) throws {
        let status = deflate(&stream, flush)
        guard status == Z_OK || status == Z_BUF_ERROR else { throw PNGWriterError.zlib(status) }
        if stream.avail_out == 0 { try flushOutput() }
    }

    private func flushOutput() throws {
        let produced = outCapacity - Int(stream.avail_out)
        if produced > 0 {
            try writeChunk("IDAT", Data(bytes: outBuffer, count: produced))
        }
        stream.next_out = outBuffer
        stream.avail_out = uInt(outCapacity)
    }

    private func writeChunk(_ type: String, _ data: Data) throws {
        var chunk = Data()
        chunk.appendBigEndian(UInt32(data.count))
        let typeAndData = Data(type.utf8) + data
        chunk.append(typeAndData)
        let crc = typeAndData.withUnsafeBytes { raw -> UInt32 in
            let bytes = raw.bindMemory(to: Bytef.self)
            return UInt32(truncatingIfNeeded: crc32(0, bytes.baseAddress, uInt(bytes.count)))
        }
        chunk.appendBigEndian(crc)
        try handle.write(contentsOf: chunk)
    }
}

extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }
}

extension ScanlineRenderer {
    /// Streams the full poster to a PNG file with bounded memory.
    public func writePNG(to url: URL, pixelsPerInch: Int = PrintSize.pixelsPerInch, progress: ((Double) -> Void)? = nil) throws {
        let writer = try StreamingPNGWriter(url: url, width: width, height: height, pixelsPerInch: pixelsPerInch)
        let step = max(1, height / 100)
        try renderRows { y, row in
            try writer.append(row: row)
            if y % step == 0 { progress?(Double(y) / Double(height)) }
        }
        try writer.finish()
        progress?(1)
    }
}
