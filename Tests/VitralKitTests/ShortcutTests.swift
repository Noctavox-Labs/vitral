import Foundation
import Testing
@testable import VitralKit

/// A `.lnk` like the ones Wine's shell writes: LinkInfo with an ANSI path, then Unicode strings
/// that count their closing NUL.
func makeShortcut(target: String?, relative: String? = nil, arguments: String = "",
                  icon: String? = nil, iconIndex: Int32 = 0) -> Data {
    var flags: UInt32 = 0x80 | 0x10   // IsUnicode, HasWorkingDir
    if target != nil { flags |= 0x02 }
    if relative != nil { flags |= 0x08 }
    if !arguments.isEmpty { flags |= 0x20 }
    if icon != nil { flags |= 0x40 }
    var bytes = le32(0x4C) + [0x01, 0x14, 0x02, 0, 0, 0, 0, 0, 0xC0, 0, 0, 0, 0, 0, 0, 0x46] + le32(flags)
    bytes += [UInt8](repeating: 0, count: 0x38 - bytes.count) + le32(UInt32(bitPattern: iconIndex))
    bytes += [UInt8](repeating: 0, count: 0x4C - bytes.count)
    if let target {
        let base = Array(target.utf8) + [0]
        let size = 0x1C + base.count + 1
        bytes += le32(UInt32(size)) + le32(0x1C) + le32(1) + le32(0) + le32(0x1C) + le32(0) + le32(UInt32(0x1C + base.count))
        bytes += base + [0]
    }
    func string(_ text: String) -> [UInt8] {
        let units = Array((text + "\0").utf16)
        return le16(UInt16(units.count)) + units.flatMap { le16($0) }
    }
    if let relative { bytes += string(relative) }
    bytes += string(#"C:\Program Files\Suite"#)
    if !arguments.isEmpty { bytes += string(arguments) }
    if let icon { bytes += string(icon) }
    return Data(bytes)
}

@Test func readsWhereAShortcutPoints() {
    let link = ShellLink.parse(makeShortcut(target: #"C:\Program Files\MetaTrader 5\metaeditor64.exe"#, arguments: #"/portable "a b""#))
    #expect(link?.target == #"C:\Program Files\MetaTrader 5\metaeditor64.exe"#)
    #expect(link?.workingDirectory == #"C:\Program Files\Suite"#)
    #expect(ShellLink.splitArguments(link?.arguments ?? "") == ["/portable", "a b"])
    #expect(ShellLink.parse(Data("not a shortcut".utf8)) == nil)
}

@Test func listsTheProgramsAnInstallerMadeShortcutsFor() throws {
    let folder = try TemporaryFolder()
    let driveC = folder.url.appendingPathComponent("drive_c")
    var terminal = SyntheticPE()
    terminal.versionStrings = ["ProductName": "MetaTrader 5 Client Terminal"]
    try folder.write("drive_c/Program Files/MetaTrader 5/terminal64.exe", terminal)
    try folder.write("drive_c/Program Files/MetaTrader 5/MetaEditor64.exe", SyntheticPE())
    try folder.write("drive_c/Program Files/MetaTrader 5/uninstall.exe", SyntheticPE())
    try folder.write("drive_c/Program Files/MetaTrader 5/manual.chm", Data())
    let menu = "drive_c/users/crossover/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/MetaTrader 5"
    let before = ProgramShortcuts.snapshot(driveC: driveC)
    try folder.write("\(menu)/MetaTrader 5.lnk", makeShortcut(target: #"C:\Program Files\MetaTrader 5\terminal64.exe"#))
    // Lower case on purpose: Windows paths ignore case; the result uses the names on disk.
    try folder.write("\(menu)/MetaEditor.lnk", makeShortcut(target: #"c:\program files\metatrader 5\metaeditor64.exe"#))
    try folder.write("\(menu)/Uninstall.lnk", makeShortcut(target: #"C:\Program Files\MetaTrader 5\uninstall.exe"#))
    try folder.write("\(menu)/Help.lnk", makeShortcut(target: #"C:\Program Files\MetaTrader 5\manual.chm"#))
    try folder.write("drive_c/users/Public/Desktop/MetaEditor 5.lnk", makeShortcut(target: #"C:\Program Files\MetaTrader 5\MetaEditor64.exe"#))
    try folder.write("drive_c/users/Public/Desktop/Elsewhere.lnk", makeShortcut(target: #"D:\Other\other.exe"#))
    try folder.write("drive_c/users/Public/Desktop/Relative.lnk", makeShortcut(target: nil, relative: #"..\..\..\Program Files\MetaTrader 5\terminal64.exe"#, arguments: "/config:demo"))

    let added = ProgramShortcuts.snapshot(driveC: driveC).subtracting(before)
    #expect(added.count == 7)
    let programs = ProgramShortcuts.programs(shortcuts: added, driveC: driveC)
    #expect(programs == [
        ProgramChoice(name: "MetaEditor", program: "Program Files/MetaTrader 5/MetaEditor64.exe"),
        ProgramChoice(name: "MetaTrader 5", program: "Program Files/MetaTrader 5/terminal64.exe"),
        ProgramChoice(name: "Relative", program: "Program Files/MetaTrader 5/terminal64.exe", arguments: ["/config:demo"]),
    ])
}

/// An app whose Windows lives in `home`'s Prefixes folder under `prefix`.
private func makeSharedApp(_ folder: TemporaryFolder, name: String, program: String, prefix: String) throws -> URL {
    let app = folder.url.appendingPathComponent("apps/\(name).app")
    let launcher = folder.url.appendingPathComponent("launcher-binary")
    if !FileManager.default.fileExists(atPath: launcher.path) { try Data("#!/bin/sh\n".utf8).write(to: launcher) }
    let manifest = WrapperManifest(name: name, program: program, engine: "cx-test", settings: LaunchSettings(),
                                   installer: "mt5setup.exe", prefix: prefix)
    try Wrapper(url: app).write(manifest: manifest, icns: nil, launcher: launcher, bundleIdentifier: "test.\(prefix).\(name.count)")
    return app
}

@Test func appsOfOneWindowsShareItUntilTheLastIsUninstalled() async throws {
    let folder = try TemporaryFolder()
    let home = VitralHome(url: folder.url.appendingPathComponent("home"))
    let prefix = home.prefixes.appendingPathComponent("mt5")
    try folder.write("home/Prefixes/mt5/drive_c/Program Files/MetaTrader 5/terminal64.exe", SyntheticPE())
    try folder.write("home/Prefixes/mt5/drive_c/Program Files/MetaTrader 5/MetaEditor64.exe", SyntheticPE())
    let menu = "home/Prefixes/mt5/drive_c/ProgramData/Microsoft/Windows/Start Menu/Programs/MetaTrader 5"
    try folder.write("\(menu)/MetaTrader 5.lnk", makeShortcut(target: #"C:\Program Files\MetaTrader 5\terminal64.exe"#))
    try folder.write("\(menu)/MetaEditor.lnk", makeShortcut(target: #"C:\Program Files\MetaTrader 5\MetaEditor64.exe"#))

    let terminal = try makeSharedApp(folder, name: "MetaTrader 5", program: "Program Files/MetaTrader 5/terminal64.exe", prefix: "mt5")
    #expect(try ProgramShortcuts.available(besides: terminal, home: home).map(\.name) == ["MetaEditor"])
    let editor = try makeSharedApp(folder, name: "MetaEditor", program: "Program Files/MetaTrader 5/MetaEditor64.exe", prefix: "mt5")
    #expect(try ProgramShortcuts.available(besides: terminal, home: home).isEmpty)

    let uninstaller = Uninstaller(home: home, logs: folder.url.appendingPathComponent("logs")) { url in
        try FileManager.default.removeItem(at: url)
    }
    // The first one leaves the Windows: MetaEditor still opens a program of it.
    #expect(try uninstaller.items(for: terminal).map(\.lastPathComponent) == ["MetaTrader 5.app"])
    try await uninstaller.uninstall(terminal)
    #expect(FileManager.default.fileExists(atPath: prefix.path))
    // The last one takes it.
    #expect(try uninstaller.items(for: editor).map(\.lastPathComponent) == ["MetaEditor.app", "mt5"])
}

@Test func readsTheArgumentsAndEnvironmentOfAWineProcess() {
    // KERN_PROCARGS2: argc, the executable's path, padding, the arguments, the environment.
    var buffer: [UInt8] = [2, 0, 0, 0]
    for part in ["/opt/wine/bin/wine-preloader", "", "", #"C:\Program Files\Greenshot\Greenshot.exe"#, "/language",
                 "WINEPREFIX=/Users/x/Prefixes/greenshot", "", "WINEDEBUG=-all"] {
        buffer += Array(part.utf8) + [0]
    }
    let parsed = WineProcesses.parse(buffer)
    #expect(parsed?.0 == [#"C:\Program Files\Greenshot\Greenshot.exe"#, "/language"])
    #expect(parsed?.1["WINEPREFIX"] == "/Users/x/Prefixes/greenshot")
    #expect(parsed?.1["WINEDEBUG"] == "-all")
    #expect(WineProcesses.isBackground("mscorsvw.exe"))
    #expect(!WineProcesses.isBackground("Greenshot.exe"))
}

@Test func uninstallsEveryAppOfOneWindowsTogether() async throws {
    let folder = try TemporaryFolder()
    let home = VitralHome(url: folder.url.appendingPathComponent("home"))
    let prefix = home.prefixes.appendingPathComponent("mt5")
    try folder.write("home/Prefixes/mt5/drive_c/Program Files/MetaTrader 5/terminal64.exe", SyntheticPE())
    try folder.write("home/Prefixes/mt5/drive_c/Program Files/MetaTrader 5/MetaEditor64.exe", SyntheticPE())
    let terminal = try makeSharedApp(folder, name: "MetaTrader 5", program: "Program Files/MetaTrader 5/terminal64.exe", prefix: "mt5")
    let editor = try makeSharedApp(folder, name: "MetaEditor", program: "Program Files/MetaTrader 5/MetaEditor64.exe", prefix: "mt5")
    let alone = try makeSharedApp(folder, name: "Notepad++", program: "Program Files/Notepad++/notepad++.exe", prefix: "npp")

    #expect(Uninstaller.companions(of: terminal).map(\.lastPathComponent) == [editor.lastPathComponent])
    #expect(Uninstaller.companions(of: alone).isEmpty)

    let uninstaller = Uninstaller(home: home, logs: folder.url.appendingPathComponent("logs")) { url in
        try FileManager.default.removeItem(at: url)
    }
    let trashed = try await uninstaller.uninstallWithCompanions(terminal)
    #expect(Set(trashed.map(\.lastPathComponent)) == ["MetaEditor.app", "MetaTrader 5.app", "mt5"])
    #expect(!FileManager.default.fileExists(atPath: prefix.path))
    #expect(FileManager.default.fileExists(atPath: alone.path))
}

@Test func readsTheIconAShortcutShows() {
    let link = ShellLink.parse(makeShortcut(target: #"C:\Program Files\Encarta\ENCARTA.EXE"#,
                                            icon: #"C:\windows\Installer\{0904}\ENCICO6B.EXE"#, iconIndex: 9))
    #expect(link?.iconLocation == #"C:\windows\Installer\{0904}\ENCICO6B.EXE"#)
    #expect(link?.iconIndex == 9)
    #expect(ShellLink.parse(makeShortcut(target: #"C:\a.exe"#, icon: #"C:\a.exe"#, iconIndex: -101))?.iconIndex == -101)
    #expect(ShellLink.parse(makeShortcut(target: #"C:\a.exe"#))?.iconLocation == nil)
}

@Test func theSameProgramShowsTheIconItsShortcutNames() throws {
    // Encarta 2009: the encyclopedia and Encarta Kids are the same ENCARTA.EXE; their shortcuts
    // show icons 0 and 1 of a file the installer left in C:\windows\Installer.
    let folder = try TemporaryFolder()
    let driveC = folder.url.appendingPathComponent("drive_c")
    var program = SyntheticPE()
    program.icons = [(16, makePNG(side: 16))]
    try folder.write("drive_c/Program Files/Encarta/Premium/ENCARTA.EXE", program)
    try folder.write("drive_c/Program Files/Encarta/Kids/ENCARTA.EXE", program)
    var icons = SyntheticPE(isDLL: false)
    icons.icons = [(32, makePNG(side: 32))]
    icons.moreIconGroups = [[(48, makePNG(side: 48))]]
    try folder.write("drive_c/windows/Installer/{0904}/ICONS.EXE", icons)
    let menu = "drive_c/users/crossover/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Encarta"
    try folder.write("\(menu)/Encarta.lnk", makeShortcut(target: #"C:\Program Files\Encarta\Premium\ENCARTA.EXE"#,
                                                         icon: #"C:\Program Files\Encarta\Premium\ENCARTA.EXE"#))
    try folder.write("\(menu)/Encarta Kids.lnk", makeShortcut(target: #"C:\Program Files\Encarta\Kids\ENCARTA.EXE"#,
                                                              icon: #"%SystemRoot%\Installer\{0904}\icons.exe"#, iconIndex: 1))

    let programs = ProgramShortcuts.programs(shortcuts: ProgramShortcuts.snapshot(driveC: driveC), driveC: driveC)
    let kids = try #require(programs.first { $0.name == "Encarta Kids" })
    #expect(kids.icon == ProgramIcon(file: "windows/Installer/{0904}/ICONS.EXE", index: 1))
    // Its own icon is no icon to remember.
    #expect(programs.first { $0.name == "Encarta" }?.icon == nil)

    let iconsData = try Data(contentsOf: driveC.appendingPathComponent("windows/Installer/{0904}/ICONS.EXE"))
    let green = try #require(PortableExecutable.icon(iconsData, index: 1))
    #expect(green != PortableExecutable.icon(iconsData, index: 0))
    #expect(PortableExecutable.icon(iconsData, index: -2) == green)   // the group numbered 2
    #expect(PortableExecutable.icon(iconsData, index: 5) == nil)
    #expect(ProgramInstaller.icns(of: kids.program, shortcutIcon: kids.icon, driveC: driveC) == AppIcon.icns(fromICO: green))
    // An icon that is not there: the program's own, as before.
    let own = ProgramInstaller.icns(of: kids.program, shortcutIcon: nil, driveC: driveC)
    #expect(own != nil)
    #expect(ProgramInstaller.icns(of: kids.program, shortcutIcon: ProgramIcon(file: kids.icon!.file, index: 5), driveC: driveC) == own)
    // An .ico file is the icon itself.
    let ico = try #require(PortableExecutable.icon(Data(contentsOf: driveC.appendingPathComponent(kids.program))))
    #expect(PortableExecutable.icon(ico, index: 3) == ico)
}

@Test func anOlderAppGetsTheIconItsShortcutShows() throws {
    let folder = try TemporaryFolder()
    let home = VitralHome(url: folder.url.appendingPathComponent("home"))
    let driveC = home.prefixes.appendingPathComponent("p/drive_c")
    var program = SyntheticPE()
    program.icons = [(16, makePNG(side: 16))]
    try FileManager.default.createDirectory(at: driveC.appendingPathComponent("Kids"), withIntermediateDirectories: true)
    try program.build().write(to: driveC.appendingPathComponent("Kids/ENCARTA.EXE"))
    var icons = SyntheticPE()
    icons.icons = [(32, makePNG(side: 32))]
    icons.moreIconGroups = [[(48, makePNG(side: 48, green: 0.9))]]
    try FileManager.default.createDirectory(at: driveC.appendingPathComponent("users/crossover/Desktop"), withIntermediateDirectories: true)
    try icons.build().write(to: driveC.appendingPathComponent("icons.exe"))
    try makeShortcut(target: #"C:\Kids\ENCARTA.EXE"#, icon: #"C:\icons.exe"#, iconIndex: 1)
        .write(to: driveC.appendingPathComponent("users/crossover/Desktop/Encarta Kids.lnk"))

    let app = Wrapper(url: folder.url.appendingPathComponent("Encarta Kids.app"))
    let launcher = folder.url.appendingPathComponent("launcher")
    try Data("#!/bin/sh\n".utf8).write(to: launcher)
    let manifest = WrapperManifest(name: "Encarta Kids", program: "Kids/ENCARTA.EXE", engine: "cx-test",
                                   settings: LaunchSettings(), recipes: [], prefix: "p")
    let old = try #require(ProgramInstaller.icns(of: "Kids/ENCARTA.EXE", shortcutIcon: nil, driveC: driveC))
    try app.write(manifest: manifest, icns: old, launcher: launcher, bundleIdentifier: "test.kids")

    let green = try #require(ProgramInstaller.icns(for: app, home: home))
    #expect(green != old)
    #expect(try app.updateIcon(green))
    #expect(try !app.updateIcon(green))
    #expect(try Data(contentsOf: app.iconURL) == green)
    #expect(app.hasValidSignature)
}
