import Foundation

public enum DiscImageError: Error, CustomStringConvertible {
    case cannotMount(String)
    case noSetup(label: String?)
    case noFreeDrive

    public var description: String {
        switch self {
        case .cannotMount(let detail):
            return tr("No pude abrir la imagen de disco (\(detail)).", "Could not open the disc image (\(detail)).")
        case .noSetup(let label):
            let disc = label.map { "«\($0)»" } ?? tr("el disco", "the disc")
            return tr("No encontré un instalador en \(disc): ni autorun.inf que lleve a uno, ni setup.exe, ni un solo .msi.",
                      "Could not find an installer on \(disc): no autorun.inf leading to one, no setup.exe, no single .msi.")
        case .noFreeDrive:
            return tr("No queda ninguna letra de unidad libre para el disco.", "No drive letter is free for the disc.")
        }
    }
}

/// What a disc image holds, seen before installing.
public struct DiscContents: Sendable, Equatable {
    /// The name Windows shows for the disc.
    public let label: String?
    /// The installer's path on the disc, Windows style ("SETUP.EXE", "x64\setup.exe").
    public let setupPath: String
    /// The installer, analyzed.
    public let setup: InstallerReport
    /// The installer's icon (ICO).
    public let icon: Data?
}

/// A CD or DVD image (`.iso`). While the installer runs, Vitral mounts it read-only and hidden
/// from the Finder, and Windows sees it as a CD drive with the disc's label: installers that read
/// the rest of their files from the disc, or check that it is in the drive, work as with the disc.
public struct DiscImage: Sendable {
    /// Extensions accepted when a file is dropped or chosen.
    public static let fileExtensions: Set<String> = ["iso"]

    /// The image file.
    public let image: URL
    /// Where it is mounted.
    public let mountPoint: URL
    /// Its device ("/dev/disk9"). Through the raw device Wine reads the label and serial number.
    public let device: String

    // MARK: Reading the image without mounting it

    /// Volume descriptors start at 32 KiB and take 2 KiB each; byte 0 is the type, bytes 1-5 the
    /// standard: "CD001" (ISO 9660), "BEA01"/"NSR02"/"NSR03"/"TEA01" (UDF).
    static let descriptorStart = 32 * 1024
    static let descriptorSize = 2048
    static let standards: Set<String> = ["CD001", "BEA01", "NSR02", "NSR03", "TEA01"]

    /// Whether the bytes (from the start of the file) are an ISO 9660 or UDF disc.
    public static func isDiscImage(_ data: Data) -> Bool {
        (0..<4).contains { index in
            let start = data.startIndex + descriptorStart + index * descriptorSize + 1
            guard data.endIndex >= start + 5 else { return false }
            return standards.contains(String(decoding: data[start..<start + 5], as: UTF8.self))
        }
    }

    /// The disc's name as Windows shows it: the Joliet one (the long name, type 2 descriptor with
    /// UCS-2) if there is one, otherwise the ISO 9660 one. Nil for discs that are only UDF.
    public static func label(of data: Data) -> String? {
        var primary: String?
        var joliet: String?
        for index in 0..<32 {
            let start = data.startIndex + descriptorStart + index * descriptorSize
            guard data.endIndex >= start + descriptorSize,
                  String(decoding: data[start + 1..<start + 6], as: UTF8.self) == "CD001" else { break }
            let type = data[start]
            if type == 255 { break }
            let field = data[start + 40..<start + 72]
            if type == 1 {
                primary = String(decoding: field, as: UTF8.self)
            } else if type == 2, data[start + 88] == 0x25, data[start + 89] == 0x2F,
                      [0x40, 0x43, 0x45].contains(data[start + 90]) {
                // Joliet: escape sequence "%/@", "%/C" or "%/E", text in UCS-2 big endian.
                joliet = String(data: Data(field), encoding: .utf16BigEndian)
            }
        }
        let label = (joliet ?? primary)?
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\0")))
        return label?.isEmpty == false ? label : nil
    }

    // MARK: Mounting

    /// Mounts the image read-only inside `folder`, hidden from the Finder.
    public static func mount(_ image: URL, in folder: URL) async throws -> DiscImage {
        let fm = FileManager.default
        let mountPoint = folder.appendingPathComponent("Disco - " + UUID().uuidString.prefix(8))
        try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let (status, output) = try await runTool("/usr/bin/hdiutil", [
            "attach", "-readonly", "-nobrowse", "-noautoopen", "-noverify",
            "-mountpoint", mountPoint.path, "-plist", image.path,
        ])
        let plist = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any]
        let entities = plist?["system-entities"] as? [[String: Any]] ?? []
        guard status == 0,
              let device = entities.first(where: { $0["mount-point"] != nil })?["dev-entry"] as? String else {
            rmdir(mountPoint.path)
            throw DiscImageError.cannotMount("hdiutil \(status)")
        }
        return DiscImage(image: image, mountPoint: mountPoint, device: device)
    }

    /// Unmounts the disc (Wine must not be using it) and removes its empty folder.
    public func eject() {
        for arguments in [["detach", device, "-quiet"], ["detach", device, "-quiet", "-force"]] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            process.waitUntilExit()
            if process.terminationStatus == 0 { break }
        }
        // Only an empty folder goes: never what is on a disc still mounted.
        rmdir(mountPoint.path)
    }

    /// Mounts the image for a moment to see which installer it holds.
    public static func contents(of image: URL, in folder: URL) async throws -> DiscContents {
        let disc = try await mount(image, in: folder)
        defer { disc.eject() }
        let data = try Data(contentsOf: image, options: .alwaysMapped)
        guard let setup = disc.setupProgram else { throw DiscImageError.noSetup(label: label(of: data)) }
        let report = try InstallerAnalyzer.analyze(fileAt: setup)
        let icon = (try? Data(contentsOf: setup, options: .alwaysMapped)).flatMap(PortableExecutable.icon)
        let path = setup.path.dropFirst(disc.mountPoint.path.count + 1).replacingOccurrences(of: "/", with: "\\")
        return DiscContents(label: label(of: data), setupPath: path, setup: report, icon: icon)
    }

    // MARK: The installer on the disc

    /// The disc's installer.
    public var setupProgram: URL? { Self.setupProgram(in: mountPoint) }

    /// The program that installs what is on a disc: what `autorun.inf` opens if it is a setup
    /// program; otherwise `setup.exe` or `install.exe` at the root; otherwise the only `.msi` there;
    /// otherwise what `autorun.inf` opens (often a menu that leads to the setup); otherwise the only
    /// `.exe` at the root.
    public static func setupProgram(in root: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let files = names.filter { !$0.hasPrefix(".") }
        func file(_ name: String) -> URL? {
            files.first { $0.lowercased() == name }.map { root.appendingPathComponent($0) }
        }
        let autorun = file("autorun.inf").flatMap { autorunTarget($0, root: root) }
        if let autorun, ProgramInstaller.looksLikeSetup(autorun.lastPathComponent) { return autorun }
        if let setup = file("setup.exe") ?? file("install.exe") { return setup }
        let packages = files.filter { $0.lowercased().hasSuffix(".msi") }
        if packages.count == 1 { return root.appendingPathComponent(packages[0]) }
        if let autorun { return autorun }
        let programs = files.filter { $0.lowercased().hasSuffix(".exe") }
        return programs.count == 1 ? root.appendingPathComponent(programs[0]) : nil
    }

    /// The `.exe` or `.msi` that `autorun.inf` opens (`open=` or `shellexecute=` in `[autorun]`).
    static func autorunTarget(_ inf: URL, root: URL) -> URL? {
        guard let data = try? Data(contentsOf: inf) else { return nil }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: Unicode.ASCII.self)
        var section = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line.lowercased(); continue }
            guard section == "[autorun]", let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "open" || key == "shellexecute" else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") {
                value = String(value.dropFirst().prefix { $0 != "\"" })
            } else if let end = value.range(of: ".exe", options: .caseInsensitive) ?? value.range(of: ".msi", options: .caseInsensitive) {
                // Arguments after the program: "setup.exe /autorun".
                value = String(value[..<end.upperBound])
            }
            if let target = resolve(value, in: root),
               ["exe", "msi"].contains(target.pathExtension.lowercased()) { return target }
        }
        return nil
    }

    /// A Windows path on the disc ("Bin\SETUP.EXE"), found whatever the case of its letters.
    static func resolve(_ windowsPath: String, in root: URL) -> URL? {
        var current = root
        for part in windowsPath.split(whereSeparator: { $0 == "\\" || $0 == "/" }) where part != "." {
            guard part != "..",
                  let names = try? FileManager.default.contentsOfDirectory(atPath: current.path),
                  let match = names.first(where: { $0.lowercased() == part.lowercased() }) else { return nil }
            current = current.appendingPathComponent(match)
        }
        var isDirectory: ObjCBool = false
        guard current != root, FileManager.default.fileExists(atPath: current.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return current
    }

    // MARK: The CD drive

    /// Where Wine keeps each drive's type.
    static let drivesKey = #"HKEY_LOCAL_MACHINE\Software\Wine\Drives"#

    /// The registry value that makes `letter` a CD drive.
    public static func driveType(_ letter: String) -> RegistryValue {
        .string(drivesKey, letter + ":", "cdrom")
    }

    /// Shows the disc to the prefix's Windows as a drive: the first free letter from D:. Returns
    /// the letter ("e"). The drive's type is set apart (`driveType`), through the registry.
    public func attach(to prefix: URL) throws -> String {
        let devices = prefix.appendingPathComponent("dosdevices")
        let fm = FileManager.default
        for letter in "defghijklmnopqrstuvwxy" {
            let link = devices.appendingPathComponent("\(letter):")
            var info = stat()
            // Taken if anything is there, also a link to a volume that is gone.
            guard lstat(link.path, &info) != 0 else { continue }
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: mountPoint.path)
            let raw = device.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")
            try? fm.createSymbolicLink(atPath: devices.appendingPathComponent("\(letter)::").path, withDestinationPath: raw)
            return String(letter)
        }
        throw DiscImageError.noFreeDrive
    }

    /// Takes the drive away from the prefix (the disc is not in it anymore).
    public static func detach(letter: String, from prefix: URL) {
        let devices = prefix.appendingPathComponent("dosdevices")
        for name in ["\(letter):", "\(letter)::"] {
            try? FileManager.default.removeItem(at: devices.appendingPathComponent(name))
        }
    }

    // MARK: Helpers

    /// Runs a tool and returns its status and what it printed.
    static func runTool(_ path: String, _ arguments: [String]) async throws -> (Int32, Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // Read while it runs: a full pipe would stop it.
        let reader = Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }
        let status: Int32
        do {
            status = try await WineSession.wait(for: process)
        } catch {
            // It did not start: nobody else will close the pipe.
            try? pipe.fileHandleForWriting.close()
            _ = await reader.value
            throw error
        }
        return (status, await reader.value)
    }
}
