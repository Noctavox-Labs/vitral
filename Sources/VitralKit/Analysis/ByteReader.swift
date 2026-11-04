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
}
