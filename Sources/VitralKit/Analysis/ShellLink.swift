import Foundation

/// A Windows shortcut (`.lnk`, the Shell Link format): what it opens. Only what Vitral needs is
/// read: the target's path (from the LinkInfo block, or the relative path), its arguments, its
/// working folder and the icon it shows. Shortcuts that point at a shell item without a path (Control Panel…)
/// have no target.
public struct ShellLink: Equatable, Sendable {
    /// Windows path of the program, such as `C:\Program Files\App\app.exe`.
    public var target: String?
    /// Path relative to the shortcut's own folder, used when there is no absolute one.
    public var relativePath: String?
    public var arguments: String
    public var workingDirectory: String?
    /// The file whose icon the shortcut shows, when it is not the program's own: a Windows path
    /// to an `.exe`, `.dll` or `.ico` (Encarta's three programs show icons of `ENCICO6B.EXE`).
    public var iconLocation: String?
    /// Which icon of that file: from 0, the nth in the file; negative, the one numbered -n.
    public var iconIndex: Int = 0

    public static func parse(_ data: Data) -> ShellLink? {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int? { at + 2 <= bytes.count ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 : nil }
        func u32(_ at: Int) -> Int? {
            guard at + 4 <= bytes.count else { return nil }
            return (0 ..< 4).reduce(0) { $0 | Int(bytes[at + $1]) << (8 * $1) }
        }
        // Header: size 0x4C and the shell link class id.
        guard u32(0) == 0x4C, bytes.count >= 0x4C,
              Array(bytes[4 ..< 20]) == [0x01, 0x14, 0x02, 0, 0, 0, 0, 0, 0xC0, 0, 0, 0, 0, 0, 0, 0x46],
              let flags = u32(0x14), let index = u32(0x38) else { return nil }
        let unicode = flags & 0x80 != 0
        var offset = 0x4C
        if flags & 0x01 != 0 {  // HasLinkTargetIDList
            guard let size = u16(offset) else { return nil }
            offset += 2 + size
        }

        var link = ShellLink(target: nil, relativePath: nil, arguments: "", workingDirectory: nil)
        if flags & 0x02 != 0 {  // HasLinkInfo
            guard let size = u32(offset), let headerSize = u32(offset + 4), let infoFlags = u32(offset + 8),
                  offset + size <= bytes.count else { return nil }
            if infoFlags & 0x01 != 0 {  // VolumeIDAndLocalBasePath
                if headerSize >= 0x24, let unicodeOffset = u32(offset + 0x1C), unicodeOffset > 0 {
                    link.target = utf16z(bytes, from: offset + unicodeOffset, end: offset + size)
                }
                if link.target?.isEmpty ?? true, let baseOffset = u32(offset + 0x10) {
                    link.target = ansiz(bytes, from: offset + baseOffset, end: offset + size)
                }
            }
            offset += size
        }

        // StringData: NAME, RELATIVE_PATH, WORKING_DIR, ARGUMENTS, ICON_LOCATION, each present
        // only if its flag is set: a count of characters, then the characters.
        var strings: [UInt32: String] = [:]
        for flag in [0x04, 0x08, 0x10, 0x20, 0x40] as [UInt32] where flags & Int(flag) != 0 {
            guard let count = u16(offset) else { break }
            offset += 2
            let length = unicode ? count * 2 : count
            guard offset + length <= bytes.count else { break }
            let chunk = Array(bytes[offset ..< offset + length])
            let text = unicode ? String(decoding: stride(from: 0, to: chunk.count, by: 2).map { UInt16(chunk[$0]) | UInt16(chunk[$0 + 1]) << 8 }, as: UTF16.self)
                               : String(decoding: chunk, as: UTF8.self)
            // Wine counts the closing NUL in these strings.
            strings[flag] = text.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            offset += length
        }
        link.relativePath = strings[0x08].flatMap { $0.isEmpty ? nil : $0 }
        link.workingDirectory = strings[0x10].flatMap { $0.isEmpty ? nil : $0 }
        link.arguments = strings[0x20] ?? ""
        link.iconLocation = strings[0x40].flatMap { $0.isEmpty ? nil : $0 }
        link.iconIndex = Int(Int32(bitPattern: UInt32(index)))
        if link.target?.isEmpty ?? true { link.target = nil }
        return link.target == nil && link.relativePath == nil ? nil : link
    }

    private static func ansiz(_ bytes: [UInt8], from start: Int, end: Int) -> String? {
        guard start < end, start < bytes.count else { return nil }
        let stop = bytes[start ..< min(end, bytes.count)].firstIndex(of: 0) ?? min(end, bytes.count)
        return String(decoding: bytes[start ..< stop], as: UTF8.self)
    }

    private static func utf16z(_ bytes: [UInt8], from start: Int, end: Int) -> String? {
        var units: [UInt16] = []
        var at = start
        while at + 1 < min(end, bytes.count) {
            let unit = UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
            if unit == 0 { break }
            units.append(unit)
            at += 2
        }
        return units.isEmpty ? nil : String(decoding: units, as: UTF16.self)
    }

    /// Splits a Windows command line into arguments: spaces separate them, double quotes group.
    public static func splitArguments(_ line: String) -> [String] {
        var result: [String] = [], current = "", quoted = false, started = false
        for character in line {
            if character == "\"" {
                quoted.toggle()
                started = true
            } else if (character == " " || character == "\t") && !quoted {
                if started { result.append(current); current = ""; started = false }
            } else {
                current.append(character)
                started = true
            }
        }
        if started { result.append(current) }
        return result
    }
}
