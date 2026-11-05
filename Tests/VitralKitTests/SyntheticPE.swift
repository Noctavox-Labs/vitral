import Foundation

/// Builds small but well-formed Windows executables in memory, with imports, resources
/// (version, icons) and a .NET header, so tests never need real `.exe` files.
struct SyntheticPE {
    var machine: UInt16 = 0x014C
    var is64Bit = false
    var subsystem: UInt16 = 2
    var isDLL = false
    var imports: [String] = []
    var delayImports: [String] = []
    /// Functions taken from each DLL of `imports` and `delayImports`, by DLL name.
    var functions: [String: [String]] = [:]
    /// Function names it exports (as a DLL).
    var exports: [String] = []
    /// `VERSIONINFO` strings ("ProductName", "CompanyName", …).
    var versionStrings: [String: String] = [:]
    /// Binary file version in `VS_FIXEDFILEINFO`, such as (5, 12, 4, 0).
    var fixedVersion: (UInt16, UInt16, UInt16, UInt16)?
    /// Image data for each icon (PNG or BMP). They become one icon group.
    var icons: [(side: UInt8, data: [UInt8])] = []
    var dotNetRuntime: String?

    static let sectionRVA: UInt32 = 0x1000
    static let sectionFileOffset = 0x400

    func build() -> Data {
        var section: [UInt8] = []
        var directories = [(rva: UInt32, size: UInt32)](repeating: (0, 0), count: 16)

        func place(_ bytes: [UInt8]) -> UInt32 {
            while section.count % 4 != 0 { section.append(0) }
            let rva = Self.sectionRVA + UInt32(section.count)
            section += bytes
            return rva
        }

        // Lookup table of a DLL: one entry per function (4 bytes, or 8 in 64 bits) pointing to a
        // 2-byte hint and the name, then a zero entry.
        func lookupTable(_ dll: String) -> UInt32 {
            let names = (functions[dll] ?? []).map { place(le16(0) + Array($0.utf8) + [0]) }
            var table: [UInt8] = []
            for name in names { table += le32(name) + (is64Bit ? le32(0) : []) }
            return place(table + [UInt8](repeating: 0, count: is64Bit ? 8 : 4))
        }

        if !imports.isEmpty {
            var table: [UInt8] = []
            for dll in imports {
                let name = place(Array(dll.utf8) + [0]), lookup = lookupTable(dll)
                table += le32(lookup) + le32(0) + le32(0) + le32(name) + le32(lookup)
            }
            table += [UInt8](repeating: 0, count: 20)
            directories[1] = (place(table), UInt32(table.count))
        }

        if !delayImports.isEmpty {
            var table: [UInt8] = []
            for dll in delayImports {
                let name = place(Array(dll.utf8) + [0]), lookup = lookupTable(dll)
                // Attributes 1 (relative addresses), name, module handle, address table, name table…
                table += le32(1) + le32(name) + le32(0) + le32(lookup) + le32(lookup) + [UInt8](repeating: 0, count: 12)
            }
            table += [UInt8](repeating: 0, count: 32)
            directories[13] = (place(table), UInt32(table.count))
        }

        if !exports.isEmpty {
            let names = exports.map { place(Array($0.utf8) + [0]) }
            let addresses = place(exports.flatMap { _ in le32(Self.sectionRVA) })
            let nameTable = place(names.flatMap(le32))
            let numbers = place(exports.indices.flatMap { le16(UInt16($0)) })
            let count = UInt32(exports.count)
            let directory = le32(0) + le32(0) + le32(0) + le32(0) + le32(1) + le32(count) + le32(count)
                + le32(addresses) + le32(nameTable) + le32(numbers)
            directories[0] = (place(directory), 40)
        }

        if let runtime = dotNetRuntime {
            var version = Array(runtime.utf8) + [0]
            while version.count % 4 != 0 { version.append(0) }
            let metadata = le32(0x424A_5342) + le16(1) + le16(1) + le32(0) + le32(UInt32(version.count)) + version
            let metadataRVA = place(metadata)
            let header = le32(72) + le16(2) + le16(5) + le32(metadataRVA) + le32(UInt32(metadata.count))
                + [UInt8](repeating: 0, count: 56)
            directories[14] = (place(header), 72)
        }

        var resourceTypes: [(type: UInt32, items: [(id: UInt32, data: [UInt8])])] = []
        if !icons.isEmpty {
            resourceTypes.append((3, icons.enumerated().map { (UInt32($0.offset + 1), $0.element.data) }))
            var group = le16(0) + le16(1) + le16(UInt16(icons.count))
            for (index, icon) in icons.enumerated() {
                group += [icon.side, icon.side, 0, 0] + le16(1) + le16(32) + le32(UInt32(icon.data.count))
                group += le16(UInt16(index + 1))
            }
            resourceTypes.append((14, [(1, group)]))
        }
        if !versionStrings.isEmpty || fixedVersion != nil {
            resourceTypes.append((16, [(1, versionResource())]))
        }
        if !resourceTypes.isEmpty {
            while section.count % 4 != 0 { section.append(0) }
            let start = Self.sectionRVA + UInt32(section.count)
            let tree = Self.resourceTree(resourceTypes, baseRVA: start)
            section += tree
            directories[2] = (start, UInt32(tree.count))
        }
        if section.isEmpty { section = [0] }

        return Data(headers(directories: directories, sectionSize: UInt32(section.count)) + section)
    }

    private func headers(directories: [(rva: UInt32, size: UInt32)], sectionSize: UInt32) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 0x40)
        bytes[0] = 0x4D; bytes[1] = 0x5A
        bytes.replaceSubrange(0x3C ..< 0x40, with: le32(0x40))
        bytes += Array("PE".utf8) + [0, 0]

        let optionalSize: UInt16 = is64Bit ? 240 : 224
        let characteristics: UInt16 = isDLL ? 0x2102 : 0x0102
        bytes += le16(machine) + le16(1) + le32(0) + le32(0) + le32(0) + le16(optionalSize) + le16(characteristics)

        var optional = [UInt8](repeating: 0, count: Int(optionalSize))
        optional.replaceSubrange(0 ..< 2, with: le16(is64Bit ? 0x020B : 0x010B))
        optional.replaceSubrange(68 ..< 70, with: le16(subsystem))
        let countOffset = is64Bit ? 108 : 92
        optional.replaceSubrange(countOffset ..< countOffset + 4, with: le32(16))
        for (index, directory) in directories.enumerated() {
            let at = countOffset + 4 + index * 8
            optional.replaceSubrange(at ..< at + 8, with: le32(directory.rva) + le32(directory.size))
        }
        bytes += optional

        var header = [UInt8](repeating: 0, count: 40)
        header.replaceSubrange(0 ..< 6, with: Array(".rdata".utf8))
        header.replaceSubrange(8 ..< 12, with: le32(sectionSize))
        header.replaceSubrange(12 ..< 16, with: le32(Self.sectionRVA))
        header.replaceSubrange(16 ..< 20, with: le32(sectionSize))
        header.replaceSubrange(20 ..< 24, with: le32(UInt32(Self.sectionFileOffset)))
        bytes += header

        precondition(bytes.count <= Self.sectionFileOffset)
        return bytes + [UInt8](repeating: 0, count: Self.sectionFileOffset - bytes.count)
    }

    // MARK: Resources

    /// Lays out a resource tree: type directories, then name directories, then language
    /// directories, then data entries, then the data itself.
    static func resourceTree(_ types: [(type: UInt32, items: [(id: UInt32, data: [UInt8])])], baseRVA: UInt32) -> [UInt8] {
        let items = types.flatMap(\.items)
        let rootSize = 16 + 8 * types.count
        let typeDirsSize = types.reduce(0) { $0 + 16 + 8 * $1.items.count }
        let languageDirsSize = items.count * (16 + 8)
        let dataEntriesStart = rootSize + typeDirsSize + languageDirsSize
        let dataStart = dataEntriesStart + 16 * items.count

        var out = directory(count: types.count)
        var typeDirOffset = rootSize
        for type in types {
            out += le32(type.type) + le32(0x8000_0000 | UInt32(typeDirOffset))
            typeDirOffset += 16 + 8 * type.items.count
        }
        var languageDirOffset = rootSize + typeDirsSize
        for type in types {
            out += directory(count: type.items.count)
            for item in type.items {
                out += le32(item.id) + le32(0x8000_0000 | UInt32(languageDirOffset))
                languageDirOffset += 16 + 8
            }
        }
        for index in items.indices {
            out += directory(count: 1) + le32(1033) + le32(UInt32(dataEntriesStart + 16 * index))
        }
        var blobs: [UInt8] = []
        for item in items {
            while (dataStart + blobs.count) % 4 != 0 { blobs.append(0) }
            let rva = baseRVA + UInt32(dataStart + blobs.count)
            out += le32(rva) + le32(UInt32(item.data.count)) + le32(0) + le32(0)
            blobs += item.data
        }
        return out + blobs
    }

    private static func directory(count: Int) -> [UInt8] {
        [UInt8](repeating: 0, count: 12) + le16(0) + le16(UInt16(count))
    }

    func versionResource() -> [UInt8] {
        var fixed = le32(0xFEEF_04BD) + le32(0x0001_0000)
        if let (a, b, c, d) = fixedVersion {
            let high = UInt32(a) << 16 | UInt32(b), low = UInt32(c) << 16 | UInt32(d)
            fixed += le32(high) + le32(low) + le32(high) + le32(low)
        } else {
            fixed += [UInt8](repeating: 0, count: 16)
        }
        fixed += [UInt8](repeating: 0, count: 52 - fixed.count)

        let strings = versionStrings.sorted { $0.key < $1.key }.map { key, value in
            Self.versionNode(key: key, type: 1, valueLength: UInt16(value.utf16.count + 1), value: utf16z(value))
        }
        let table = Self.versionNode(key: "040904b0", type: 1, valueLength: 0, value: [], children: strings)
        let stringInfo = Self.versionNode(key: "StringFileInfo", type: 1, valueLength: 0, value: [], children: [table])
        return Self.versionNode(key: "VS_VERSION_INFO", type: 0, valueLength: 52, value: fixed, children: [stringInfo])
    }

    static func versionNode(key: String, type: UInt16, valueLength: UInt16, value: [UInt8], children: [[UInt8]] = []) -> [UInt8] {
        var node = le16(0) + le16(valueLength) + le16(type) + utf16z(key)
        while node.count % 4 != 0 { node.append(0) }
        node += value
        for child in children {
            while node.count % 4 != 0 { node.append(0) }
            node += child
        }
        node.replaceSubrange(0 ..< 2, with: le16(UInt16(node.count)))
        return node
    }
}

func utf16z(_ text: String) -> [UInt8] { text.utf16.flatMap { le16($0) } + [0, 0] }
