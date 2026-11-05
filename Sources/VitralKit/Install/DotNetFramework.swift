import Foundation

/// Microsoft's .NET Framework 4.8 inside a prefix, for programs built on it (WinForms, WPF) and
/// installers that require it (Power BI asks for 4.6.2). Wine's own stand-in, Wine Mono, is not
/// installed by Vitral.
///
/// The steps follow winetricks' `dotnet40` and `dotnet48` (LGPL): the 4.8 installer does not
/// bring `mscoree.dll`, because every Windows it supports has one, so 4.0 goes first, run as
/// Windows XP; 4.8 refuses to install on Windows 10 (it comes with it), so it runs as Windows 7.
/// Both are Microsoft's own installers, downloaded from Microsoft and pinned to the checksums
/// winetricks uses. About five minutes.
public enum DotNetFramework {
    static let license = "Microsoft .NET Framework redistributable license (downloaded from Microsoft, not redistributed by Vitral)"

    public static let installer40 = Component(
        id: "dotnetfx-4.0", name: ".NET Framework 4.0 (Microsoft)",
        url: URL(string: "https://download.microsoft.com/download/9/5/A/95A9616B-7A37-4AF6-BC36-D6EA96C8DAAE/dotNetFx40_Full_x86_x64.exe")!,
        sha256: "65e064258f2e418816b304f646ff9e87af101e4c9552ab064bb74d281c38659f", bytes: 50_449_456,
        archiveRoot: "", license: license,
        source: URL(string: "https://dotnet.microsoft.com/download/dotnet-framework/net40")!,
        fileName: "dotNetFx40_Full_x86_x64.exe")

    public static let installer48 = Component(
        id: "dotnetfx-4.8", name: ".NET Framework 4.8 (Microsoft)",
        url: URL(string: "https://download.visualstudio.microsoft.com/download/pr/7afca223-55d2-470a-8edc-6a1739ae3252/abd170b4b0ec15ad0222a809b761a036/ndp48-x86-x64-allos-enu.exe")!,
        sha256: "95889d6de3f2070c07790ad6cf2000d33d9a1bdfc6a381725ab82ab1c314fd53", bytes: 72_721_568,
        archiveRoot: "", license: license,
        source: URL(string: "https://dotnet.microsoft.com/download/dotnet-framework/net48")!,
        fileName: "ndp48-x86-x64-allos-enu.exe")

    /// `Release` value of .NET Framework 4.8.
    static let release48 = 528_040

    /// The recipe, as listed in the app's manifest.
    public static func recipe(because: String) -> AppliedRecipe { AppliedRecipe(id: "dotnet-framework-4.8", because: because) }

    /// Whether a program needs it: built for .NET Framework 4 (`v4.0.30319`). Programs for 2.0
    /// to 3.5 need .NET 3.5, which this does not bring.
    public static func needed(by runtime: String?) -> Bool {
        guard let runtime else { return false }
        return runtime.lowercased().hasPrefix("v4")
    }

    /// The installed .NET Framework 4 release in the prefix (`NDP\v4\Full` in `system.reg`).
    public static func installedRelease(prefix: URL) -> Int? {
        guard let text = try? String(contentsOf: prefix.appendingPathComponent("system.reg"), encoding: .utf8) else { return nil }
        var inSection = false
        var best: Int?
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("[") {
                inSection = line.lowercased().contains(#"ndp\\v4\\full]"#)
            } else if inSection, line.hasPrefix("\"Release\"=dword:"),
                      let value = Int(line.dropFirst("\"Release\"=dword:".count), radix: 16) {
                best = max(best ?? 0, value)
            }
        }
        return best
    }

    public static func isInstalled(prefix: URL) -> Bool { (installedRelease(prefix: prefix) ?? 0) >= release48 }

    /// Downloads both installers if needed and installs .NET Framework 4.8 into the session's
    /// prefix. `progress` goes from 0 to 1: the downloads are the first fifth.
    public static func install(in session: WineSession, home: VitralHome, log: FileHandle,
                               progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let components = ComponentInstaller(home: home)
        let total = Double(installer40.bytes + installer48.bytes)
        var done = 0.0
        var files: [URL] = []
        for piece in [installer40, installer48] {
            let share = Double(piece.bytes) / total, base = done
            let folder = try await components.install(piece) { progress(0.2 * (base + $0 * share)) }
            files.append(folder.appendingPathComponent(piece.fileName!))
            done += share
        }

        func note(_ text: String) { log.write(Data("[Vitral] .NET Framework: \(text)\n".utf8)) }
        func windowsVersion(_ version: String) async throws {
            _ = try await session.run(["winecfg", "-v", version], output: log)
            await session.waitForServer()
        }
        // Wine's builtin fusion (the .NET assembly cache) is what the installers expect.
        func runInstaller(_ file: URL, _ arguments: [String]) async throws -> Int32 {
            let process = session.process([file.path] + arguments, directory: file.deletingLastPathComponent(), output: log)
            let overrides = process.environment?["WINEDLLOVERRIDES"] ?? ""
            process.environment?["WINEDLLOVERRIDES"] = (overrides.isEmpty ? "" : overrides + ";") + "fusion=b"
            let status = try await WineSession.wait(for: process)
            await session.waitForServer()
            return status
        }

        note("4.0, as Windows XP (it brings mscoree.dll)")
        progress(0.25)
        try await windowsVersion("winxp64")
        let status40 = try await runInstaller(files[0], ["/q", "/c:install.exe /q"])
        note("4.0 ended with \(status40)")
        // Microsoft's mscoree, not Wine's.
        try await session.importRegistry([.string(#"HKEY_CURRENT_USER\Software\Wine\DllOverrides"#, "mscoree", "native")])

        note("4.8, as Windows 7 (on Windows 10 it says it is already there)")
        progress(0.6)
        try await windowsVersion("win7")
        let status48 = try await runInstaller(files[1], ["/q", "/norestart"])
        note("4.8 ended with \(status48)")
        try await windowsVersion("win10")
        progress(1)

        guard isInstalled(prefix: session.prefix) else {
            throw InstallError.dotNetFailed(release: installedRelease(prefix: session.prefix))
        }
        note("installed (release \(installedRelease(prefix: session.prefix) ?? 0))")
    }
}
