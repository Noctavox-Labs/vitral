import Foundation
import Testing
@testable import VitralKit

/// Builds `<name>.tar.xz` with the given files under `root/` and returns it with its SHA-256.
func makeArchive(in folder: TemporaryFolder, name: String, root: String, files: [String: String]) throws -> (URL, String) {
    let staging = folder.url.appendingPathComponent("staging-\(name)")
    for (path, text) in files {
        let file = staging.appendingPathComponent(root).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
    let archive = folder.url.appendingPathComponent("\(name).tar.xz")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments = ["-cJf", archive.path, "-C", staging.path, root]
    try process.run()
    process.waitUntilExit()
    return (archive, try ComponentInstaller.sha256(of: archive))
}

func component(_ archive: URL, sha256: String, root: String, members: [String] = []) -> Component {
    Component(
        id: "test-\(archive.deletingPathExtension().deletingPathExtension().lastPathComponent)",
        name: "Test", url: archive, sha256: sha256, bytes: 0, archiveRoot: root, members: members,
        license: "MIT", source: URL(string: "https://example.com")!
    )
}

/// An installer whose "download" is the local file itself.
func localInstaller(_ folder: TemporaryFolder) -> ComponentInstaller {
    ComponentInstaller(home: VitralHome(url: folder.url.appendingPathComponent("home")), fetch: { url, progress in
        progress(1)
        return url
    })
}

@Test func sha256MatchesKnownValue() throws {
    let folder = try TemporaryFolder()
    try folder.write("abc.txt", Data("abc".utf8))
    #expect(try ComponentInstaller.sha256(of: folder.url.appendingPathComponent("abc.txt"))
        == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

@Test func installsVerifiedComponent() async throws {
    let folder = try TemporaryFolder()
    let (archive, sum) = try makeArchive(in: folder, name: "engine", root: "wswine.bundle",
                                         files: ["bin/wine": "#!/bin/sh", "lib/wine/x.so": "so"])
    let installer = localInstaller(folder)
    let piece = component(archive, sha256: sum, root: "wswine.bundle")

    #expect(!installer.isInstalled(piece))
    let installed = try await installer.install(piece)
    #expect(installer.isInstalled(piece))
    #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent("bin/wine").path))
    #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent("lib/wine/x.so").path))
    // No leftovers from the work folder.
    let names = try FileManager.default.contentsOfDirectory(atPath: installer.home.components.path)
    #expect(names == [piece.id])
}

@Test func reportsProgressAndDownloadsFromFileURL() async throws {
    let folder = try TemporaryFolder()
    let (archive, sum) = try makeArchive(in: folder, name: "net", root: "r", files: ["a": "a"])
    // The real downloader, pointed at a local file.
    let installer = ComponentInstaller(home: VitralHome(url: folder.url.appendingPathComponent("home")))
    let reports = Reports()
    try await installer.install(component(archive, sha256: sum, root: "r")) { reports.add($0) }
    #expect(installer.isInstalled(component(archive, sha256: sum, root: "r")))
    #expect(reports.values.allSatisfy { (0 ... 1).contains($0) })
}

final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func add(_ value: Double) { lock.withLock { stored.append(value) } }
    var values: [Double] { lock.withLock { stored } }
}

@Test func rejectsWrongChecksumAndInstallsNothing() async throws {
    let folder = try TemporaryFolder()
    let (archive, _) = try makeArchive(in: folder, name: "evil", root: "root", files: ["bin/wine": "x"])
    let installer = localInstaller(folder)
    let piece = component(archive, sha256: String(repeating: "0", count: 64), root: "root")

    await #expect(throws: ComponentError.self) { try await installer.install(piece) }
    #expect(!installer.isInstalled(piece))
    #expect(!FileManager.default.fileExists(atPath: installer.home.folder(of: piece).path))
}

@Test func extractsOnlyRequestedMembers() async throws {
    let folder = try TemporaryFolder()
    let (archive, sum) = try makeArchive(in: folder, name: "libs", root: "Wine.app/lib", files: [
        "libfreetype.6.dylib": "ft", "libSDL2.dylib": "sdl", "wine/x86_64-unix/ntdll.so": "big",
    ])
    let installer = localInstaller(folder)
    let piece = component(archive, sha256: sum, root: "Wine.app/lib", members: ["Wine.app/lib/*.dylib"])

    let installed = try await installer.install(piece)
    let names = try FileManager.default.contentsOfDirectory(atPath: installed.path).filter { !$0.hasPrefix(".") }
    #expect(names.sorted() == ["libSDL2.dylib", "libfreetype.6.dylib"])
}

@Test func reportsMissingArchiveRoot() async throws {
    let folder = try TemporaryFolder()
    let (archive, sum) = try makeArchive(in: folder, name: "odd", root: "other", files: ["a": "a"])
    let installer = localInstaller(folder)
    await #expect(throws: ComponentError.missingArchiveRoot("wswine.bundle")) {
        try await installer.install(component(archive, sha256: sum, root: "wswine.bundle"))
    }
}

@Test func reinstallsWhenPinnedChecksumChanges() async throws {
    let folder = try TemporaryFolder()
    let (old, oldSum) = try makeArchive(in: folder, name: "v1", root: "r", files: ["version": "1"])
    let (new, newSum) = try makeArchive(in: folder, name: "v2", root: "r", files: ["version": "2"])
    let installer = localInstaller(folder)
    var piece = component(old, sha256: oldSum, root: "r")
    try await installer.install(piece)

    piece = Component(id: piece.id, name: piece.name, url: new, sha256: newSum, bytes: 0,
                      archiveRoot: "r", license: "MIT", source: piece.source)
    #expect(!installer.isInstalled(piece))
    let installed = try await installer.install(piece)
    #expect(try String(contentsOf: installed.appendingPathComponent("version"), encoding: .utf8) == "2")
}

@Test func catalogPinsOfficialHTTPSDownloads() {
    for engine in EngineCatalog.all {
        for piece in engine.components {
            #expect(piece.url.scheme == "https", "\(piece.id)")
            #expect(piece.url.host == "github.com", "\(piece.id)")
            #expect(piece.sha256.count == 64 && piece.sha256.allSatisfy(\.isHexDigit), "\(piece.id)")
            #expect(piece.source.scheme == "https", "\(piece.id)")
        }
    }
    #expect(EngineCatalog.engine(id: EngineCatalog.default.id) != nil)
}

@Test func engineEnvironmentPointsAtItsLibraries() {
    let home = VitralHome(url: URL(fileURLWithPath: "/tmp/vitral-home"))
    let installed = InstalledEngine(engine: EngineCatalog.crossover24, home: home)
    let environment = installed.environment(prefix: URL(fileURLWithPath: "/tmp/prefix"))
    #expect(environment["WINEPREFIX"] == "/tmp/prefix")
    #expect(environment["DYLD_FALLBACK_LIBRARY_PATH"] == "/tmp/vitral-home/Components/libraries-gcenx-11.0_1:/usr/lib")
    #expect(installed.wine.path == "/tmp/vitral-home/Components/wine-cx24.0.7_7/bin/wine")
}

// MARK: System check

private func mac(
    chip: String = "Apple M1",
    appleSilicon: Bool = true,
    memoryGB: UInt64 = 16,
    macOS: Int = 15,
    freeGB: Int64? = 100,
    rosetta: Bool = true
) -> MacInfo {
    MacInfo(chip: chip, isAppleSilicon: appleSilicon, memoryBytes: memoryGB << 30,
            macOSVersion: OperatingSystemVersion(majorVersion: macOS, minorVersion: 0, patchVersion: 0),
            freeBytes: freeGB.map { $0 * 1_000_000_000 }, hasRosetta: rosetta)
}

private func status(_ requirements: [Requirement], _ kind: Requirement.Kind) -> Requirement.Status? {
    requirements.first { $0.kind == kind }?.status
}

@Test func readyMacNeedsNothing() {
    let list = SystemCheck.requirements(mac: mac(), engineInstalled: true, language: .english)
    #expect(list.allSatisfy { $0.status == .ok })
    #expect(list.map(\.kind) == [.appleSilicon, .macOS, .memory, .rosetta, .diskSpace, .engine])
}

@Test func freshMacCanBeFixedByVitral() {
    let list = SystemCheck.requirements(mac: mac(rosetta: false), engineInstalled: false, language: .english)
    #expect(status(list, .rosetta) == .fixable)
    #expect(status(list, .engine) == .fixable)
    #expect(!list.contains { $0.status == .blocking })
}

@Test func blocksWhatVitralCannotFix() {
    let old = SystemCheck.requirements(mac: mac(macOS: 13), engineInstalled: true, language: .english)
    #expect(status(old, .macOS) == .blocking)
    let full = SystemCheck.requirements(mac: mac(freeGB: 1), engineInstalled: true, language: .english)
    #expect(status(full, .diskSpace) == .blocking)
}

@Test func warnsAboutIntelLowMemoryAndMacOSWithoutRosetta() {
    let intel = SystemCheck.requirements(mac: mac(chip: "Intel Core i7", appleSilicon: false), engineInstalled: true, language: .english)
    #expect(status(intel, .appleSilicon) == .warning)
    #expect(SystemCheck.requirements(mac: mac(memoryGB: 8), engineInstalled: true, language: .english)
        .first { $0.kind == .memory }?.status == .ok)
    #expect(status(SystemCheck.requirements(mac: mac(memoryGB: 4), engineInstalled: true, language: .english), .memory) == .warning)
    #expect(status(SystemCheck.requirements(mac: mac(macOS: 28), engineInstalled: true, language: .english), .macOS) == .warning)
}

@Test func describesWhatItFound() {
    let english = SystemCheck.requirements(mac: mac(rosetta: false), engineInstalled: false, language: .english)
    #expect(english.first { $0.kind == .rosetta }?.detail == "Missing")
    let spanish = SystemCheck.requirements(mac: mac(), engineInstalled: true, language: .spanish)
    #expect(spanish.first { $0.kind == .memory }?.detail == "16 GB")
    #expect(spanish.first { $0.kind == .rosetta }?.detail == "Instalada")
    #expect(spanish.first { $0.kind == .engine }?.detail == EngineCatalog.default.name)
}
