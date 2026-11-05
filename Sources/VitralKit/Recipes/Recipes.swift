import Foundation

/// How to open one program: what goes in its environment and registry, and what to clean first.
public struct LaunchSettings: Codable, Sendable, Equatable {
    public var environment: [String: String]
    public var registry: [RegistryValue]
    /// Files to delete before opening, as patterns relative to the prefix
    /// (`*` and `?` match inside one folder name). Only plain files inside the prefix are deleted.
    public var cleanup: [String]
    public var arguments: [String]

    public init(environment: [String: String] = [:], registry: [RegistryValue] = [],
                cleanup: [String] = [], arguments: [String] = []) {
        self.environment = environment
        self.registry = registry
        self.cleanup = cleanup
        self.arguments = arguments
    }
}

/// A rule Vitral applied, and what in the program triggered it.
public struct AppliedRecipe: Codable, Sendable, Equatable {
    public let id: String
    public let because: String

    public init(id: String, because: String) {
        self.id = id
        self.because = because
    }
}

/// Rules per framework, learned from programs that work (see `Caso Shape It.md`).
public enum Recipes {
    static let macDriver = #"HKEY_CURRENT_USER\Software\Wine\Mac Driver"#
    static let desktop = #"HKEY_CURRENT_USER\Control Panel\Desktop"#
    static let fonts = #"HKEY_LOCAL_MACHINE\System\CurrentControlSet\Hardware Profiles\Current\Software\Fonts"#
    static let wineDbg = #"HKEY_CURRENT_USER\Software\Wine\WineDbg"#
    /// Variables every Windows program of the prefix gets. Needed for the ones Wine does not
    /// pass from the Mac (see `WineSession.reachesWindows`).
    static let windowsEnvironment = #"HKEY_CURRENT_USER\Environment"#
    /// Wine's own DLL and program overrides; an empty value turns that one off.
    static let dllOverrides = #"HKEY_CURRENT_USER\Software\Wine\DllOverrides"#

    /// Settings the prefix needs before the installer runs, and the rules that produced them.
    /// They stay in the prefix: the program, its uninstaller and its updates get them too.
    public static func installerSettings(for report: InstallerReport) -> (registry: [RegistryValue], applied: [AppliedRecipe]) {
        var registry: [RegistryValue] = []
        var applied: [AppliedRecipe] = []
        if report.builder == .electronBuilder, report.runsPowerShell {
            // electron-builder asks PowerShell whether the program is open. Wine's PowerShell is a
            // stand-in that does nothing and exits with 0, which the installer reads as "it is
            // open": it asks to close it, cannot, and quits without installing. With PowerShell
            // turned off it checks with tasklist instead, which works (see `Caso aTube Catcher.md`).
            registry.append(.string(dllOverrides, "powershell.exe", ""))
            applied.append(AppliedRecipe(id: "electron-builder-no-powershell", because: "electron-builder"))
        }
        return (registry, applied)
    }

    /// Every prefix: no crash dialog from Wine's debugger (Vitral reads the log instead).
    public static let base: [RegistryValue] = [
        .dword(wineDbg, "ShowCrashDialog", 0),
    ]

    /// Full Retina resolution, with Windows told the screen is 192 dpi (200 %).
    public static let retina: [RegistryValue] = [
        .string(macDriver, "RetinaMode", "y"),
        .dword(desktop, "LogPixels", 192),
        .dword(fonts, "LogPixels", 192),
    ]

    public static let qtLocks = [
        "drive_c/users/*/Temp/qsingleinstance-*.lock",
        "drive_c/users/*/AppData/Local/Temp/qsingleinstance-*.lock",
    ]

    /// The settings for a program, and the rules that produced them.
    public static func settings(for report: ProgramReport) -> (settings: LaunchSettings, applied: [AppliedRecipe]) {
        var settings = LaunchSettings(registry: base)
        var applied: [AppliedRecipe] = []

        if let qt = report.technology(.qt) {
            let label = "Qt" + (qt.version.map { " " + $0 } ?? "")
            if qt.version?.hasPrefix("5.") == true {
                // Qt 5 ignores the 192 dpi on its own; QT_SCALE_FACTOR=2 scales its windows and text
                // (without it the window opens at half size, unreadable). It goes in the registry:
                // Wine drops the Mac's QT_* variables. QT_AUTO_SCREEN_SCALE_FACTOR breaks window creation.
                settings.registry += retina
                settings.registry.append(.string(windowsEnvironment, "QT_SCALE_FACTOR", "2"))
                applied.append(AppliedRecipe(id: "qt5-retina", because: label))

                if report.technology(.qtQuick) != nil {
                    // Qt Quick fails to create its OpenGL context under Wine on macOS.
                    settings.environment["QMLSCENE_DEVICE"] = "softwarecontext"
                    applied.append(AppliedRecipe(id: "qt5-quick-software", because: label + " · Qt Quick"))
                }
            }
            // A lock left by a forced quit makes the program exit silently on the next start.
            settings.cleanup += qtLocks
            applied.append(AppliedRecipe(id: "qt-single-instance", because: label))
        }

        if report.technology(.electron) != nil {
            // Chromium draws in a separate GPU process, and DXMT (Direct3D 11 on Metal) cannot yet
            // show what another process draws: the window stays blank. In-process, it works
            // (see `Caso aTube Catcher.md`).
            settings.arguments.append("--in-process-gpu")
            applied.append(AppliedRecipe(id: "electron-in-process-gpu", because: "Electron"))
        }
        return (settings, applied)
    }

    /// What a rule does, in words.
    public static func describe(_ id: String, language: Language = .current) -> String {
        switch id {
        case "qt5-retina":
            return tr("Nítido en Retina: resolución completa, 192 ppp y QT_SCALE_FACTOR=2",
                      "Sharp on Retina: full resolution, 192 dpi and QT_SCALE_FACTOR=2", language)
        case "qt5-quick-software":
            return tr("Qt Quick dibuja sin OpenGL (QMLSCENE_DEVICE=softwarecontext)",
                      "Qt Quick draws without OpenGL (QMLSCENE_DEVICE=softwarecontext)", language)
        case "qt-single-instance":
            return tr("Borra el candado de instancia única antes de abrir",
                      "Removes the single-instance lock before opening", language)
        case "electron-in-process-gpu":
            return tr("Electron dibuja dentro del programa (--in-process-gpu): DXMT todavía no muestra lo que dibuja otro proceso",
                      "Electron draws inside the program (--in-process-gpu): DXMT cannot yet show what another process draws", language)
        case "electron-builder-no-powershell":
            return tr("PowerShell desactivado: el de Wine no hace nada y el instalador creía que el programa seguía abierto",
                      "PowerShell turned off: Wine's does nothing, and the installer thought the program was still open", language)
        case "dotnet-framework-4.8":
            return tr(".NET Framework 4.8 de Microsoft instalado en su Windows (en vez de Wine Mono)",
                      "Microsoft's .NET Framework 4.8 installed in its Windows (instead of Wine Mono)", language)
        default:
            return id
        }
    }
}

/// Files of a prefix that match cleanup patterns.
public enum PrefixFiles {
    /// Plain files under `root` matching `pattern`. Never leaves `root`: patterns with `..` or an
    /// absolute path match nothing, and symbolic links (the prefix links to the Mac's Desktop,
    /// Documents and disks) are neither followed nor returned.
    public static func matching(_ pattern: String, in root: URL) -> [URL] {
        let parts = pattern.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !pattern.hasPrefix("/"), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return [] }

        var current = [root]
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            var next: [URL] = []
            for folder in current {
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
                for name in names where fnmatch(part, name, 0) == 0 {
                    let url = folder.appendingPathComponent(name)
                    guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]),
                          values.isSymbolicLink != true else { continue }
                    if isLast {
                        if values.isRegularFile == true { next.append(url) }
                    } else if values.isDirectory == true {
                        next.append(url)
                    }
                }
            }
            current = next
        }
        return current.sorted { $0.path < $1.path }
    }

    /// Deletes the files that match any of the patterns. Returns how many were deleted.
    @discardableResult
    public static func clean(_ patterns: [String], in root: URL) -> Int {
        var deleted = 0
        for pattern in patterns {
            for file in matching(pattern, in: root) where (try? FileManager.default.removeItem(at: file)) != nil {
                deleted += 1
            }
        }
        return deleted
    }
}
