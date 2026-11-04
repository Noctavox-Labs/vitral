import CoreGraphics
import Foundation

/// Normal windows on screen and the processes that own them. In macOS a Windows program shows
/// up as a process named after its file (`Setup.exe`, `Setup.tmp`…), with its own Dock icon.
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
            owners.append(Owner(pid: pid, name: name))
        }
        return owners
    }

    /// Whether a process name is a Windows program's (Inno Setup runs its wizard as `.tmp`).
    public static func looksLikeWindows(_ name: String) -> Bool {
        let lower = name.lowercased()
        return [".exe", ".tmp", ".msi"].contains { lower.hasSuffix($0) }
    }
}
