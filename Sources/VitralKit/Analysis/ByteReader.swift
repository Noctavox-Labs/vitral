import Foundation

/// Bounds-checked little-endian reads over a `Data` buffer. Every read returns `nil`
/// instead of trapping when the file is truncated or malformed.
struct ByteReader {
    let data: Data

    var count: Int { data.count }

    func u8(_ offset: Int) -> UInt8? {
        guard offset >= 0, offset < data.count else { return nil }
        return data[data.startIndex + offset]
    }

    func u16(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        let i = data.startIndex + offset
        return UInt16(data[i]) | UInt16(data[i + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32? {
        guard let low = u16(offset), let high = u16(offset + 2) else { return nil }
        return UInt32(low) | UInt32(high) << 16
    }

    func bytes(_ offset: Int, _ length: Int) -> Data? {
        guard offset >= 0, length >= 0, offset + length <= data.count else { return nil }
        let start = data.startIndex + offset
        return data[start ..< start + length]
    }

    /// Byte offset (relative to the start of `data`) of the first occurrence of `pattern`.
    func firstOffset(of pattern: [UInt8]) -> Int? {
        guard !pattern.isEmpty, let range = data.range(of: Data(pattern)) else { return nil }
        return range.lowerBound - data.startIndex
    }

    func contains(_ pattern: [UInt8]) -> Bool { firstOffset(of: pattern) != nil }

    func contains(_ ascii: String) -> Bool { contains(Array(ascii.utf8)) }

    /// NUL-terminated ASCII text starting at `offset` (at most `limit` bytes).
    func cString(_ offset: Int, limit: Int = 256) -> String? {
        var bytes: [UInt8] = []
        var position = offset
        while bytes.count < limit, let byte = u8(position) {
            if byte == 0 { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
            position += 1
        }
        return nil
    }

    /// UTF-16LE text starting at `offset`, up to a NUL or `maxUnits` code units.
    /// Returns the text and how many units were consumed, counting the NUL if present.
    func utf16(_ offset: Int, maxUnits: Int) -> (text: String, units: Int) {
        var units: [UInt16] = []
        var position = offset
        while units.count < maxUnits, let unit = u16(position) {
            if unit == 0 { return (String(decoding: units, as: UTF16.self), units.count + 1) }
            units.append(unit)
            position += 2
        }
        return (String(decoding: units, as: UTF16.self), units.count)
    }
}
