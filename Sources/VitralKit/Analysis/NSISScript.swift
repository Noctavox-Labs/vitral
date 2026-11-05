import Compression
import Foundation

/// Tool that made an installer, when Vitral recognizes it.
public enum InstallerBuilder: String, Codable, Sendable {
    /// electron-builder (Electron apps): NSIS with the app in `$PLUGINSDIR\app-64.7z`.
    case electronBuilder
}

/// The script of an NSIS installer. NSIS keeps every command and text of the installer in one
/// header block right after its stub: reading it tells what the installer will do, without
/// running it.
public enum NSISScript {
    /// What Vitral reads in the script.
    public struct Facts: Sendable, Equatable {
        public let builder: InstallerBuilder?
        /// The script runs `powershell.exe`.
        public let runsPowerShell: Bool
        /// Bits of the program it installs, when the script shows it (electron-builder packs
        /// `app-64.7z` and/or `app-32.7z`).
        public var programBits: Int? = nil
    }

    /// `siginfo` and `nsinst` of NSIS's first header.
    static let signature: [UInt8] = [0xEF, 0xBE, 0xAD, 0xDE] + Array("NullsoftInst".utf8)
    /// NSIS looks for its first header at multiples of 512 bytes.
    static let alignment = 512
    /// Bigger headers are not real installers (electron-builder's is about 250 KB).
    static let maxHeader = 64 * 1024 * 1024

    /// Reads the script of an NSIS installer, if it can be read.
    public static func facts(in data: Data, scanLimit: Int) -> Facts? {
        header(in: data, scanLimit: scanLimit).map(facts(header:))
    }

    /// The header, decompressed. Only when it is stored plainly or with zlib outside a solid
    /// block, as electron-builder builds it; `nil` for LZMA, bzip2 or solid compression.
    static func header(in data: Data, scanLimit: Int) -> Data? {
        let r = ByteReader(data: data)
        let limit = min(r.count, scanLimit)
        var offset = 0
        while offset + 32 <= limit {
            if let bytes = r.bytes(offset + 4, signature.count), bytes.elementsEqual(signature) {
                return header(r, firstHeader: offset)
            }
            offset += alignment
        }
        return nil
    }

    /// First header: flags, signature (16 bytes), header length, data length. The header block
    /// follows it: a 32-bit size (top bit set when compressed) and the bytes.
    private static func header(_ r: ByteReader, firstHeader offset: Int) -> Data? {
        guard let length = r.u32(offset + 20).map(Int.init), length > 0, length <= maxHeader,
              let block = r.u32(offset + 28) else { return nil }
        let size = Int(block & 0x7FFF_FFFF)
        guard size > 0, let body = r.bytes(offset + 32, size) else { return nil }
        if block & 0x8000_0000 == 0 {
            return size == length ? Data(body) : nil
        }
        return inflate(body, expected: length)
    }

    /// Raw DEFLATE (NSIS's "zlib") into exactly `expected` bytes.
    static func inflate(_ input: Data, expected: Int) -> Data? {
        guard !input.isEmpty, expected > 0 else { return nil }
        var output = Data(count: expected)
        let written = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { source in
                compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, expected,
                                          source.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        return written == expected ? output : nil
    }

    static func facts(header: Data) -> Facts {
        // Unicode installers keep their texts in UTF-16, older ones in single bytes: look for both,
        // ignoring ASCII case.
        let lower = Data(header.map { (65...90).contains($0) ? $0 + 32 : $0 })
        func mentions(_ text: String) -> Bool {
            let ascii = Array(text.lowercased().utf8)
            let utf16 = ascii.flatMap { byte -> [UInt8] in [byte, 0] }
            return lower.range(of: Data(utf16)) != nil || lower.range(of: Data(ascii)) != nil
        }
        let has64 = mentions("\\app-64.7z"), has32 = mentions("\\app-32.7z")
        let packedApp = has64 || has32 || mentions("\\app-arm64.7z")
        let electronBuilder = packedApp && mentions("nsis7z")
        // With both, the installer picks by Windows' bits; Wine is 64-bit Windows.
        let bits: Int? = electronBuilder ? (has64 ? 64 : has32 ? 32 : nil) : nil
        return Facts(builder: electronBuilder ? .electronBuilder : nil,
                     runsPowerShell: mentions("\\powershell.exe"), programBits: bits)
    }
}
