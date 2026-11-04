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
    ComponentInstaller(home: VitralHome(url: folder.url.appendingPathComponent("home")), fetch: { $0 })
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
