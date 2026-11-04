import Foundation

/// Finds what an installer added to a prefix: the folders that are new afterwards.
public enum ProgramFinder {
    /// Folders (relative to `drive_c`) whose children are program folders.
    static let roots = ["Program Files", "Program Files (x86)", "", "users/*/AppData/Local/Programs"]

    /// Folders Wine itself creates in `drive_c`; never a program.
    static let ignored: Set<String> = ["windows", "users", "ProgramData", "Program Files", "Program Files (x86)"]

    /// Every program-folder candidate in the prefix now, relative to `drive_c`.
    public static func snapshot(driveC: URL) -> Set<String> {
        var found = Set<String>()
        for root in roots {
            for folder in expand(root, in: driveC) {
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.url.path) else { continue }
                for name in names where !name.hasPrefix(".") {
                    let relative = folder.relative.isEmpty ? name : folder.relative + "/" + name
                    if folder.relative.isEmpty, ignored.contains(name) { continue }
                    var isDirectory: ObjCBool = false
                    let url = folder.url.appendingPathComponent(name)
                    let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
                    if !isLink, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                        found.insert(relative)
                    }
                }
            }
        }
        return found
    }

    /// The installed program among the new folders: the one with a program to open, preferring
    /// a windowed one, then the biggest.
    public static func choose(newFolders: Set<String>, driveC: URL) -> (folder: String, report: ProgramReport)? {
        let candidates = newFolders.sorted().compactMap { relative -> (String, ProgramReport)? in
            guard let report = try? ProgramAnalyzer.analyze(folderAt: driveC.appendingPathComponent(relative)),
                  report.mainExecutable != nil else { return nil }
            return (relative, report)
        }
        return candidates.max { a, b in
            let guiA = a.1.executable?.subsystem == .gui, guiB = b.1.executable?.subsystem == .gui
            if guiA != guiB { return !guiA }
            return a.1.totalBytes < b.1.totalBytes
        }.map { (folder: $0.0, report: $0.1) }
    }

    /// Expands one `*` per path component (only used for the user folder).
    private static func expand(_ pattern: String, in driveC: URL) -> [(relative: String, url: URL)] {
        guard !pattern.isEmpty else { return [("", driveC)] }
        var current: [(String, URL)] = [("", driveC)]
        for part in pattern.split(separator: "/").map(String.init) {
            var next: [(String, URL)] = []
            for (relative, url) in current {
                let names = part.contains("*")
                    ? ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { fnmatch(part, $0, 0) == 0 }
                    : [part]
                for name in names {
                    let child = url.appendingPathComponent(name)
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: child.path, isDirectory: &isDirectory), isDirectory.boolValue {
                        next.append((relative.isEmpty ? name : relative + "/" + name, child))
                    }
                }
            }
            current = next
        }
        return current
    }
}
