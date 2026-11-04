import Foundation

/// What the headers of a Windows executable (`MZ` file) say about it.
public struct ExecutableInfo: Codable, Sendable, Equatable {
    public enum Format: String, Codable, Sendable {
        /// Plain MS-DOS program.
        case dos
        /// 16-bit Windows (NE). Wine on macOS cannot run these.
        case windows16
        /// 32-bit Windows (PE32).
        case pe32
        /// 64-bit Windows (PE32+).
        case pe32Plus
    }

    public enum Machine: String, Codable, Sendable {
        case x86, x64, arm64, arm, other
    }

    public enum Subsystem: String, Codable, Sendable {
        case gui, console, other
    }

    public let format: Format
    public let machine: Machine?
    public let subsystem: Subsystem?
    public let isDLL: Bool
    public let sectionNames: [String]

    /// 16, 32 or 64.
    public var bits: Int {
        switch format {
        case .dos, .windows16: 16
        case .pe32: 32
        case .pe32Plus: 64
        }
    }
}

/// Minimal reader for MZ / NE / PE headers. It never executes anything.
public enum PortableExecutable {
    private static let mz: UInt16 = 0x5A4D          // "MZ"
    private static let pe: UInt32 = 0x0000_4550     // "PE\0\0"
    private static let ne: UInt16 = 0x454E          // "NE"
    private static let pe32Magic: UInt16 = 0x010B
    private static let pe32PlusMagic: UInt16 = 0x020B

    /// Parses the headers in `data` (the start of the file is enough; 1 MB is plenty).
    /// Returns `nil` if `data` is not an `MZ` executable at all.
    public static func parse(_ data: Data) -> ExecutableInfo? {
        let r = ByteReader(data: data)
        guard r.u16(0) == mz else { return nil }

        let dos = ExecutableInfo(format: .dos, machine: nil, subsystem: nil, isDLL: false, sectionNames: [])
        guard let rawOffset = r.u32(0x3C), rawOffset > 0, Int(rawOffset) + 4 <= r.count else { return dos }
        let header = Int(rawOffset)

        if r.u16(header) == ne {
            return ExecutableInfo(format: .windows16, machine: .x86, subsystem: .gui, isDLL: false, sectionNames: [])
        }
        guard r.u32(header) == pe else { return dos }

        // COFF file header (20 bytes) right after the "PE\0\0" signature.
        let coff = header + 4
        guard let machineValue = r.u16(coff),
              let sectionCount = r.u16(coff + 2),
              let optionalSize = r.u16(coff + 16),
              let characteristics = r.u16(coff + 18) else { return dos }

        let optional = coff + 20
        let format: ExecutableInfo.Format
        switch r.u16(optional) {
        case pe32Magic: format = .pe32
        case pe32PlusMagic: format = .pe32Plus
        default: return dos
        }

        // `Subsystem` sits at offset 68 of the optional header in both PE32 and PE32+.
        let subsystem: ExecutableInfo.Subsystem? = r.u16(optional + 68).map {
            switch $0 {
            case 2: .gui
            case 3: .console
            default: .other
            }
        }

        var sections: [String] = []
        let table = optional + Int(optionalSize)
        for index in 0 ..< min(Int(sectionCount), 96) {
            guard let raw = r.bytes(table + index * 40, 8) else { break }
            let name = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            sections.append(name)
        }

        return ExecutableInfo(
            format: format,
            machine: machine(machineValue),
            subsystem: subsystem,
            isDLL: characteristics & 0x2000 != 0,
            sectionNames: sections
        )
    }

    private static func machine(_ value: UInt16) -> ExecutableInfo.Machine {
        switch value {
        case 0x014C: .x86
        case 0x8664: .x64
        case 0xAA64: .arm64
        case 0x01C0, 0x01C2, 0x01C4: .arm
        default: .other
        }
    }
}
