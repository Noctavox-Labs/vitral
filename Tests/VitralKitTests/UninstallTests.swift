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

    // No app uses CrossOver 24: its Wine goes; the shared libraries stay (the default engine uses them).
    #expect(EngineUsage.unusedComponents(home: home, apps: apps).map(\.id) == [EngineCatalog.crossover24.wine.id])

    _ = try makeApp(folder, name: "Old", installer: nil, engine: EngineCatalog.crossover24.id)
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
