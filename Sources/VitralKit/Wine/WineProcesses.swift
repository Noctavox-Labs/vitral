import Darwin
import Foundation

/// The Windows processes of one prefix, windows or not: each Wine process carries its
/// `WINEPREFIX` in its environment, readable with sysctl(KERN_PROCARGS2) for the person's own
/// processes. Programs that live in the menu bar (Greenshot) have no window to look for.
public enum WineProcesses {
    public struct Entry: Equatable, Sendable {
        public let pid: pid_t
        /// The Windows file name: "Greenshot.exe".
        public let name: String
    }

    /// Processes Windows and .NET keep running in the background: they do not mean the installer
    /// or the program is still busy.
    static let background: Set<String> = [
        "services.exe", "winedevice.exe", "plugplay.exe", "svchost.exe", "rpcss.exe", "explorer.exe",
        "conhost.exe", "tabtip.exe", "mscorsvw.exe", "ngen.exe", "ngentask.exe", "microsoftedgeupdate.exe",
        "winemenubuilder.exe", "wineboot.exe",
    ]

    /// Whether a process of the prefix only works in the background.
    public static func isBackground(_ name: String) -> Bool { background.contains(name.lowercased()) }

    /// The Windows processes running in `prefix`.
    public static func list(prefix: URL) -> [Entry] {
        let wanted = prefix.standardizedFileURL.path
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard found > 0 else { return [] }
        return pids.prefix(Int(found)).compactMap { pid in
            guard pid > 0, let (arguments, environment) = arguments(of: pid),
                  let first = arguments.first, let name = WineWindows.windowsFileName(fromArgument: first),
                  let own = environment["WINEPREFIX"],
                  URL(fileURLWithPath: own).standardizedFileURL.path == wanted else { return nil }
            return Entry(pid: pid, name: name)
        }
    }

    /// The arguments and environment of a process (KERN_PROCARGS2: argc, the executable's path,
    /// padding, the arguments, then the environment, each ending in NUL).
    static func arguments(of pid: pid_t) -> ([String], [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parse(buffer)
    }

    /// Reads a KERN_PROCARGS2 buffer.
    static func parse(_ buffer: [UInt8]) -> ([String], [String: String])? {
        let size = buffer.count
        guard size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var strings: [String] = []
        var start = index
        while index < size {
            if buffer[index] == 0 {
                // Empty strings pad the gaps; the environment comes after the arguments.
                if index > start { strings.append(String(decoding: buffer[start..<index], as: UTF8.self)) }
                start = index + 1
            }
            index += 1
        }
        guard strings.count >= argc else { return nil }
        var environment: [String: String] = [:]
        for entry in strings.dropFirst(argc) {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return (Array(strings.prefix(argc)), environment)
    }
}
