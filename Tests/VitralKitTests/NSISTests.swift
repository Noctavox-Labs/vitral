import Compression
import Foundation
import Testing
@testable import VitralKit

/// A fake NSIS installer: an "MZ" stub padded to 1024 bytes, NSIS's first header, and the script
/// header holding `texts` in UTF-16, compressed with raw DEFLATE (as electron-builder builds it)
/// or stored plainly.
func makeNSIS(texts: [String], compressed: Bool = true) -> Data {
    var header = [UInt8](repeating: 0, count: 64)   // stands for the binary part of the header
    for text in texts { header += text.utf16.flatMap(le16) + [0, 0] }
    let body = compressed ? deflate(header) : header

    var bytes = [UInt8](repeating: 0, count: 1024)
    bytes[0] = 0x4D; bytes[1] = 0x5A
    bytes += le32(0) + [0xEF, 0xBE, 0xAD, 0xDE] + Array("NullsoftInst".utf8)
    bytes += le32(UInt32(header.count)) + le32(0)
    bytes += le32(UInt32(body.count) | (compressed ? 0x8000_0000 : 0)) + body
    return Data(bytes)
}

func deflate(_ input: [UInt8]) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: input.count + 1024)
    let size = compression_encode_buffer(&output, output.count, input, input.count, nil, COMPRESSION_ZLIB)
    return Array(output.prefix(size))
}

/// Texts from the script of aTube Catcher 26.11.3 (electron-builder with its PowerShell check).
let electronBuilderTexts = [
    "\\app-64.7z",
    "\\nsis7z.dll",
    "\\WindowsPowerShell\\v1.0\\powershell.exe",
    #"" -C "if ((Get-CimInstance -ClassName Win32_Process | ? {$_.Path -and $_.Path.StartsWith('"#,
    "aTube Catcher is running.",
]

@Test func readsElectronBuilderScript() throws {
    let facts = try #require(NSISScript.facts(in: makeNSIS(texts: electronBuilderTexts), scanLimit: 1 << 20))
    #expect(facts.builder == .electronBuilder)
    #expect(facts.runsPowerShell)
    // aTube Catcher's installer is 32-bit (all NSIS stubs are); the program it packs is 64-bit.
    #expect(facts.programBits == 64)
    let only32 = electronBuilderTexts.map { $0 == "\\app-64.7z" ? "\\app-32.7z" : $0 }
    #expect(try #require(NSISScript.facts(in: makeNSIS(texts: only32), scanLimit: 1 << 20)).programBits == 32)

    let stored = try #require(NSISScript.facts(in: makeNSIS(texts: electronBuilderTexts, compressed: false), scanLimit: 1 << 20))
    #expect(stored == facts)
}

@Test func analyzerReportsElectronBuilderAndItsRecipe() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vitral-\(UUID().uuidString)-Setup.exe")
    try makeNSIS(texts: electronBuilderTexts).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let report = try InstallerAnalyzer.analyze(fileAt: url)
    #expect(report.kind == .nsis)
    #expect(report.builder == .electronBuilder)
    #expect(report.runsPowerShell)

    let setup = Recipes.installerSettings(for: report)
    #expect(setup.applied.map(\.id) == ["electron-builder-no-powershell"])
    #expect(setup.registry == [.string(#"HKEY_CURRENT_USER\Software\Wine\DllOverrides"#, "powershell.exe", "")])
    // An empty value is what turns the program off in Wine.
    #expect(RegistryFile.render(setup.registry).contains(#""powershell.exe"="""#))
}

@Test func otherNSISInstallersGetNoRecipe() throws {
    // A plain NSIS installer.
    let plain = try #require(NSISScript.facts(in: makeNSIS(texts: ["$INSTDIR\\program.exe"]), scanLimit: 1 << 20))
    #expect(plain.builder == nil)
    #expect(!plain.runsPowerShell)

    // Older electron-builder versions check with tasklist, not PowerShell: nothing to change.
    let older = try #require(NSISScript.facts(in: makeNSIS(texts: ["\\app-32.7z", "\\nsis7z.dll", "tasklist"]), scanLimit: 1 << 20))
    #expect(older.builder == .electronBuilder)
    #expect(!older.runsPowerShell)
    let report = InstallerReport(fileName: "x.exe", sizeBytes: 1, kind: .nsis, kindVersion: nil, executable: nil,
                                 companionFiles: [], builder: older.builder, runsPowerShell: older.runsPowerShell)
    #expect(Recipes.installerSettings(for: report).applied.isEmpty)
}

@Test func unreadableNSISHeadersGiveNothing() {
    // A header that is not DEFLATE (LZMA, bzip2 or damaged), one cut short, and no NSIS at all.
    var damaged = [UInt8](makeNSIS(texts: electronBuilderTexts))
    for index in 1060 ..< damaged.count { damaged[index] = 0x5D }
    #expect(NSISScript.facts(in: Data(damaged), scanLimit: 1 << 20) == nil)
    #expect(NSISScript.facts(in: makeNSIS(texts: electronBuilderTexts).prefix(1050), scanLimit: 1 << 20) == nil)
    #expect(NSISScript.facts(in: makePE(), scanLimit: 1 << 20) == nil)
}
