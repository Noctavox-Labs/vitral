import Foundation

/// A program of a Windows installation that can become its own Mac app, found from the shortcut
/// its installer made (in the Start menu or on the Windows desktop).
public struct ProgramChoice: Codable, Sendable, Hashable {
    /// The shortcut's name: "MetaEditor 5".
    public var name: String
    /// The program, relative to drive_c with `/` separators: "Program Files/MetaTrader 5/MetaEditor64.exe".
    public var program: String
    /// What the shortcut passes to the program.
    public var arguments: [String]
    /// The icon the shortcut shows, when it is not the program's own.
    public var icon: ProgramIcon?

    public init(name: String, program: String, arguments: [String] = [], icon: ProgramIcon? = nil) {
        self.name = name
        self.program = program
        self.arguments = arguments
        self.icon = icon
    }

    /// The program's folder, relative to drive_c.
    public var folder: String { (program as NSString).deletingLastPathComponent }
    public var fileName: String { (program as NSString).lastPathComponent }
}

/// An icon a shortcut names: Encarta and Encarta Kids are the same ENCARTA.EXE, and their
/// shortcuts show different icons of another file the installer left.
public struct ProgramIcon: Codable, Sendable, Hashable {
    /// The file, relative to drive_c: an `.exe`, `.dll` or `.ico`.
    public var file: String
    /// Which icon of it, as Windows counts them (`ShellLink.iconIndex`).
    public var index: Int

    public init(file: String, index: Int) {
        self.file = file
        self.index = index
    }
}

/// The shortcuts an installer leaves are its own list of the programs meant for people: the
/// main program and, in suites, the others (MetaTrader 5 and MetaEditor; Photoshop and
/// Illustrator), without the helpers that sit next to them.
public enum ProgramShortcuts {
    /// Folders where installers put shortcuts, relative to drive_c (`*` is any user).
    static let roots = [
        "ProgramData/Microsoft/Windows/Start Menu",
        "users/*/AppData/Roaming/Microsoft/Windows/Start Menu",
        "users/*/Desktop",
    ]

    /// Shortcut files in the prefix, relative to drive_c.
    public static func snapshot(driveC: URL) -> Set<String> {
        let fm = FileManager.default
        var found = Set<String>()
        for root in roots {
            for folder in expand(root, in: driveC) {
                // A Desktop linked to the Mac's own would list the person's files.
                let isLink = (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
                guard !isLink, let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { continue }
                for case let file as URL in walker where file.pathExtension.lowercased() == "lnk" {
                    found.insert(String(file.standardizedFileURL.path.dropFirst(driveC.standardizedFileURL.path.count + 1)))
                }
            }
        }
        return found
    }

    /// The programs the shortcuts open, each once, best names first; helpers, uninstallers,
    /// manuals and web links left out.
    public static func programs(shortcuts: Set<String>, driveC: URL) -> [ProgramChoice] {
        var choices: [ProgramChoice] = []
        // Start menu names first (they tend to be the plain ones), then the desktop's.
        let ordered = shortcuts.sorted { a, b in
            let desktopA = a.contains("/Desktop/"), desktopB = b.contains("/Desktop/")
            return desktopA != desktopB ? !desktopA : a.localizedStandardCompare(b) == .orderedAscending
        }
        for relative in ordered {
            let name = ((relative as NSString).lastPathComponent as NSString).deletingPathExtension
            guard !isAccessory(name),
                  let data = FileManager.default.contents(atPath: driveC.appendingPathComponent(relative).path),
                  let link = ShellLink.parse(data),
                  let program = resolve(link, shortcut: relative, driveC: driveC),
                  program.lowercased().hasSuffix(".exe"),
                  !ProgramAnalyzer.isHelper((program as NSString).lastPathComponent) else { continue }
            let arguments = ShellLink.splitArguments(link.arguments)
            guard !choices.contains(where: { $0.program.lowercased() == program.lowercased() && $0.arguments == arguments }) else { continue }
            let icon = link.iconLocation.flatMap { onDriveC($0, driveC: driveC) }
                .flatMap { $0 == program && link.iconIndex == 0 ? nil : ProgramIcon(file: $0, index: link.iconIndex) }
            choices.append(ProgramChoice(name: Wrapper.safeName(name), program: program, arguments: arguments, icon: icon))
        }
        return choices
    }

    /// Shortcut names that are not programs to use: "Uninstall", "Help", "Website"…
    static func isAccessory(_ name: String) -> Bool {
        let lower = name.lowercased()
        let words = ["uninstall", "desinstal", "remove ", "help", "ayuda", "readme", "read me", "léame", "leame",
                     "manual", "website", "web site", "homepage", "home page", "support", "soporte", "license",
                     "licencia", "documentation", "documentación", "changelog", "release notes", "what's new",
                     "novedades", "register", "registr"]
        return words.contains { lower.contains($0) }
    }

    /// The shortcut's program as a path relative to drive_c, with the folder and file names as
    /// they are on disk, if it is on drive C and exists.
    static func resolve(_ link: ShellLink, shortcut: String, driveC: URL) -> String? {
        var components: [String]
        if let target = link.target {
            let parts = target.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
            guard let drive = parts.first, drive.lowercased() == "c:" else { return nil }
            components = Array(parts.dropFirst())
        } else if let relative = link.relativePath {
            components = (shortcut as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
            for part in relative.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init) {
                switch part {
                case ".": continue
                case "..": guard !components.isEmpty else { return nil }; components.removeLast()
                default: components.append(part)
                }
            }
        } else {
            return nil
        }
        return onDisk(components, driveC: driveC)
    }

    /// A Windows path on drive C (`C:\windows\Installer\…\icons.exe`, also with `%SystemRoot%`
    /// and the like), relative to drive_c as it is on disk, if it exists.
    static func onDriveC(_ windowsPath: String, driveC: URL) -> String? {
        var path = windowsPath.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        for (variable, value) in [("%SystemRoot%", #"C:\windows"#), ("%windir%", #"C:\windows"#),
                                  ("%ProgramFiles(x86)%", #"C:\Program Files (x86)"#),
                                  ("%ProgramFiles%", #"C:\Program Files"#), ("%SystemDrive%", "C:")] {
            path = path.replacingOccurrences(of: variable, with: value, options: .caseInsensitive)
        }
        let parts = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
        guard let drive = parts.first, drive.lowercased() == "c:", parts.count > 1 else { return nil }
        return onDisk(Array(parts.dropFirst()), driveC: driveC)
    }

    /// `components` under drive_c with each name as it is on disk (Windows names ignore case).
    private static func onDisk(_ components: [String], driveC: URL) -> String? {
        var folder = driveC
        var found: [String] = []
        for (index, part) in components.enumerated() {
            guard part != "..", let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
                  let match = names.first(where: { $0 == part }) ?? names.first(where: { $0.lowercased() == part.lowercased() })
            else { return nil }
            found.append(match)
            folder = folder.appendingPathComponent(match)
            if index < components.count - 1 {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            }
        }
        return found.isEmpty ? nil : found.joined(separator: "/")
    }

    /// `users/*/Desktop` → each user's Desktop that exists.
    private static func expand(_ pattern: String, in driveC: URL) -> [URL] {
        var folders = [driveC]
        for part in pattern.split(separator: "/").map(String.init) {
            folders = folders.flatMap { folder -> [URL] in
                if part == "*" {
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                    return names.filter { !$0.hasPrefix(".") }.map { folder.appendingPathComponent($0) }
                }
                return [folder.appendingPathComponent(part)]
            }
        }
        return folders.filter { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: $0.path, isDirectory: &d) && d.boolValue }
    }

    /// The programs of an app's Windows that no app in the same folder opens yet: what "Add
    /// another program" offers.
    public static func available(besides app: URL, home: VitralHome = .default) throws -> [ProgramChoice] {
        let wrapper = Wrapper(url: app)
        let manifest = try wrapper.readManifest()
        let driveC = wrapper.prefix(in: home).appendingPathComponent("drive_c")
        let used = ([manifest] + Uninstaller.otherManifests(besides: app).filter { $0.prefix != nil && $0.prefix == manifest.prefix })
            .map { ($0.program.lowercased(), $0.settings.arguments) }
        return programs(shortcuts: snapshot(driveC: driveC), driveC: driveC).filter { choice in
            !used.contains { $0.0 == choice.program.lowercased() && Array($0.1.prefix(choice.arguments.count)) == choice.arguments }
        }
    }
}
