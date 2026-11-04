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
    /// Lower-cased names of the DLLs it loads, such as "d3d11.dll" or "mscoree.dll".
    public let imports: [String]
    /// Runtime version of a .NET assembly ("v4.0.30319"), `nil` for native programs.
    public let dotNetRuntime: String?
    public let version: VersionInfo?
    public let hasIcon: Bool

    public init(
        format: Format, machine: Machine? = nil, subsystem: Subsystem? = nil, isDLL: Bool = false,
        sectionNames: [String] = [], imports: [String] = [], dotNetRuntime: String? = nil,
        version: VersionInfo? = nil, hasIcon: Bool = false
    ) {
        self.format = format
        self.machine = machine
        self.subsystem = subsystem
        self.isDLL = isDLL
        self.sectionNames = sectionNames
        self.imports = imports
        self.dotNetRuntime = dotNetRuntime
        self.version = version
        self.hasIcon = hasIcon
    }

    /// 16, 32 or 64.
    public var bits: Int {
        switch format {
        case .dos, .windows16: 16
        case .pe32: 32
        case .pe32Plus: 64
        }
    }

    public var isDotNet: Bool { dotNetRuntime != nil }
}

/// Minimal reader for MZ / NE / PE files. It never executes anything.
public enum PortableExecutable {
    private static let mz: UInt16 = 0x5A4D          // "MZ"
    private static let pe: UInt32 = 0x0000_4550     // "PE\0\0"
    private static let ne: UInt16 = 0x454E          // "NE"

    /// Parses an executable. Pass the whole file (memory-mapped is fine): resources such as
    /// the icon and the version often sit near the end. Returns `nil` if `data` is not an
    /// `MZ` executable at all.
    public static func parse(_ data: Data) -> ExecutableInfo? {
        let r = ByteReader(data: data)
        guard r.u16(0) == mz else { return nil }

        let dos = ExecutableInfo(format: .dos)
        guard let rawOffset = r.u32(0x3C), rawOffset > 0, Int(rawOffset) + 4 <= r.count else { return dos }
        let header = Int(rawOffset)

        if r.u16(header) == ne {
            return ExecutableInfo(format: .windows16, machine: .x86, subsystem: .gui)
        }
        guard r.u32(header) == pe, let image = PEImage(reader: r, header: header) else { return dos }

        let subsystem: ExecutableInfo.Subsystem? = image.subsystem.map {
            switch $0 {
            case 2: .gui
            case 3: .console
            default: .other
            }
        }

        return ExecutableInfo(
            format: image.format,
            machine: machine(image.machine),
            subsystem: subsystem,
            isDLL: image.characteristics & 0x2000 != 0,
            sectionNames: image.sections.map(\.name),
            imports: image.importedDLLs(),
            dotNetRuntime: image.isDotNet ? (image.dotNetRuntimeVersion() ?? "?") : nil,
            version: image.versionInfo(),
            hasIcon: image.hasIcon
        )
    }

    /// The program's icon as a Windows `.ico` file, or `nil` if it has none.
    public static func icon(_ data: Data) -> Data? {
        let r = ByteReader(data: data)
        guard r.u16(0) == mz, let rawOffset = r.u32(0x3C), r.u32(Int(rawOffset)) == pe,
              let image = PEImage(reader: r, header: Int(rawOffset)) else { return nil }
        return image.iconFile()
    }

    /// Reads an executable from disk (memory-mapped, so large files are cheap).
    public static func parse(fileAt url: URL) -> ExecutableInfo? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return parse(data)
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
