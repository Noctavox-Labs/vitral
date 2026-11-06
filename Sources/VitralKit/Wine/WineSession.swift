import Foundation

/// One value in the Windows registry of a prefix.
public struct RegistryValue: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// Text (`REG_SZ`).
        case string
        /// 32-bit number (`REG_DWORD`).
        case dword
    }

    /// Full key, such as `HKEY_CURRENT_USER\Software\Wine\Mac Driver`.
    public let key: String
    public let name: String
    public let kind: Kind
    /// The text, or the number in decimal.
    public let value: String

    public static func string(_ key: String, _ name: String, _ value: String) -> RegistryValue {
        RegistryValue(key: key, name: name, kind: .string, value: value)
    }

    public static func dword(_ key: String, _ name: String, _ value: UInt32) -> RegistryValue {
        RegistryValue(key: key, name: name, kind: .dword, value: String(value))
    }
}

/// Writes `.reg` files that `reg import` understands.
public enum RegistryFile {
    public static func render(_ values: [RegistryValue]) -> String {
        var lines = ["REGEDIT4", ""]
        var order: [String] = []
        var byKey: [String: [RegistryValue]] = [:]
        for value in values {
            if byKey[value.key] == nil { order.append(value.key) }
            byKey[value.key, default: []].append(value)
        }
        for key in order {
            lines.append("[\(key)]")
            for value in byKey[key] ?? [] {
                let name = "\"\(escape(value.name))\""
                switch value.kind {
                case .string:
                    lines.append("\(name)=\"\(escape(value.value))\"")
                case .dword:
                    let number = UInt32(value.value) ?? 0
                    lines.append("\(name)=dword:" + String(format: "%08x", number))
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\r\n")
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

public enum WineError: Error, CustomStringConvertible {
    case failed(command: String, status: Int32)
    case registryNotApplied

    public var description: String {
        switch self {
        case .failed(let command, let status):
            return tr("Wine falló al ejecutar «\(command)» (código \(status)).",
                      "Wine failed running “\(command)” (status \(status)).")
        case .registryNotApplied:
            return tr("Wine no guardó los ajustes del registro.", "Wine did not save the registry settings.")
        }
    }
}

/// Runs Wine commands in one prefix with one engine.
public struct WineSession: Sendable {
    public let engine: InstalledEngine
    public let prefix: URL
    /// Every variable the processes get: the engine's, then the extra ones.
    public let environment: [String: String]

    public init(engine: InstalledEngine, prefix: URL, extraEnvironment: [String: String] = [:]) {
        self.engine = engine
        self.prefix = prefix
        var environment = ProcessInfo.processInfo.environment
        // A WINEPREFIX or WINEDEBUG from the person's shell must not leak in.
        for key in environment.keys where key.hasPrefix("WINE") || key.hasPrefix("DYLD_") {
            environment.removeValue(forKey: key)
        }
        environment.merge(engine.environment(prefix: prefix)) { _, new in new }
        environment.merge(extraEnvironment) { _, new in new }
        self.environment = environment
    }

    public var driveC: URL { prefix.appendingPathComponent("drive_c") }

    /// Whether Wine passes a variable from the Mac's environment to Windows programs. It leaves
    /// out `QT_…` and `VK_…` (so the Mac's own Qt and Vulkan settings do not leak in), and the
    /// variables it handles itself. Those go in the registry instead (`HKCU\Environment`).
    public static func reachesWindows(_ name: String) -> Bool {
        let upper = name.uppercased()
        if upper.hasPrefix("QT_") || upper.hasPrefix("VK_") { return false }
        return !["PATH", "PWD", "HOME", "TEMP", "TMP", "XDG_SESSION_TYPE"].contains(upper)
    }

    /// Whether this prefix's Wine is running: while it runs, its server keeps a socket in
    /// `/tmp/.wine-<user>/server-<device>-<inode>/`, named after the prefix folder.
    public var serverIsRunning: Bool { Self.serverIsRunning(prefix: prefix) }

    /// Whether a Wine server runs for `prefix` (some Windows process of it is open).
    public static func serverIsRunning(prefix: URL) -> Bool {
        var info = stat()
        guard stat(prefix.path, &info) == 0 else { return false }
        let folder = String(format: "/tmp/.wine-%u/server-%llx-%llx", getuid(),
                            UInt64(UInt32(bitPattern: info.st_dev)), UInt64(info.st_ino))
        return FileManager.default.fileExists(atPath: folder + "/socket")
    }

    /// A `wine` process, ready to start.
    public func process(_ arguments: [String], directory: URL? = nil, output: FileHandle? = nil) -> Process {
        let process = Process()
        process.executableURL = engine.wine
        process.arguments = arguments
        process.environment = environment
        // drive_c does not exist until the prefix is created.
        process.currentDirectoryURL = directory
            ?? (FileManager.default.fileExists(atPath: driveC.path) ? driveC : prefix)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = output ?? FileHandle.nullDevice
        return process
    }

    /// Runs `wine <arguments>` and waits for it.
    @discardableResult
    public func run(_ arguments: [String], directory: URL? = nil, output: FileHandle? = nil) async throws -> Int32 {
        try await Self.wait(for: process(arguments, directory: directory, output: output))
    }

    /// Waits until every Windows process of the prefix has ended and the server stopped.
    public func waitForServer() async {
        _ = try? await Self.wait(for: serverProcess(["-w"]))
    }

    /// Stops every Windows process of the prefix at once.
    public func killServer() async {
        _ = try? await Self.wait(for: serverProcess(["-k"]))
        await waitForServer()
    }

    /// Ends every Windows process of the prefix, also hung ones ("Force Quit"). Closing a program
    /// from the Mac's menu sends it Windows' end-of-session messages and waits until every window
    /// answers, with no time limit (`macdrv_app_quit_request` in winemac.drv): a hung program never
    /// closes that way. `wineserver -k` ends the processes with a signal, without asking them.
    /// Whatever is left after `timeout` seconds (a server that does not answer, or an engine that
    /// is gone) gets SIGKILL. Returns whether no process of the prefix is left.
    @discardableResult
    public func forceQuit(timeout: TimeInterval = 10) async -> Bool {
        _ = try? await Self.wait(for: serverProcess(["-k"]))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !serverIsRunning, WineProcesses.list(prefix: prefix).isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        for process in WineProcesses.list(prefix: prefix) { kill(process.pid, SIGKILL) }
        for _ in 0..<8 where !WineProcesses.list(prefix: prefix).isEmpty {
            try? await Task.sleep(for: .milliseconds(250))
        }
        return WineProcesses.list(prefix: prefix).isEmpty
    }

    /// Creates the Windows folders and registry of a new prefix.
    public func createPrefix() async throws {
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let boot = process(["wineboot", "--init"])
        boot.environment?["WINEDLLOVERRIDES"] = InstalledEngine.prefixCreationOverrides
        let status = try await Self.wait(for: boot)
        await waitForServer()
        guard status == 0, FileManager.default.fileExists(atPath: prefix.appendingPathComponent("system.reg").path) else {
            throw WineError.failed(command: "wineboot --init", status: status)
        }
    }

    /// Imports registry values with `reg import` and checks that Wine saved them.
    public func importRegistry(_ values: [RegistryValue]) async throws {
        guard !values.isEmpty else { return }
        let temp = driveC.appendingPathComponent("windows/temp")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let file = temp.appendingPathComponent("vitral-settings.reg")
        try Data(RegistryFile.render(values).utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let status = try await run(["reg", "import", #"C:\windows\temp\vitral-settings.reg"#])
        await waitForServer()
        guard status == 0 else { throw WineError.failed(command: "reg import", status: status) }
        guard registryContains(values) else { throw WineError.registryNotApplied }
    }

    /// Whether `user.reg` and `system.reg` hold these values (Wine writes them when the server stops).
    public func registryContains(_ values: [RegistryValue]) -> Bool {
        let text = ["user.reg", "system.reg"]
            .compactMap { try? String(contentsOf: prefix.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
        return values.allSatisfy { value in
            let expected: String
            switch value.kind {
            case .string: expected = "\"\(value.name)\"=\"\(value.value)\""
            case .dword: expected = "\"\(value.name)\"=dword:" + String(format: "%08x", UInt32(value.value) ?? 0)
            }
            return text.contains(expected)
        }
    }

    private func serverProcess(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = engine.wineserver
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    /// Starts a process and waits for it without blocking a thread.
    public static func wait(for process: Process) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
