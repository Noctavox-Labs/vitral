import Foundation
import Testing
@testable import VitralKit

// MARK: - Synthetic executables

/// Builds a minimal but well-formed MZ + PE header.
func makePE(
    machine: UInt16 = 0x014C,
    magic: UInt16 = 0x010B,
    subsystem: UInt16 = 2,
    characteristics: UInt16 = 0x0102,
    sections: [String] = [".text", ".rsrc"],
    payload: [UInt8] = []
) -> Data {
    var bytes = [UInt8](repeating: 0, count: 0x40)
    bytes[0] = 0x4D; bytes[1] = 0x5A                          // "MZ"
    bytes.replaceSubrange(0x3C ..< 0x40, with: le32(0x40))    // e_lfanew
    bytes += Array("PE".utf8) + [0, 0]

    let optionalSize: UInt16 = magic == 0x010B ? 224 : 240
    bytes += le16(machine) + le16(UInt16(sections.count)) + le32(0) + le32(0) + le32(0)
    bytes += le16(optionalSize) + le16(characteristics)

    var optional = [UInt8](repeating: 0, count: Int(optionalSize))
    optional.replaceSubrange(0 ..< 2, with: le16(magic))
    optional.replaceSubrange(68 ..< 70, with: le16(subsystem))
    bytes += optional

    for name in sections {
        var header = [UInt8](repeating: 0, count: 40)
        let raw = Array(name.utf8.prefix(8))
        header.replaceSubrange(0 ..< raw.count, with: raw)
        bytes += header
    }
    return Data(bytes + payload)
}

func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
func le32(_ value: UInt32) -> [UInt8] { (0 ..< 4).map { UInt8((value >> (8 * $0)) & 0xFF) } }

// MARK: - Executable headers

@Test func parses32BitGraphicalProgram() throws {
    let info = try #require(PortableExecutable.parse(makePE()))
    #expect(info.format == .pe32)
    #expect(info.bits == 32)
    #expect(info.machine == .x86)
    #expect(info.subsystem == .gui)
    #expect(info.isDLL == false)
    #expect(info.sectionNames == [".text", ".rsrc"])
}

@Test func parses64BitConsoleProgram() throws {
    let info = try #require(PortableExecutable.parse(makePE(machine: 0x8664, magic: 0x020B, subsystem: 3)))
    #expect(info.format == .pe32Plus)
    #expect(info.bits == 64)
    #expect(info.machine == .x64)
    #expect(info.subsystem == .console)
}

@Test func recognisesDLLAndARM64() throws {
    let info = try #require(PortableExecutable.parse(makePE(machine: 0xAA64, magic: 0x020B, characteristics: 0x2102)))
    #expect(info.isDLL)
    #expect(info.machine == .arm64)
}

@Test func recognises16BitWindows() throws {
    var bytes = [UInt8](repeating: 0, count: 0x80)
    bytes[0] = 0x4D; bytes[1] = 0x5A
    bytes.replaceSubrange(0x3C ..< 0x40, with: le32(0x40))
    bytes[0x40] = 0x4E; bytes[0x41] = 0x45                    // "NE"
    let info = try #require(PortableExecutable.parse(Data(bytes)))
    #expect(info.format == .windows16)
    #expect(info.bits == 16)
}

@Test func rejectsNonExecutables() {
    #expect(PortableExecutable.parse(Data("hello".utf8)) == nil)
    #expect(PortableExecutable.parse(Data()) == nil)
}

@Test func survivesTruncatedHeaders() throws {
    let truncated = makePE().prefix(0x50)
    let info = try #require(PortableExecutable.parse(truncated))
    #expect(info.format == .dos)
}

// MARK: - Installer kinds

@Test func detectsInnoSetupWithVersion() {
    let data = makePE(payload: Array("....Inno Setup Setup Data (5.6.0)....".utf8))
    let (kind, version) = InstallerAnalyzer.classify(data)
    #expect(kind == .innoSetup)
    #expect(version == "5.6.0")
}

@Test func detectsInnoSetupUnicodeMarker() {
    let data = makePE(payload: Array("Inno Setup Setup Data (6.2.2) (u)".utf8))
    #expect(InstallerAnalyzer.classify(data) == (.innoSetup, "6.2.2"))
}

@Test func detectsNSISWithVersion() {
    let data = makePE(payload: Array("NullsoftInst ... Nullsoft Install System v3.08 ...".utf8))
    #expect(InstallerAnalyzer.classify(data) == (.nsis, "3.08"))
}

@Test func detectsWixBurnBySection() {
    let data = makePE(sections: [".text", ".wixburn", ".rsrc"])
    #expect(InstallerAnalyzer.classify(data).0 == .wixBurn)
}

@Test func detectsMSIOnlyWithMsiExtension() {
    let ole = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0, 0])
    #expect(InstallerAnalyzer.classify(ole, fileExtension: "MSI").0 == .msi)
    #expect(InstallerAnalyzer.classify(ole, fileExtension: "doc").0 == .unknown)
}

@Test func detectsZip() {
    #expect(InstallerAnalyzer.classify(Data([0x50, 0x4B, 0x03, 0x04, 0x14])).0 == .zip)
}

@Test func plainProgramIsExecutable() {
    #expect(InstallerAnalyzer.classify(makePE()).0 == .executable)
}

@Test func garbageIsUnknown() {
    #expect(InstallerAnalyzer.classify(Data("not a program".utf8)).0 == .unknown)
}

// MARK: - Files on disk

@Test func findsInnoSetupDataFilesNextToInstaller() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vitral-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let installer = folder.appendingPathComponent("My App Setup.exe")
    try makePE(payload: Array("Inno Setup Setup Data (5.6.0)".utf8)).write(to: installer)
    for name in ["My App Setup-1a.bin", "My App Setup-1b.bin", "Other-1a.bin", "notes.txt"] {
        try Data([0]).write(to: folder.appendingPathComponent(name))
    }

    let report = try InstallerAnalyzer.analyze(fileAt: installer)
    #expect(report.kind == .innoSetup)
    #expect(report.fileName == "My App Setup.exe")
    #expect(report.executable?.bits == 32)
    #expect(report.companionFiles == ["My App Setup-1a.bin", "My App Setup-1b.bin"])
}

@Test func reportsMissingFile() {
    let missing = URL(fileURLWithPath: "/nonexistent/vitral/setup.exe")
    #expect(throws: InstallerAnalyzerError.notFound) {
        try InstallerAnalyzer.analyze(fileAt: missing)
    }
}

// MARK: - Language

@Test func translatesBothWays() {
    #expect(tr("Hola", "Hello", .spanish) == "Hola")
    #expect(tr("Hola", "Hello", .english) == "Hello")
}
