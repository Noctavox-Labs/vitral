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
    // A real process that is not a Windows program keeps its own name.
    #expect(WineWindows.windowsFileName(of: getpid()) == nil)
}
