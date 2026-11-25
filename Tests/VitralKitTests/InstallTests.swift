import Foundation
import Testing
@testable import VitralKit

/// A drive_c with a Qt 5 + Qt Quick program, like Shape It!, under the given folder.
private func writeQtProgram(_ folder: TemporaryFolder, at path: String, name: String) throws {
    var main = SyntheticPE()
    main.imports = ["kernel32.dll", "qt5core.dll", "qt5quick.dll"]
    main.versionStrings = ["ProductName": name, "CompanyName": "Avallain", "ProductVersion": "28,0,0"]
    main.icons = [(16, makePNG(side: 16))]
    try folder.write("\(path)/\(name).exe", main)
    var core = SyntheticPE()
    core.isDLL = true
    core.fixedVersion = (5, 12, 4, 0)
    try folder.write("\(path)/Qt5Core.dll", core)
    try folder.write("\(path)/Qt5Quick.dll", SyntheticPE(isDLL: true))
    try folder.write("\(path)/unins000.exe", SyntheticPE())
}

@Test func qtCoreAloneDoesNotMakeAWin32ProgramRetina() throws {
    // Winamp 5.9: a Win32 skin, plus Qt Core and Qt Network for its online parts.
    let folder = try TemporaryFolder()
    var main = SyntheticPE()
    main.imports = ["kernel32.dll", "user32.dll", "gdi32.dll"]
    main.versionStrings = ["ProductName": "Winamp", "CompanyName": "Winamp SA"]
    try folder.write("Winamp/winamp.exe", main)
    var core = SyntheticPE()
    core.isDLL = true
    core.fixedVersion = (5, 15, 11, 0)
    try folder.write("Winamp/Qt5Core.dll", core)
    try folder.write("Winamp/Qt5Network.dll", SyntheticPE(isDLL: true))
    let report = try ProgramAnalyzer.analyze(folderAt: folder.url.appendingPathComponent("Winamp"))
    #expect(report.technology(.qt)?.version == "5.15.11")
    #expect(report.technology(.qtGui) == nil)

    let (settings, applied) = Recipes.settings(for: report)
    #expect(!applied.map(\.id).contains("qt5-retina"))
    #expect(!settings.registry.contains(.string(Recipes.macDriver, "RetinaMode", "y")))
    #expect(!settings.registry.contains { $0.name == "QT_SCALE_FACTOR" })
}

@Test func qtWidgetsProgramGetsRetina() throws {
    let folder = try TemporaryFolder()
    try folder.write("App/app.exe", SyntheticPE())
    var core = SyntheticPE()
    core.isDLL = true
    core.fixedVersion = (5, 15, 2, 0)
    try folder.write("App/Qt5Core.dll", core)
    try folder.write("App/Qt5Gui.dll", SyntheticPE(isDLL: true))
    try folder.write("App/Qt5Widgets.dll", SyntheticPE(isDLL: true))
    let report = try ProgramAnalyzer.analyze(folderAt: folder.url.appendingPathComponent("App"))
    #expect(Recipes.settings(for: report).applied.map(\.id) == ["qt5-retina", "qt-single-instance"])
}

// MARK: Registry

@Test func writesRegistryFilesWineImports() {
    let text = RegistryFile.render([
        .string(#"HKEY_CURRENT_USER\Software\Wine\Mac Driver"#, "RetinaMode", "y"),
        .dword(#"HKEY_CURRENT_USER\Control Panel\Desktop"#, "LogPixels", 192),
        .string(#"HKEY_CURRENT_USER\Software\Wine\Mac Driver"#, "Path", #"C:\a "b""#),
    ])
    #expect(text == [
        "REGEDIT4", "",
        #"[HKEY_CURRENT_USER\Software\Wine\Mac Driver]"#,
        #""RetinaMode"="y""#,
        #""Path"="C:\\a \"b\"""#,
        "",
        #"[HKEY_CURRENT_USER\Control Panel\Desktop]"#,
        #""LogPixels"=dword:000000c0"#,
        "",
    ].joined(separator: "\r\n"))
}

// MARK: Recipes

@Test func qt5QuickProgramGetsTheShapeItSettings() throws {
    let folder = try TemporaryFolder()
    try writeQtProgram(folder, at: "Shape it", name: "Shape it Level 1 PPlus")
    let report = try ProgramAnalyzer.analyze(folderAt: folder.url.appendingPathComponent("Shape it"))
    let (settings, applied) = Recipes.settings(for: report)

    #expect(applied.map(\.id) == ["qt5-retina", "qt5-quick-software", "qt-single-instance"])
    #expect(applied.first?.because == "Qt 5.12.4")
    #expect(settings.environment == ["QMLSCENE_DEVICE": "softwarecontext"])
    #expect(settings.registry.contains(.string(Recipes.windowsEnvironment, "QT_SCALE_FACTOR", "2")))
    #expect(settings.registry.contains(.string(Recipes.macDriver, "RetinaMode", "y")))
    // Wine drops the Mac's QT_* variables: a recipe must never rely on them.
    #expect(settings.environment.keys.allSatisfy(WineSession.reachesWindows))
    #expect(!WineSession.reachesWindows("QT_SCALE_FACTOR"))
    #expect(WineSession.reachesWindows("QMLSCENE_DEVICE"))
    #expect(settings.registry.filter { $0.name == "LogPixels" }.count == 2)
    #expect(settings.registry.contains(.dword(Recipes.wineDbg, "ShowCrashDialog", 0)))
    #expect(settings.cleanup == Recipes.qtLocks)
}

@Test func electronProgramDrawsInProcess() throws {
    let folder = try TemporaryFolder()
    try folder.write("aTube Catcher/aTube Catcher.exe", SyntheticPE())
    try folder.write("aTube Catcher/resources/app.asar", Data("asar".utf8))
    let report = try ProgramAnalyzer.analyze(folderAt: folder.url.appendingPathComponent("aTube Catcher"))
    let (settings, applied) = Recipes.settings(for: report)
    #expect(applied.map(\.id) == ["electron-in-process-gpu"])
    #expect(settings.arguments == ["--in-process-gpu"])
}

@Test func programWithoutKnownFrameworkKeepsWineDefaults() throws {
    let folder = try TemporaryFolder()
    try folder.write("Tool/tool.exe", SyntheticPE())
    let report = try ProgramAnalyzer.analyze(folderAt: folder.url.appendingPathComponent("Tool"))
    let (settings, applied) = Recipes.settings(for: report)
    #expect(applied.isEmpty)
    #expect(settings.environment.isEmpty)
    #expect(settings.registry == Recipes.base)
    #expect(settings.cleanup.isEmpty)
}

// MARK: Cleanup

@Test func cleanupMatchesOnlyPlainFilesInsideThePrefix() throws {
    let folder = try TemporaryFolder()
    let prefix = folder.url.appendingPathComponent("prefix")
    try folder.write("prefix/drive_c/users/crossover/Temp/qsingleinstance-shapeitl-1.lock", Data())
    try folder.write("prefix/drive_c/users/crossover/Temp/other.lock", Data())
    try folder.write("prefix/drive_c/users/crossover/Temp/qsingleinstance-folder.lock/keep", Data())
    // A link to a folder outside, like Wine's links to the Mac's Desktop: never followed.
    try folder.write("outside/Temp/qsingleinstance-mine.lock", Data())
    try FileManager.default.createSymbolicLink(at: prefix.appendingPathComponent("drive_c/users/link"),
                                               withDestinationURL: folder.url.appendingPathComponent("outside"))

    let found = PrefixFiles.matching("drive_c/users/*/Temp/qsingleinstance-*.lock", in: prefix)
    #expect(found.map(\.lastPathComponent) == ["qsingleinstance-shapeitl-1.lock"])
    #expect(PrefixFiles.matching("../outside/Temp/*", in: prefix).isEmpty)
    #expect(PrefixFiles.matching("/etc/hosts", in: prefix).isEmpty)
    #expect(PrefixFiles.matching("drive_c/users/link/Temp/*", in: prefix).isEmpty)

    #expect(PrefixFiles.clean(Recipes.qtLocks, in: prefix) == 1)
    #expect(PrefixFiles.matching("drive_c/users/*/Temp/*.lock", in: prefix).map(\.lastPathComponent) == ["other.lock"])
    #expect(FileManager.default.fileExists(atPath: folder.url.appendingPathComponent("outside/Temp/qsingleinstance-mine.lock").path))
}

// MARK: Finding the installed program

@Test func findsTheProgramTheInstallerAdded() throws {
    let folder = try TemporaryFolder()
    let driveC = folder.url.appendingPathComponent("drive_c")
    try folder.write("drive_c/Program Files/Common Files/readme.txt", Data())
    try folder.write("drive_c/windows/notepad.exe", SyntheticPE())
    let before = ProgramFinder.snapshot(driveC: driveC)
    #expect(before == ["Program Files/Common Files"])

    try writeQtProgram(folder, at: "drive_c/Program Files (x86)/Shape it Level 1 PPlus", name: "Shape it Level 1 PPlus")
    var console = SyntheticPE()
    console.subsystem = 3
    try folder.write("drive_c/Program Files/Helper/helper.exe", console)
    try folder.write("drive_c/Program Files/Docs/manual.pdf", Data())
    try folder.write("drive_c/users/crossover/AppData/Local/Programs/Other/other.exe", SyntheticPE())

    let added = ProgramFinder.snapshot(driveC: driveC).subtracting(before)
    #expect(added == ["Program Files (x86)/Shape it Level 1 PPlus", "Program Files/Helper", "Program Files/Docs",
                      "users/crossover/AppData/Local/Programs/Other"])
    let chosen = try #require(ProgramFinder.choose(newFolders: added, driveC: driveC))
    // Windowed beats console, then the biggest folder wins.
    #expect(chosen.folder == "Program Files (x86)/Shape it Level 1 PPlus")
    #expect(chosen.report.mainExecutable == "Shape it Level 1 PPlus.exe")
    #expect(ProgramFinder.choose(newFolders: ["Program Files/Docs"], driveC: driveC) == nil)
}

@Test func refusesWhatWineCannotRun() {
    func report(_ kind: InstallerKind, _ info: ExecutableInfo?) -> InstallerReport {
        InstallerReport(fileName: "x.exe", sizeBytes: 1, kind: kind, kindVersion: nil, executable: info, companionFiles: [])
    }
    #expect(ProgramInstaller.refusal(report(.executable, ExecutableInfo(format: .dos))) != nil)
    #expect(ProgramInstaller.refusal(report(.executable, ExecutableInfo(format: .windows16))) != nil)
    #expect(ProgramInstaller.refusal(report(.executable, ExecutableInfo(format: .pe32, isDLL: true))) != nil)
    #expect(ProgramInstaller.refusal(report(.unknown, nil)) != nil)
    #expect(ProgramInstaller.refusal(report(.innoSetup, ExecutableInfo(format: .pe32))) == nil)
    #expect(ProgramInstaller.looksLikeSetup("Setup.exe"))
    #expect(ProgramInstaller.looksLikeSetup("npp.8.7.Installer.x64.exe"))
    #expect(!ProgramInstaller.looksLikeSetup("putty.exe"))
}

@Test func findsTheProgramsInsideNewFolders() throws {
    let folder = try TemporaryFolder()
    try writeQtProgram(folder, at: "drive_c/Program Files (x86)/Shape it", name: "Shape it Level 1 PPlus")
    try folder.write("drive_c/Program Files (x86)/Shape it/bin/QtWebEngineProcess.exe", SyntheticPE())
    let names = ProgramFinder.executableNames(inFolders: ["Program Files (x86)/Shape it"],
                                              driveC: folder.url.appendingPathComponent("drive_c"))
    #expect(names == ["shape it level 1 pplus.exe", "qtwebengineprocess.exe"])
    #expect(WineWindows.looksLikeWindows("Shape it Level 1 PPlus.tmp"))
    #expect(!WineWindows.looksLikeWindows("Finder"))
}

// MARK: Wrapper

@Test func writesAWrapperMacOSCanOpen() throws {
    let folder = try TemporaryFolder()
    let wrapper = Wrapper(url: folder.url.appendingPathComponent("Shape it.app"))
    let launcher = folder.url.appendingPathComponent("launcher-binary")
    try Data("#!/bin/sh\n".utf8).write(to: launcher)
    let manifest = WrapperManifest(
        name: "Shape it Level 1 PPlus", program: "Program Files (x86)/Shape it/Shape it.exe", engine: "cx24.0.7_7",
        settings: LaunchSettings(environment: ["QT_SCALE_FACTOR": "2"], cleanup: Recipes.qtLocks),
        recipes: [AppliedRecipe(id: "qt5-retina", because: "Qt 5.12.4")],
        product: VersionInfo(productName: "Shape it Level 1 PPlus", companyName: "Avallain", productVersion: "28.0.0"),
        created: Date(timeIntervalSince1970: 1_800_000_000))
    try wrapper.write(manifest: manifest, icns: Data([1, 2, 3]), launcher: launcher,
                      bundleIdentifier: "com.noctavox.vitral.app.shape-it.1234abcd")

    let info = try #require(NSDictionary(contentsOf: wrapper.contents.appendingPathComponent("Info.plist")) as? [String: Any])
    #expect(info["CFBundleExecutable"] as? String == "launcher")
    #expect(info["CFBundleIconFile"] as? String == "AppIcon")
    #expect(info["CFBundleShortVersionString"] as? String == "28.0.0")
    #expect(info["LSUIElement"] as? Bool == true)
    #expect(info[Wrapper.marker] != nil)
    #expect(FileManager.default.fileExists(atPath: wrapper.launcherURL.path))
    #expect(try wrapper.readManifest() == manifest)
    #expect(try wrapper.programURL(manifest).path.hasSuffix("SharedSupport/prefix/drive_c/Program Files (x86)/Shape it/Shape it.exe"))

    var escaping = manifest
    escaping.program = "../../../../bin/sh"
    #expect(throws: WrapperError.self) { try wrapper.programURL(escaping) }
    #expect(throws: WrapperError.self) { try Wrapper(url: folder.url).readManifest() }
}

@Test func namesAndIdentifiersAreSafe() {
    #expect(Wrapper.safeName("AC/DC: Live") == "AC-DC- Live")
    #expect(Wrapper.safeName("  ..  ") == "Programa")
    let id = Wrapper.bundleIdentifier(for: "Shape it Level 1 PPlus")
    #expect(id.hasPrefix("com.noctavox.vitral.app.shape-it-level-1-pplus."))
    #expect(id != Wrapper.bundleIdentifier(for: "Shape it Level 1 PPlus"))
    #expect(Wrapper.bundleIdentifier(for: "日本").hasPrefix("com.noctavox.vitral.app.program."))
}

// MARK: Start watch

@Test func retriesOnlyCrashesWhileStarting() {
    let crash = "0024:err:seh:NtRaiseException Unhandled page fault on read access to 00000000 at address 00000000"
    #expect(StartupWatch.shouldRetry(ranFor: 5, sawWindow: false, log: crash, attempt: 1))
    #expect(!StartupWatch.shouldRetry(ranFor: 5, sawWindow: false, log: crash, attempt: StartupWatch.maxAttempts))
    #expect(!StartupWatch.shouldRetry(ranFor: 5, sawWindow: true, log: crash, attempt: 1))
    #expect(!StartupWatch.shouldRetry(ranFor: 300, sawWindow: false, log: crash, attempt: 1))
    // Closed quickly without a crash (the person closed it, or another copy was open).
    #expect(!StartupWatch.shouldRetry(ranFor: 5, sawWindow: false, log: "fixme:ole:something", attempt: 1))
}

// MARK: Wine processes

@Test func namesWineProcessesAfterTheirWindowsFile() {
    // Wine 11 shows every Windows process as "wine"; its first argument keeps the Windows path.
    #expect(WineWindows.windowsFileName(fromArgument: #"C:\users\crossover\AppData\Local\Programs\aTube Catcher\aTube Catcher.exe"#) == "aTube Catcher.exe")
    #expect(WineWindows.windowsFileName(fromArgument: #"C:\windows\system32\explorer.exe"#) == "explorer.exe")
    #expect(WineWindows.windowsFileName(fromArgument: #"\\?\Z:\Users\me\Downloads\Setup.tmp"#) == "Setup.tmp")
    #expect(WineWindows.windowsFileName(fromArgument: "/Applications/Vitral.app/Contents/MacOS/Vitral") == nil)
    #expect(WineWindows.windowsFileName(fromArgument: "wine") == nil)
    // Electron's main process keeps only the file name.
    #expect(WineWindows.windowsFileName(fromArgument: "aTube Catcher.exe") == "aTube Catcher.exe")
    #expect(WineWindows.windowsFileName(fromArgument: "./run.exe") == nil)
    // A real process that is not a Windows program keeps its own name.
    #expect(WineWindows.windowsFileName(of: getpid()) == nil)
}

@Test func updatesAnOlderLauncher() throws {
    let folder = try TemporaryFolder()
    let wrapper = Wrapper(url: folder.url.appendingPathComponent("P.app"))
    let old = folder.url.appendingPathComponent("old"), new = folder.url.appendingPathComponent("new")
    try Data("old".utf8).write(to: old)
    try Data("new".utf8).write(to: new)
    let manifest = WrapperManifest(name: "P", program: "p.exe", engine: "x", settings: LaunchSettings())
    try wrapper.write(manifest: manifest, icns: nil, launcher: old, bundleIdentifier: "test.p")

    #expect(try wrapper.updateLauncher(from: new))
    #expect(try Data(contentsOf: wrapper.launcherURL) == Data("new".utf8))
    #expect(try !wrapper.updateLauncher(from: new))
    #expect(try FileManager.default.contentsOfDirectory(atPath: wrapper.launcherURL.deletingLastPathComponent().path) == ["launcher"])
    #expect(throws: WrapperError.self) { try Wrapper(url: folder.url).updateLauncher(from: new) }
}

@Test func launcherCopiesLoseTheQuarantineMark() throws {
    let folder = try TemporaryFolder()
    let launcher = folder.url.appendingPathComponent("downloaded-launcher")
    try Data("#!/bin/sh\n".utf8).write(to: launcher)
    let mark = "0083;6a0b1c2d;Chrome;"
    #expect(setxattr(launcher.path, "com.apple.quarantine", mark, mark.utf8.count, 0, 0) == 0)

    let wrapper = Wrapper(url: folder.url.appendingPathComponent("P.app"))
    let manifest = WrapperManifest(name: "P", program: "p.exe", engine: "x", settings: LaunchSettings())
    try wrapper.write(manifest: manifest, icns: nil, launcher: launcher, bundleIdentifier: "test.p")
    #expect(getxattr(wrapper.launcherURL.path, "com.apple.quarantine", nil, 0, 0, 0) < 0)
}

/// A ZIP made with `ditto`, as the Finder makes them, from `files` (path → contents).
private func makeZip(_ files: [String: Data], as name: String, in folder: TemporaryFolder) throws -> URL {
    let source = folder.url.appendingPathComponent(name + "-src")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    for (path, data) in files { try folder.write(name + "-src/" + path, data) }
    let zip = folder.url.appendingPathComponent(name + ".zip")
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-c", "-k", source.path, zip.path]
    try ditto.run()
    ditto.waitUntilExit()
    return zip
}

@Test func runsTheInstallerAZipHolds() async throws {
    let folder = try TemporaryFolder()
    let staging = folder.url.appendingPathComponent("staging")
    let setup = makeNSIS(texts: ["hello"])

    let single = try makeZip(["paint.net.install.x64.exe": setup], as: "single", in: folder)
    let found = try #require(try await installer(single))
    #expect(found.file.lastPathComponent == "paint.net.install.x64.exe")
    #expect(found.report.kind == .nsis)

    // An installer with a note beside it is still an installer.
    let withNote = try makeZip(["Setup.exe": setup, "readme.txt": Data()], as: "two", in: folder)
    #expect(try await installer(withNote)?.file.lastPathComponent == "Setup.exe")
    #expect(try await ZipPackage.unpack(try makeZip(["tool.txt": Data("x".utf8)], as: "text", in: folder), in: staging) == nil)

    func installer(_ zip: URL) async throws -> (file: URL, report: InstallerReport)? {
        guard case .installer(_, let file, let report) = try await ZipPackage.unpack(zip, in: staging) else { return nil }
        return (file, report)
    }
}

@Test func findsTheInstallerOfAFolderSentByWeTransfer() async throws {
    // Shape It! Level 2: WeTransfer gave a ZIP with a folder, and in it the Inno Setup installer
    // and its two data files. Vitral copied the installer as if it were the program.
    let folder = try TemporaryFolder()
    let staging = folder.url.appendingPathComponent("staging")
    let inside = "Shape it Level 2 PPlus_3.0.1.zip/"
    let zip = try makeZip([
        inside + "Shape it Level 2 PPlus.exe": makePE(payload: Array("JR.Inno.Setup".utf8)),
        inside + "Shape it Level 2 PPlus-1a.bin": Data(count: 2048),
        inside + "Shape it Level 2 PPlus-1b.bin": Data(count: 1024),
        "__MACOSX/._x": Data(), inside + ".DS_Store": Data(),
    ], as: "wetransfer_shape-it-level-2", in: folder)

    // A look without unpacking it all: the installer, and the files it needs, from the ZIP's list.
    let contents = try #require(try await ZipPackage.contents(of: zip, in: staging))
    #expect(contents.setupPath == inside + "Shape it Level 2 PPlus.exe")
    #expect(contents.setup.kind == .innoSetup)
    #expect(contents.setup.companionFiles == ["Shape it Level 2 PPlus-1a.bin", "Shape it Level 2 PPlus-1b.bin"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)

    // Unpacked to install: the data files beside the installer.
    guard case .installer(let unpacked, let file, let report) = try await ZipPackage.unpack(zip, in: staging) else {
        Issue.record("no installer")
        return
    }
    #expect(report.kind == .innoSetup)
    #expect(report.companionFiles == ["Shape it Level 2 PPlus-1a.bin", "Shape it Level 2 PPlus-1b.bin"])
    let bin = file.deletingLastPathComponent().appendingPathComponent("Shape it Level 2 PPlus-1a.bin")
    #expect((try? Data(contentsOf: bin))?.count == 2048)
    // Only the unpacked ZIP stays: the first look is gone.
    #expect(try FileManager.default.contentsOfDirectory(atPath: unpacked.path) == ["unpacked"])
}

@Test func looksInsideAZipInsideTheZip() async throws {
    let folder = try TemporaryFolder()
    let staging = folder.url.appendingPathComponent("staging")
    let inner = try makeZip(["Carpeta [v2]/Setup.exe": makeNSIS(texts: ["hello"]), "Carpeta [v2]/data.cab": Data(count: 10)],
                            as: "Programa", in: folder)
    let outer = try makeZip(["Programa.zip": try Data(contentsOf: inner), "Léeme.txt": Data()], as: "wetransfer", in: folder)

    let contents = try #require(try await ZipPackage.contents(of: outer, in: staging))
    #expect(contents.setupPath == "Programa.zip › Carpeta [v2]/Setup.exe")
    #expect(contents.setup.kind == .nsis)
    guard case .installer(_, let file, _) = try await ZipPackage.unpack(outer, in: staging) else {
        Issue.record("no installer")
        return
    }
    #expect(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().appendingPathComponent("data.cab").path))

    // A portable program in the inner ZIP: that ZIP is what gets unpacked into Program Files.
    let portable = try makeZip(["HeidiSQL/heidisql.exe": SyntheticPE().build()], as: "HeidiSQL_12", in: folder)
    let sent = try makeZip(["HeidiSQL_12.zip": try Data(contentsOf: portable)], as: "wetransfer-portable", in: folder)
    #expect(try await ZipPackage.contents(of: sent, in: staging) == nil)
    guard case .portable(let work, let zip) = try await ZipPackage.unpack(sent, in: staging) else {
        Issue.record("not the inner ZIP")
        return
    }
    #expect(zip.lastPathComponent == "HeidiSQL_12.zip")
    #expect(try Data(contentsOf: zip) == Data(contentsOf: portable))
    #expect(try FileManager.default.contentsOfDirectory(atPath: work.path).count == 1)
}

@Test func aPortableProgramInAZipIsNotAnInstaller() async throws {
    let folder = try TemporaryFolder()
    let staging = folder.url.appendingPathComponent("staging")
    var program = SyntheticPE()
    program.versionStrings = ["FileDescription": "HeidiSQL"]
    // Its own program beside an uninstaller, or beside an installer it brings (a runtime, a driver).
    for (name, extra) in [("unins000.exe", makePE(payload: Array("JR.Inno.Setup".utf8))), ("DriverSetup.exe", makeNSIS(texts: ["x"]))] {
        let zip = try makeZip(["HeidiSQL/heidisql.exe": program.build(), "HeidiSQL/" + name: extra,
                               "HeidiSQL/libmariadb.dll": SyntheticPE(isDLL: true).build()], as: "portable-" + name, in: folder)
        #expect(try await ZipPackage.contents(of: zip, in: staging) == nil)
        #expect(try await ZipPackage.unpack(zip, in: staging) == nil)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)

    // An installer of no known kind says what it is in its description.
    var custom = SyntheticPE()
    custom.versionStrings = ["FileDescription": "Shape it Level 2 PPlus Setup"]
    let described = try makeZip(["Shape it.exe": custom.build()], as: "described", in: folder)
    #expect(try await ZipPackage.contents(of: described, in: staging)?.setupPath == "Shape it.exe")
    var uninstaller = SyntheticPE()
    uninstaller.versionStrings = ["FileDescription": "Setup/Uninstall"]
    #expect(!ZipPackage.isInstaller("tool.exe", try InstallerAnalyzer.analyze(fileAt: try {
        let file = folder.url.appendingPathComponent("tool.exe")
        try uninstaller.build().write(to: file)
        return file
    }())))
}

@Test func theSameProgramTwiceIsTheOneWithMoreAroundIt() throws {
    // Encarta 2009: the encyclopedia and its Kids edition share the same ENCARTA.EXE.
    let folder = try TemporaryFolder()
    try folder.write("Microsoft Encarta/Encarta Kids 2009/ENCARTA.EXE", SyntheticPE())
    try folder.write("Microsoft Encarta/Encarta Premium DVD 2009/ENCARTA.EXE", SyntheticPE())
    try folder.write("Microsoft Encarta/Encarta Premium DVD 2009/articles.dat", Data(count: 4096))
    let report = try ProgramAnalyzer.analyze(folderAt: folder.url.appendingPathComponent("Microsoft Encarta"))
    #expect(report.mainExecutable == "Encarta Premium DVD 2009/ENCARTA.EXE")
}

/// A 64-bit Mach-O with just an LC_UUID, and `tail` where a signature would be.
private func machO(uuid: UInt8, tail: [UInt8]) -> Data {
    var bytes = le32(0xFEED_FACF) + le32(0x0100_000C) + le32(0) + le32(2) + le32(1) + le32(24) + le32(0) + le32(0)
    bytes += le32(0x1B) + le32(24) + [UInt8](repeating: uuid, count: 16)
    return Data(bytes + tail)
}

@Test func theSameLauncherBuildSignedAgainIsNotNewer() throws {
    // Signing the app rewrites its launcher: the bytes differ, the linker's UUID does not.
    let folder = try TemporaryFolder()
    let wrapper = Wrapper(url: folder.url.appendingPathComponent("P.app"))
    let vitrals = folder.url.appendingPathComponent("vitral-launcher"), other = folder.url.appendingPathComponent("other")
    try machO(uuid: 7, tail: [1, 2, 3]).write(to: vitrals)
    try machO(uuid: 9, tail: [1, 2, 3]).write(to: other)
    let script = folder.url.appendingPathComponent("script")
    try Data("#!/bin/sh\n".utf8).write(to: script)
    let manifest = WrapperManifest(name: "P", program: "p.exe", engine: "x", settings: LaunchSettings())
    try wrapper.write(manifest: manifest, icns: nil, launcher: script, bundleIdentifier: "test.p")
    // As if signed: same build, other bytes (codesign would not sign these made-up files).
    try machO(uuid: 7, tail: [4, 5, 6, 7]).write(to: wrapper.launcherURL)

    #expect(MachO.uuids(of: vitrals) == MachO.uuids(of: wrapper.launcherURL))
    #expect(try !wrapper.updateLauncher(from: vitrals))
    #expect(MachO.uuids(of: other) != MachO.uuids(of: wrapper.launcherURL))
    #expect(MachO.uuids(of: folder.url.appendingPathComponent("nothing")) == nil)
    // The real launcher, built by these tests' package.
    let built = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/debug/vitral-launcher")
    if FileManager.default.fileExists(atPath: built.path) { #expect(MachO.uuids(of: built)?.count == 1) }
}
