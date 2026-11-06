import Foundation
import Testing
@testable import VitralKit

/// A Vitral app in `folder/apps`, with a link in its prefix to a folder outside (like the links
/// to the Mac's Documents).
private func makeApp(_ folder: TemporaryFolder, name: String, installer: String?, engine: String = "cx-test") throws -> URL {
    let app = folder.url.appendingPathComponent("apps/\(name).app")
    let launcher = folder.url.appendingPathComponent("launcher-binary")
    if !FileManager.default.fileExists(atPath: launcher.path) { try Data("#!/bin/sh\n".utf8).write(to: launcher) }
    let manifest = WrapperManifest(name: "Program", program: "Program Files/P/p.exe", engine: engine,
                                   settings: LaunchSettings(), installer: installer)
    try Wrapper(url: app).write(manifest: manifest, icns: nil, launcher: launcher, bundleIdentifier: "test.\(name)")
    let documents = Wrapper(url: app).prefix.appendingPathComponent("drive_c/users/crossover/Documents")
    try FileManager.default.createDirectory(at: documents.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: documents, withDestinationURL: folder.url.appendingPathComponent("My Documents"))
    return app
}

@Test func uninstallTrashesTheAppAndItsLogsButNotTheLinkedFolders() async throws {
    let folder = try TemporaryFolder()
    try folder.write("My Documents/essay.txt", Data("mine".utf8))
    let logs = folder.url.appendingPathComponent("logs")
    let app = try makeApp(folder, name: "aTube Catcher 2", installer: "aTube-Setup.exe")
    for log in ["aTube Catcher 2.log", "aTube Catcher 2 (anterior).log", "Instalación - aTube-Setup.log", "Other.log"] {
        try folder.write("logs/\(log)", Data())
    }

    let trashed = Locked<[URL]>([])
    let uninstaller = Uninstaller(home: VitralHome(url: folder.url.appendingPathComponent("home")), logs: logs) { url in
        trashed.value.append(url)
        try FileManager.default.removeItem(at: url)   // removeItem does not follow links either
    }
    try await uninstaller.uninstall(app)

    #expect(trashed.value.map(\.lastPathComponent) ==
            ["aTube Catcher 2.app", "aTube Catcher 2.log", "aTube Catcher 2 (anterior).log", "Instalación - aTube-Setup.log"])
    #expect(!FileManager.default.fileExists(atPath: app.path))
    #expect(FileManager.default.fileExists(atPath: logs.appendingPathComponent("Other.log").path))
    #expect(try String(contentsOf: folder.url.appendingPathComponent("My Documents/essay.txt"), encoding: .utf8) == "mine")
}

@Test func keepsTheInstallLogAnotherAppShares() throws {
    let folder = try TemporaryFolder()
    let logs = folder.url.appendingPathComponent("logs")
    let first = try makeApp(folder, name: "aTube Catcher", installer: "aTube-Setup.exe")
    _ = try makeApp(folder, name: "aTube Catcher 2", installer: "aTube-Setup.exe")
    try folder.write("logs/Instalación - aTube-Setup.log", Data())
    try folder.write("logs/aTube Catcher.log", Data())

    let items = try Uninstaller(logs: logs).items(for: first)
    #expect(items.map(\.lastPathComponent) == ["aTube Catcher.app", "aTube Catcher.log"])
}

@Test func refusesWhatIsNotAVitralApp() throws {
    let folder = try TemporaryFolder()
    try folder.write("apps/Safari.app/Contents/Info.plist", Data())
    #expect(throws: WrapperError.self) {
        try Uninstaller(logs: folder.url).items(for: folder.url.appendingPathComponent("apps/Safari.app"))
    }
}

@Test func findsEngineComponentsNoAppUses() throws {
    let folder = try TemporaryFolder()
    let home = VitralHome(url: folder.url.appendingPathComponent("home"))
    // Pretend every catalog component is installed.
    for component in EngineCatalog.all.flatMap(\.components) {
        let receipt = home.folder(of: component).appendingPathComponent(ComponentInstaller.receiptName)
        try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(component).write(to: receipt)
    }
    let apps = folder.url.appendingPathComponent("apps")
    try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)

    // No app uses CrossOver 24 or the first build of 26.3: their Wine goes; the shared libraries
    // stay (the default engine uses them).
    #expect(Set(EngineUsage.unusedComponents(home: home, apps: apps).map(\.id))
            == [EngineCatalog.crossover24.wine.id, EngineCatalog.crossover26First.wine.id])

    _ = try makeApp(folder, name: "Old", installer: nil, engine: EngineCatalog.crossover24.id)
    _ = try makeApp(folder, name: "Older build", installer: nil, engine: EngineCatalog.crossover26First.id)
    #expect(EngineUsage.unusedComponents(home: home, apps: apps).isEmpty)
}

/// A value shared between threads.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

// MARK: Windows outside the app (0.1.1)

/// An app made before 0.1.1: Windows inside it, with a link to a folder outside.
private func makeOldApp(_ folder: TemporaryFolder, name: String) throws -> URL {
    let app = try makeApp(folder, name: name, installer: nil)
    try folder.write("apps/\(name).app/Contents/SharedSupport/prefix/drive_c/Program Files/P/p.exe", Data("MZ".utf8))
    return app
}

@Test func signsTheAppsItWrites() throws {
    let folder = try TemporaryFolder()
    let launcher = folder.url.appendingPathComponent("launcher-binary")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: launcher)
    let wrapper = Wrapper(url: folder.url.appendingPathComponent("P.app"))
    try wrapper.write(manifest: WrapperManifest(name: "P", program: "p.exe", engine: "x", settings: LaunchSettings(), prefix: "p"),
                      icns: nil, launcher: launcher, bundleIdentifier: "test.p")
    #expect(wrapper.hasValidSignature)
    // Anything changed inside afterwards breaks the seal, which is why Windows lives outside.
    try Data("{}".utf8).write(to: wrapper.contents.appendingPathComponent("Resources/extra.json"))
    #expect(!wrapper.hasValidSignature)
}

@Test func movesWindowsOutOfAnOlderApp() throws {
    let folder = try TemporaryFolder()
    try folder.write("My Documents/essay.txt", Data("mine".utf8))
    let home = VitralHome(url: folder.url.appendingPathComponent("home"))
    let app = try makeOldApp(folder, name: "Old")
    let wrapper = Wrapper(url: app)
    #expect(!wrapper.hasValidSignature)   // the link to the Mac's folder cannot be sealed

    #expect(try wrapper.moveEmbeddedPrefix(to: home))
    let moved = home.prefixes.appendingPathComponent("test.Old")
    #expect(try wrapper.readManifest().prefix == "test.Old")
    #expect(wrapper.prefix(in: home) == moved)
    #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("drive_c/Program Files/P/p.exe").path))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: moved.appendingPathComponent("drive_c/users/crossover/Documents").path)
            == folder.url.appendingPathComponent("My Documents").path)
    #expect(!FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/SharedSupport").path))
    #expect(wrapper.hasValidSignature)
    #expect(try !wrapper.moveEmbeddedPrefix(to: home))
}

@Test func uninstallTrashesWindowsOutsideTheAppToo() async throws {
    let folder = try TemporaryFolder()
    try folder.write("My Documents/essay.txt", Data("mine".utf8))
    let home = VitralHome(url: folder.url.appendingPathComponent("home"))
    let app = try makeOldApp(folder, name: "New")
    try Wrapper(url: app).moveEmbeddedPrefix(to: home)

    let trashed = Locked<[URL]>([])
    try await Uninstaller(home: home, logs: folder.url.appendingPathComponent("logs")) { url in
        trashed.value.append(url)
        try FileManager.default.removeItem(at: url)
    }.uninstall(app)
    #expect(trashed.value.map(\.lastPathComponent) == ["New.app", "test.New"])
    #expect(try String(contentsOf: folder.url.appendingPathComponent("My Documents/essay.txt"), encoding: .utf8) == "mine")
}

// MARK: Force Quit

@Test func forceQuitEndsAHungProgramEvenWithoutTheEngine() async throws {
    let folder = try TemporaryFolder()
    let prefix = folder.url.appendingPathComponent("prefix")
    try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
    // Stands in for a hung Windows program: Wine names its processes after the Windows path,
    // and they carry their WINEPREFIX. macOS hides the environment of its own programs, so it is
    // a copy of `sleep` signed again (as Wine is).
    let sleep = folder.url.appendingPathComponent("sleep")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: sleep)
    let sign = Process()
    sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    sign.arguments = ["-f", "-s", "-", sleep.path]
    sign.standardError = FileHandle.nullDevice
    #expect(try await WineSession.wait(for: sign) == 0)
    let hung = Process()
    hung.executableURL = URL(fileURLWithPath: "/bin/bash")
    hung.arguments = ["-c", #"exec -a 'C:\Program Files\Hung\hung.exe' "$0" 60"#, sleep.path]
    hung.environment = ["WINEPREFIX": prefix.path]
    // Not waitUntilExit(): it waits on the run loop of the thread that started the process, and
    // after an await the test can be on another one, where the news never arrives (it hung).
    let (exits, exited) = AsyncStream<Process.TerminationReason>.makeStream()
    hung.terminationHandler = { exited.yield($0.terminationReason); exited.finish() }
    try hung.run()
    defer { if hung.isRunning { kill(hung.processIdentifier, SIGKILL) } }

    var listed = false
    for _ in 0..<60 where !listed {
        listed = WineProcesses.list(prefix: prefix).contains { $0.name == "hung.exe" }
        if !listed { try await Task.sleep(for: .milliseconds(50)) }
    }
    #expect(listed)
    #expect(WineProcesses.all().contains { $0.prefix == prefix.standardizedFileURL.path && $0.entry.pid == hung.processIdentifier })

    // No engine in this home: `wineserver -k` cannot run, so what is left gets SIGKILL.
    let home = VitralHome(url: folder.url.appendingPathComponent("home"))
    let session = WineSession(engine: InstalledEngine(engine: EngineCatalog.default, home: home), prefix: prefix)
    #expect(await session.forceQuit(timeout: 0.5))
    var reasons = exits.makeAsyncIterator()
    #expect(await reasons.next() == .uncaughtSignal)
    #expect(WineProcesses.list(prefix: prefix).isEmpty)
}
