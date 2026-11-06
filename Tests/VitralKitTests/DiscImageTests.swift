import Foundation
import Testing
@testable import VitralKit

/// A new empty folder for a test.
private func folder(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vitral-disc-\(name)-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, _ name: String, in root: URL) throws {
    let url = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

/// An ISO 9660 + Joliet image of `source`, made by macOS itself.
private func makeISO(of source: URL, isoLabel: String, jolietLabel: String, in folder: URL) throws -> URL {
    let iso = folder.appendingPathComponent("disco.iso")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    process.arguments = ["makehybrid", "-iso", "-joliet", "-iso-volume-name", isoLabel, "-joliet-volume-name", jolietLabel,
                         "-o", iso.path, source.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
    return iso
}

// MARK: Choosing the installer

@Test func autorunThatOpensASetupWins() throws {
    let root = try folder("autorun")
    defer { try? FileManager.default.removeItem(at: root) }
    try write("[AutoRun]\r\nopen=Bin\\Instalar.EXE /autorun\r\nicon=Bin\\Instalar.EXE\r\n", "AUTORUN.INF", in: root)
    try write("MZ", "Bin/instalar.exe", in: root)
    try write("MZ", "setup.exe", in: root)
    #expect(DiscImage.setupProgram(in: root)?.lastPathComponent == "instalar.exe")
}

@Test func setupBeforeAnAutorunMenu() throws {
    // Encarta 2009: autorun.inf opens a menu (Autorun.exe); SETUP.EXE installs.
    let root = try folder("menu")
    defer { try? FileManager.default.removeItem(at: root) }
    try write("[autorun]\nopen = Autorun.exe\nicon = Autorun.exe\n", "AUTORUN.INF", in: root)
    try write("MZ", "AUTORUN.EXE", in: root)
    try write("MZ", "SETUP.EXE", in: root)
    try write("MZ", "SETUPREQ.EXE", in: root)
    try write("x", "E09AXLRD.MSI", in: root)
    #expect(DiscImage.setupProgram(in: root)?.lastPathComponent == "SETUP.EXE")
}

@Test func theOnlyPackageOrTheMenuOrTheOnlyProgram() throws {
    let root = try folder("rules")
    defer { try? FileManager.default.removeItem(at: root) }
    try write("x", "Programa.msi", in: root)
    try write("MZ", "Leeme.exe", in: root)
    try write("MZ", "Otro.exe", in: root)
    #expect(DiscImage.setupProgram(in: root)?.lastPathComponent == "Programa.msi")

    try FileManager.default.removeItem(at: root.appendingPathComponent("Programa.msi"))
    #expect(DiscImage.setupProgram(in: root) == nil)
    try write("[autorun]\nopen=\"Leeme.exe\"\n", "autorun.inf", in: root)
    #expect(DiscImage.setupProgram(in: root)?.lastPathComponent == "Leeme.exe")

    try FileManager.default.removeItem(at: root.appendingPathComponent("autorun.inf"))
    try FileManager.default.removeItem(at: root.appendingPathComponent("Otro.exe"))
    #expect(DiscImage.setupProgram(in: root)?.lastPathComponent == "Leeme.exe")
}

@Test func autorunCannotLeaveTheDisc() throws {
    let root = try folder("escape")
    defer { try? FileManager.default.removeItem(at: root) }
    try write("[autorun]\nopen=..\\..\\setup.exe\n", "autorun.inf", in: root)
    #expect(DiscImage.setupProgram(in: root) == nil)
}

// MARK: Reading the image

@Test func notADisc() {
    #expect(!DiscImage.isDiscImage(Data(repeating: 0, count: 64 * 1024)))
    #expect(!DiscImage.isDiscImage(Data("CD001".utf8)))
    #expect(DiscImage.label(of: Data(repeating: 0, count: 64 * 1024)) == nil)
}

/// Makes a real disc image, mounts it hidden, shows it to a prefix as a CD drive and ejects it.
@Test func mountsAndAttachesARealImage() async throws {
    let work = try folder("iso")
    defer { try? FileManager.default.removeItem(at: work) }
    let source = work.appendingPathComponent("contenido")
    try write("[autorun]\nopen=autorun.exe\n", "AUTORUN.INF", in: source)
    try write("MZ", "AUTORUN.EXE", in: source)
    try write("MZ", "SETUP.EXE", in: source)
    let iso = try makeISO(of: source, isoLabel: "PRUEBA_1", jolietLabel: "Prueba Vitral", in: work)

    let report = try InstallerAnalyzer.analyze(fileAt: iso)
    #expect(report.kind == .discImage)
    // Windows shows the Joliet name.
    #expect(report.discLabel == "Prueba Vitral")
    #expect(ProgramInstaller.needsInstaller(iso, report))

    let staging = work.appendingPathComponent("Staging")
    let contents = try await DiscImage.contents(of: iso, in: staging)
    #expect(contents.setupPath == "SETUP.EXE")
    #expect(contents.label == "Prueba Vitral")
    // Nothing left mounted or behind.
    #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)

    let disc = try await DiscImage.mount(iso, in: staging)
    defer { disc.eject() }
    #expect(disc.setupProgram?.lastPathComponent == "SETUP.EXE")
    // D: is taken (Wine gives mounted volumes a letter); the disc goes to E:.
    let prefix = work.appendingPathComponent("prefix")
    let devices = prefix.appendingPathComponent("dosdevices")
    try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: devices.appendingPathComponent("d:").path, withDestinationPath: "/Volumes/Gone")
    let letter = try disc.attach(to: prefix)
    #expect(letter == "e")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: devices.appendingPathComponent("e:").path) == disc.mountPoint.path)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: devices.appendingPathComponent("e::").path)
        == disc.device.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk"))
    #expect(DiscImage.driveType(letter) == .string(#"HKEY_LOCAL_MACHINE\Software\Wine\Drives"#, "e:", "cdrom"))
    DiscImage.detach(letter: letter, from: prefix)
    #expect(try FileManager.default.contentsOfDirectory(atPath: devices.path) == ["d:"])

    disc.eject()
    #expect(!FileManager.default.fileExists(atPath: disc.mountPoint.path))
}
