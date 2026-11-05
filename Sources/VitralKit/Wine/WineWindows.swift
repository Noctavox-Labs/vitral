import CoreGraphics
import Foundation

/// Normal windows on screen and the processes that own them, named after the Windows file each
/// runs (`Setup.exe`, `Setup.tmp`…). CrossOver 24 named the process after it; Wine 11 shows them
/// all as `wine`, but keeps the Windows path as the process's first argument.
public enum WineWindows {
    public struct Owner: Hashable, Sendable {
        public let pid: pid_t
        public let name: String
    }

    /// Owners of normal windows (layer 0) on screen, front to back, each once.
    public static func owners() -> [Owner] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var seen = Set<pid_t>()
        var owners: [Owner] = []
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let name = window[kCGWindowOwnerName as String] as? String,
                  !seen.contains(pid) else { continue }
            seen.insert(pid)
            owners.append(Owner(pid: pid, name: windowsFileName(of: pid) ?? name))
        }
        return owners
    }

    /// The file name a Windows process runs ("aTube Catcher.exe"), from its first argument
    /// (`C:\users\…\aTube Catcher.exe`). Nil for processes that are not Windows programs.
    public static func windowsFileName(of pid: pid_t) -> String? {
        guard let first = firstArgument(of: pid) else { return nil }
        return windowsFileName(fromArgument: first)
    }

    static func windowsFileName(fromArgument argument: String) -> String? {
        // Chromium (Electron apps) rewrites its main process's arguments and leaves only the
        // file name: "aTube Catcher.exe".
        if !argument.contains("/"), !argument.contains("\\"),
           argument.range(of: #"^[^\s][^\u{0}]*\.(exe|tmp|com)$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return argument
        }
        // A Windows path: a drive letter or a UNC/device prefix, with backslashes.
        guard argument.contains("\\"),
              argument.range(of: #"^([A-Za-z]:\\|\\\\)"#, options: .regularExpression) != nil,
              let name = argument.split(separator: "\\").last, !name.isEmpty else { return nil }
        return String(name)
    }

    /// argv[0] of a process, read with sysctl(KERN_PROCARGS2): an argc, the executable's path,
    /// padding NULs, then the arguments, each ending in NUL.
    static func firstArgument(of pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }   // executable path
        while index < size, buffer[index] == 0 { index += 1 }   // padding
        let start = index
        while index < size, buffer[index] != 0 { index += 1 }
        guard index > start else { return nil }
        return String(decoding: buffer[start..<index], as: UTF8.self)
    }

    /// Whether a process name is a Windows program's (Inno Setup runs its wizard as `.tmp`).
    public static func looksLikeWindows(_ name: String) -> Bool {
        let lower = name.lowercased()
        return [".exe", ".tmp", ".msi"].contains { lower.hasSuffix($0) }
    }
}
