import Foundation

/// Product details from a Windows executable's `VERSIONINFO` resource
/// (what Windows shows under Properties → Details).
public struct VersionInfo: Codable, Sendable, Equatable {
    public var productName: String?
    public var companyName: String?
    public var fileDescription: String?
    public var productVersion: String?
    public var fileVersion: String?
    public var originalFilename: String?

    public init(
        productName: String? = nil, companyName: String? = nil, fileDescription: String? = nil,
        productVersion: String? = nil, fileVersion: String? = nil, originalFilename: String? = nil
    ) {
        self.productName = productName
        self.companyName = companyName
        self.fileDescription = fileDescription
        self.productVersion = productVersion
        self.fileVersion = fileVersion
        self.originalFilename = originalFilename
    }

    var isEmpty: Bool {
        [productName, companyName, fileDescription, productVersion, fileVersion, originalFilename]
            .allSatisfy { $0 == nil }
    }
}

/// Name of a resource: Windows resources are identified by a number or by a string.
enum ResourceName: Hashable {
    case id(UInt32)
    case name(String)
}

/// A parsed PE (Portable Executable) image: sections, data directories and the
/// structures Vitral reads from them. Reads only; it never executes anything.
struct PEImage {
    struct Section {
        let name: String
        let virtualAddress: UInt32
        let virtualSize: UInt32
        let rawOffset: UInt32
        let rawSize: UInt32
    }

    struct Directory {
        let rva: UInt32
        let size: UInt32
    }

    /// Indexes into the optional header's data directory table.
    enum DirectoryIndex: Int {
        case exports = 0
        case imports = 1
        case resources = 2
        case delayImports = 13
        case clr = 14
    }

    /// Standard resource types.
    enum ResourceType: UInt32 {
        case icon = 3
        case groupIcon = 14
        case version = 16
    }

    let reader: ByteReader
    let format: ExecutableInfo.Format
    let machine: UInt16
    let characteristics: UInt16
    let subsystem: UInt16?
    let sections: [Section]
    let directories: [Directory]

    private static let pe32Magic: UInt16 = 0x010B
    private static let pe32PlusMagic: UInt16 = 0x020B

    /// `header` is the offset of the `PE\0\0` signature (the DOS header's `e_lfanew`).
    init?(reader r: ByteReader, header: Int) {
        let coff = header + 4
        guard let machine = r.u16(coff),
              let sectionCount = r.u16(coff + 2),
              let optionalSize = r.u16(coff + 16),
              let characteristics = r.u16(coff + 18) else { return nil }

        let optional = coff + 20
        let directoryCountOffset: Int
        switch r.u16(optional) {
        case Self.pe32Magic:
            format = .pe32
            directoryCountOffset = 92
        case Self.pe32PlusMagic:
            format = .pe32Plus
            directoryCountOffset = 108
        default:
            return nil
        }

        var directories: [Directory] = []
        let directoryTable = optional + directoryCountOffset + 4
        if let declared = r.u32(optional + directoryCountOffset) {
            let fits = max(0, (Int(optionalSize) - directoryCountOffset - 4) / 8)
            for index in 0 ..< min(Int(declared), fits, 16) {
                guard let rva = r.u32(directoryTable + index * 8),
                      let size = r.u32(directoryTable + index * 8 + 4) else { break }
                directories.append(Directory(rva: rva, size: size))
            }
        }

        var sections: [Section] = []
        let table = optional + Int(optionalSize)
        for index in 0 ..< min(Int(sectionCount), 96) {
            let entry = table + index * 40
            guard let raw = r.bytes(entry, 8),
                  let virtualSize = r.u32(entry + 8),
                  let virtualAddress = r.u32(entry + 12),
                  let rawSize = r.u32(entry + 16),
                  let rawOffset = r.u32(entry + 20) else { break }
            sections.append(Section(
                name: String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self),
                virtualAddress: virtualAddress,
                virtualSize: virtualSize,
                rawOffset: rawOffset,
                rawSize: rawSize
            ))
        }

        self.reader = r
        self.machine = machine
        self.characteristics = characteristics
        // `Subsystem` sits at offset 68 of the optional header in both PE32 and PE32+.
        self.subsystem = r.u16(optional + 68)
        self.sections = sections
        self.directories = directories
    }

    func directory(_ index: DirectoryIndex) -> Directory? {
        guard index.rawValue < directories.count else { return nil }
        let directory = directories[index.rawValue]
        return directory.rva == 0 || directory.size == 0 ? nil : directory
    }

    /// File offset of a relative virtual address, or `nil` if it is not backed by the file.
    func offset(ofRVA rva: UInt32) -> Int? {
        for section in sections {
            let span = max(section.virtualSize, section.rawSize)
            guard rva >= section.virtualAddress, rva - section.virtualAddress < span else { continue }
            let delta = rva - section.virtualAddress
            guard delta < section.rawSize else { return nil }
            let offset = Int(section.rawOffset) + Int(delta)
            return offset < reader.count ? offset : nil
        }
        // Before the first section the image maps the headers one to one.
        let firstSection = sections.map(\.virtualAddress).min() ?? 0
        return rva < firstSection && Int(rva) < reader.count ? Int(rva) : nil
    }

    // MARK: Imports

    /// A DLL the image imports and the functions it takes from it.
    struct ImportedDLL: Equatable {
        /// Lower-cased, such as "user32.dll".
        let name: String
        /// Functions imported by name (the few imported by number are left out).
        let functions: [String]
        /// Loaded the first time one of its functions is called, not when the program starts.
        let delayLoaded: Bool
    }

    /// Lower-cased names of the DLLs this image loads (normal and delay-loaded imports).
    func importedDLLs() -> [String] {
        Set(importTable().map(\.name)).sorted()
    }

    /// The import tables: the DLLs loaded at start, then the delay-loaded ones.
    func importTable() -> [ImportedDLL] {
        var found: [ImportedDLL] = []

        if let imports = directory(.imports), var entry = offset(ofRVA: imports.rva) {
            for _ in 0 ..< 1024 {
                guard let lookup = reader.u32(entry),
                      let bound = reader.u32(entry + 4),
                      let nameRVA = reader.u32(entry + 12),
                      let thunks = reader.u32(entry + 16) else { break }
                if lookup == 0, nameRVA == 0, thunks == 0 { break }
                if let name = dllName(atRVA: nameRVA) {
                    // Without a lookup table the names are in the address table, unless the
                    // linker already replaced them with addresses ("bound" imports).
                    let table = lookup != 0 ? lookup : (bound == 0 ? thunks : 0)
                    found.append(ImportedDLL(name: name, functions: functionNames(atRVA: table), delayLoaded: false))
                }
                entry += 20
            }
        }

        if let delayed = directory(.delayImports), var entry = offset(ofRVA: delayed.rva) {
            for _ in 0 ..< 1024 {
                guard let attributes = reader.u32(entry),
                      let nameRVA = reader.u32(entry + 4), nameRVA != 0 else { break }
                if let name = dllName(atRVA: nameRVA) {
                    // Bit 0 says the table holds relative addresses; Visual C++ 6 wrote absolute ones.
                    let names = attributes & 1 != 0 ? reader.u32(entry + 16).map(functionNames(atRVA:)) ?? [] : []
                    found.append(ImportedDLL(name: name, functions: names, delayLoaded: true))
                }
                entry += 32
            }
        }
        return found
    }

    /// Names in an import lookup table: entries of 4 bytes (PE32) or 8 (PE32+) up to a zero one.
    private func functionNames(atRVA rva: UInt32) -> [String] {
        guard rva != 0, var entry = offset(ofRVA: rva) else { return [] }
        let wide = format == .pe32Plus
        var names: [String] = []
        for _ in 0 ..< 65536 {
            guard let value = wide ? reader.u64(entry) : reader.u32(entry).map(UInt64.init), value != 0 else { break }
            entry += wide ? 8 : 4
            let byNumber = wide ? value >> 63 == 1 : value & 0x8000_0000 != 0
            // A name entry is a 2-byte hint followed by the name.
            guard !byNumber, let at = offset(ofRVA: UInt32(truncatingIfNeeded: value & 0x7FFF_FFFF)),
                  let name = symbolName(at + 2) else { continue }
            names.append(name)
        }
        return names
    }

    /// Names this image exports, forwarded ones included (functions and data).
    func exportedNames() -> Set<String> {
        guard let exports = directory(.exports), let table = offset(ofRVA: exports.rva),
              let count = reader.u32(table + 24), let namesRVA = reader.u32(table + 32),
              let names = offset(ofRVA: namesRVA) else { return [] }
        var found = Set<String>()
        for index in 0 ..< min(Int(count), 65536) {
            guard let rva = reader.u32(names + 4 * index), let at = offset(ofRVA: rva),
                  let name = symbolName(at) else { continue }
            found.insert(name)
        }
        return found
    }

    private func dllName(atRVA rva: UInt32) -> String? {
        guard let offset = offset(ofRVA: rva), let name = printable(offset, limit: 128) else { return nil }
        return name.lowercased()
    }

    /// Function names can be long (decorated C++ names).
    private func symbolName(_ offset: Int) -> String? { printable(offset, limit: 1024) }

    private func printable(_ offset: Int, limit: Int) -> String? {
        guard let text = reader.cString(offset, limit: limit), !text.isEmpty,
              text.utf8.allSatisfy({ (0x20 ..< 0x7F).contains($0) }) else { return nil }
        return text
    }

    // MARK: .NET

    /// `true` when the image has a CLR header, that is, it is a .NET assembly.
    var isDotNet: Bool { directory(.clr) != nil }

    /// Runtime version the assembly was built for, from its metadata root
    /// (for example "v4.0.30319" for .NET Framework 4.x or "v2.0.50727" for 2.0–3.5).
    func dotNetRuntimeVersion() -> String? {
        guard let clr = directory(.clr), let header = offset(ofRVA: clr.rva),
              let metadataRVA = reader.u32(header + 8),
              let root = offset(ofRVA: metadataRVA),
              reader.u32(root) == 0x424A_5342,                    // "BSJB"
              let length = reader.u32(root + 12), length > 0, length <= 255,
              let raw = reader.bytes(root + 16, Int(length)) else { return nil }
        let text = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    // MARK: Resources

    /// Resources of one type: each entry's name and the data of its first language.
    func resources(ofType type: UInt32) -> [(name: ResourceName, data: Data)] {
        guard let directory = directory(.resources), let base = offset(ofRVA: directory.rva) else { return [] }

        func entries(at relative: UInt32) -> [(name: ResourceName, field: UInt32)] {
            let table = base + Int(relative)
            guard let named = reader.u16(table + 12), let numbered = reader.u16(table + 14) else { return [] }
            var result: [(ResourceName, UInt32)] = []
            for index in 0 ..< min(Int(named) + Int(numbered), 4096) {
                let entry = table + 16 + index * 8
                guard let nameField = reader.u32(entry), let field = reader.u32(entry + 4) else { break }
                let name: ResourceName
                if nameField & 0x8000_0000 != 0 {
                    let string = base + Int(nameField & 0x7FFF_FFFF)
                    let length = Int(reader.u16(string) ?? 0)
                    name = .name(reader.utf16(string + 2, maxUnits: length).text)
                } else {
                    name = .id(nameField)
                }
                result.append((name, field))
            }
            return result
        }

        func isDirectory(_ field: UInt32) -> Bool { field & 0x8000_0000 != 0 }
        func target(_ field: UInt32) -> UInt32 { field & 0x7FFF_FFFF }

        guard let typeEntry = entries(at: 0).first(where: { $0.name == .id(type) }),
              isDirectory(typeEntry.field) else { return [] }

        var result: [(ResourceName, Data)] = []
        for (name, field) in entries(at: target(typeEntry.field)) where isDirectory(field) {
            guard let language = entries(at: target(field)).first(where: { !isDirectory($0.field) }) else { continue }
            let leaf = base + Int(language.field)
            guard let rva = reader.u32(leaf), let size = reader.u32(leaf + 4),
                  let offset = offset(ofRVA: rva),
                  let data = reader.bytes(offset, Int(size)) else { continue }
            result.append((name, Data(data)))
        }
        return result
    }

    func versionInfo() -> VersionInfo? {
        guard let blob = resources(ofType: ResourceType.version.rawValue).first?.data else { return nil }
        return VersionInfoParser.parse(blob)
    }

    var hasIcon: Bool { !resources(ofType: ResourceType.groupIcon.rawValue).isEmpty }

    /// The program's icon as a Windows `.ico` file: the first icon group, which is the one
    /// Windows shows for the executable.
    func iconFile() -> Data? {
        guard let group = resources(ofType: ResourceType.groupIcon.rawValue).first?.data else { return nil }
        var images: [UInt32: Data] = [:]
        for (name, data) in resources(ofType: ResourceType.icon.rawValue) {
            if case .id(let id) = name { images[id] = data }
        }

        let g = ByteReader(data: group)
        guard g.u16(0) == 0, g.u16(2) == 1, let declared = g.u16(4) else { return nil }

        // GRPICONDIRENTRY is 14 bytes; the .ico entry is the same but ends with a 4-byte offset.
        var entries: [(header: Data, image: Data)] = []
        for index in 0 ..< Int(declared) {
            let entry = 6 + index * 14
            guard let header = g.bytes(entry, 12), let id = g.u16(entry + 12),
                  let image = images[UInt32(id)], !image.isEmpty else { continue }
            entries.append((Data(header.prefix(8)), image))
        }
        guard !entries.isEmpty else { return nil }

        var ico = Data([0, 0, 1, 0]) + Data(le16(UInt16(entries.count)))
        var imageOffset = 6 + entries.count * 16
        for entry in entries {
            ico += entry.header
            ico += Data(le32(UInt32(entry.image.count)))
            ico += Data(le32(UInt32(imageOffset)))
            imageOffset += entry.image.count
        }
        for entry in entries { ico += entry.image }
        return ico
    }

    private func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
    private func le32(_ value: UInt32) -> [UInt8] { (0 ..< 4).map { UInt8((value >> (8 * $0)) & 0xFF) } }
}

/// Reads the `VS_VERSIONINFO` tree of a version resource.
enum VersionInfoParser {
    private struct Node {
        let key: String
        let valueStart: Int
        let valueLength: Int
        let end: Int
        let children: [Node]
    }

    static func parse(_ blob: Data) -> VersionInfo? {
        let r = ByteReader(data: blob)
        guard let root = node(r, at: 0, limit: r.count, depth: 0), root.key == "VS_VERSION_INFO" else { return nil }

        var info = VersionInfo()
        for table in root.children.filter({ $0.key == "StringFileInfo" }).flatMap(\.children) {
            var strings: [String: String] = [:]
            for string in table.children {
                let maxUnits = max(0, (string.end - string.valueStart) / 2)
                let value = r.utf16(string.valueStart, maxUnits: maxUnits).text
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
                if !value.isEmpty { strings[string.key] = value }
            }
            guard !strings.isEmpty else { continue }
            info.productName = strings["ProductName"]
            info.companyName = strings["CompanyName"]
            info.fileDescription = strings["FileDescription"]
            info.productVersion = strings["ProductVersion"].map(normalizeVersion)
            info.fileVersion = strings["FileVersion"].map(normalizeVersion)
            info.originalFilename = strings["OriginalFilename"]
            break
        }

        // VS_FIXEDFILEINFO: signature, struct version, then file and product versions.
        if root.valueLength >= 52, r.u32(root.valueStart) == 0xFEEF_04BD {
            func version(_ at: Int) -> String? {
                guard let high = r.u32(root.valueStart + at), let low = r.u32(root.valueStart + at + 4),
                      high != 0 || low != 0 else { return nil }
                return "\(high >> 16).\(high & 0xFFFF).\(low >> 16).\(low & 0xFFFF)"
            }
            if info.fileVersion == nil { info.fileVersion = version(8) }
            if info.productVersion == nil { info.productVersion = version(16) }
        }
        return info.isEmpty ? nil : info
    }

    /// "28,0,0" → "28.0.0"; "5, 12, 4, 0" → "5.12.4.0".
    static func normalizeVersion(_ text: String) -> String {
        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count > 1, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return text }
        return parts.joined(separator: ".")
    }

    private static func align4(_ value: Int) -> Int { (value + 3) & ~3 }

    private static func node(_ r: ByteReader, at offset: Int, limit: Int, depth: Int) -> Node? {
        guard depth < 6,
              let length = r.u16(offset), length >= 6,
              let valueLength = r.u16(offset + 2),
              let type = r.u16(offset + 4) else { return nil }
        let end = min(offset + Int(length), limit)
        guard end > offset + 6 else { return nil }

        let key = r.utf16(offset + 6, maxUnits: (end - offset - 6) / 2)
        let valueStart = align4(offset + 6 + key.units * 2)
        // Text values (type 1) count UTF-16 units; binary values count bytes.
        let valueBytes = type == 1 ? Int(valueLength) * 2 : Int(valueLength)

        var children: [Node] = []
        var position = align4(valueStart + valueBytes)
        while position + 6 <= end, children.count < 256,
              let child = node(r, at: position, limit: end, depth: depth + 1) {
            children.append(child)
            position = align4(child.end)
        }
        return Node(key: key.text, valueStart: valueStart, valueLength: valueBytes, end: end, children: children)
    }
}
