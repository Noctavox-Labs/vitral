import Foundation

/// The little Vitral reads of macOS executables.
public enum MachO {
    /// The UUIDs the linker gave an executable, one per architecture. Signing does not change
    /// them, while it does rewrite the file: the launcher in an app is the same build as
    /// Vitral's when their UUIDs match, even if their bytes differ.
    public static func uuids(of url: URL) -> [UUID]? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        func u32(_ at: Int, bigEndian: Bool = false) -> Int? {
            guard at >= 0, at + 4 <= data.count else { return nil }
            let b = (0 ..< 4).map { Int(data[data.startIndex + at + $0]) }
            return bigEndian ? b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3] : b[3] << 24 | b[2] << 16 | b[1] << 8 | b[0]
        }
        func uuid(at start: Int) -> UUID? {
            // 64-bit Mach-O, little-endian: magic, cputype, subtype, filetype, ncmds, sizeofcmds…
            guard u32(start) == 0xFEED_FACF, let count = u32(start + 16) else { return nil }
            var offset = start + 32
            for _ in 0 ..< min(count, 4096) {
                guard let command = u32(offset), let size = u32(offset + 4), size >= 8 else { return nil }
                if command == 0x1B, offset + 24 <= data.count {  // LC_UUID
                    let raw = (0 ..< 16).map { data[data.startIndex + offset + 8 + $0] }
                    return UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
                                       raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]))
                }
                offset += size
            }
            return nil
        }
        // A universal file lists its architectures first (big-endian).
        if u32(0, bigEndian: true) == 0xCAFE_BABE, let count = u32(4, bigEndian: true), count < 32 {
            let found = (0 ..< count).compactMap { index in u32(8 + index * 20 + 8, bigEndian: true).flatMap(uuid(at:)) }
            return found.count == count ? found : nil
        }
        return uuid(at: 0).map { [$0] }
    }
}
