import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import VitralKit

// MARK: - Helpers

/// A square PNG of `side` pixels, filled with one color.
func makePNG(side: Int) -> [UInt8] {
    let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return [UInt8](output as Data)
}

/// A temporary folder that is deleted when the test ends.
final class TemporaryFolder {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vitral-test-\(UUID().uuidString)")

    init() throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ path: String, _ data: Data) throws {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    func write(_ path: String, _ pe: SyntheticPE) throws { try write(path, pe.build()) }
}

// MARK: - Version, imports, .NET

@Test func readsVersionStrings() throws {
    var pe = SyntheticPE()
    pe.versionStrings = [
        "ProductName": "Shape it Level 1 PPlus",
        "CompanyName": "Avallain AG   ",
        "ProductVersion": "28,0,0",
        "FileDescription": "Shape it Level 1 PPlus Setup",
    ]
    let info = try #require(PortableExecutable.parse(pe.build()))
    let version = try #require(info.version)
    #expect(version.productName == "Shape it Level 1 PPlus")
    #expect(version.companyName == "Avallain AG")
    #expect(version.productVersion == "28.0.0")
    #expect(version.fileDescription == "Shape it Level 1 PPlus Setup")
}

@Test func fallsBackToBinaryVersion() throws {
    var pe = SyntheticPE()
    pe.fixedVersion = (5, 12, 4, 0)
    pe.versionStrings = ["ProductName": "Qt5"]
    let version = try #require(PortableExecutable.parse(pe.build())?.version)
    #expect(version.productName == "Qt5")
    #expect(version.fileVersion == "5.12.4.0")
    #expect(version.productVersion == "5.12.4.0")
}

@Test func readsImportsAndDelayImports() throws {
    var pe = SyntheticPE()
    pe.imports = ["KERNEL32.dll", "Qt5Core.dll", "d3d11.dll"]
    pe.delayImports = ["dxgi.dll"]
    let info = try #require(PortableExecutable.parse(pe.build()))
    #expect(info.imports == ["d3d11.dll", "dxgi.dll", "kernel32.dll", "qt5core.dll"])
    #expect(info.isDotNet == false)
}

@Test func readsDotNetRuntimeVersion() throws {
    var pe = SyntheticPE()
    pe.imports = ["mscoree.dll"]
    pe.dotNetRuntime = "v4.0.30319"
    let info = try #require(PortableExecutable.parse(pe.build()))
    #expect(info.dotNetRuntime == "v4.0.30319")
    #expect(info.isDotNet)
}

@Test func plainExecutableHasNoExtras() throws {
    let info = try #require(PortableExecutable.parse(SyntheticPE().build()))
    #expect(info.imports.isEmpty)
    #expect(info.version == nil)
    #expect(info.hasIcon == false)
    #expect(info.dotNetRuntime == nil)
}

@Test func survivesTruncatedAndCorruptedResources() {
    var pe = SyntheticPE()
    pe.imports = ["kernel32.dll"]
    pe.versionStrings = ["ProductName": "Test"]
    pe.icons = [(16, makePNG(side: 16))]
    pe.dotNetRuntime = "v4.0.30319"
    let data = pe.build()

    // Every prefix must parse (or fail) without crashing.
    for length in stride(from: 0, through: data.count, by: 3) {
        _ = PortableExecutable.parse(data.prefix(length))
        _ = PortableExecutable.icon(data.prefix(length))
    }
    // So must files with garbage written over the structures.
    var generator = SystemRandomNumberGenerator()
    for _ in 0 ..< 200 {
        var corrupted = data
        for _ in 0 ..< 8 {
            let at = Int.random(in: SyntheticPE.sectionFileOffset ..< data.count, using: &generator)
            corrupted[at] = UInt8.random(in: 0 ... 255, using: &generator)
        }
        _ = PortableExecutable.parse(corrupted)
        _ = PortableExecutable.icon(corrupted)
    }
}

// MARK: - Icons

@Test func extractsIconGroupAsICOFile() throws {
    var pe = SyntheticPE()
    let small = makePNG(side: 16), large = makePNG(side: 64)
    pe.icons = [(16, small), (64, large)]
    let data = pe.build()
    #expect(PortableExecutable.parse(data)?.hasIcon == true)

    let ico = try #require(PortableExecutable.icon(data))
    let r = ByteReader(data: ico)
    #expect(r.u16(0) == 0 && r.u16(2) == 1 && r.u16(4) == 2)
    #expect(r.u8(6) == 16 && r.u8(22) == 64)
    let firstSize = Int(try #require(r.u32(6 + 8))), firstOffset = Int(try #require(r.u32(6 + 12)))
    let secondOffset = Int(try #require(r.u32(22 + 12)))
    #expect(firstOffset == 6 + 2 * 16)
    #expect(Array(ico[firstOffset ..< firstOffset + firstSize]) == small)
    #expect(Array(ico[secondOffset...]) == large)
}

@Test func convertsICOToICNSWithRetinaSizes() throws {
    var pe = SyntheticPE()
    pe.icons = [(32, makePNG(side: 32)), (0, makePNG(side: 256))]
    let ico = try #require(PortableExecutable.icon(pe.build()))
    let icns = try #require(AppIcon.icns(fromICO: ico))

    let source = try #require(CGImageSourceCreateWithData(icns as CFData, nil))
    #expect(CGImageSourceGetType(source) as String? == UTType.icns.identifier)
    let sides = Set((0 ..< CGImageSourceGetCount(source)).compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil)?.width })
    // Up to 256 px: 16, 16@2x and 32 (32 px), 32@2x (64), 128, 128@2x and 256 (256).
    #expect(sides == [16, 32, 64, 128, 256])
}

@Test func iconOfProgramWithoutIconIsNil() {
    #expect(PortableExecutable.icon(SyntheticPE().build()) == nil)
    #expect(PortableExecutable.icon(Data("not a program".utf8)) == nil)
}

// MARK: - Installed programs

@Test func analyzesQtProgramLikeShapeIt() throws {
    let folder = try TemporaryFolder()
    let app = "Shape it Level 1 PPlus"

    var main = SyntheticPE()
    main.imports = ["kernel32.dll", "qt5core.dll", "qt5webenginecore.dll", "msvcp140.dll", "vcruntime140.dll"]
    main.versionStrings = ["ProductName": app, "CompanyName": "Avallain", "ProductVersion": "28,0,0"]
    main.icons = [(16, makePNG(side: 16))]
    try folder.write("\(app)/\(app).exe", main)

    var core = SyntheticPE()
    core.isDLL = true
    core.fixedVersion = (5, 12, 4, 0)
    core.versionStrings = ["ProductName": "Qt5"]
    try folder.write("\(app)/Qt5Core.dll", core)

    var webEngine = SyntheticPE()
    webEngine.isDLL = true
    webEngine.imports = ["d3d11.dll", "d3d9.dll"]
    try folder.write("\(app)/Qt5WebEngineCore.dll", webEngine)
    try folder.write("\(app)/Qt5Quick.dll", SyntheticPE(isDLL: true))
    try folder.write("\(app)/libEGL.dll", SyntheticPE(isDLL: true))
    try folder.write("\(app)/libGLESV2.dll", SyntheticPE(isDLL: true))
    try folder.write("\(app)/QtWebEngineProcess.exe", SyntheticPE())
    try folder.write("\(app)/unins000.exe", SyntheticPE())
    try folder.write("\(app)/vc_redist.x86.exe", SyntheticPE())
    try folder.write("\(app)/data.bin", Data(repeating: 1, count: 100))

    let report = try ProgramAnalyzer.analyze(folderAt: folder.url.appendingPathComponent(app))
    #expect(report.mainExecutable == "\(app).exe")
    #expect(report.alternatives.isEmpty)
    #expect(report.executable?.bits == 32)
    #expect(report.executable?.version?.companyName == "Avallain")
    #expect(report.technology(.qt)?.version == "5.12.4")
    #expect(report.technology(.qtWebEngine)?.evidence == "QtWebEngineProcess.exe")
    #expect(report.technology(.qtQuick) != nil)
    #expect(report.technology(.angle) != nil)
    #expect(report.technology(.visualCpp)?.version == "2015-2022")
    #expect(report.bundledRedistributables == ["vc_redist.x86.exe"])
    // Qt WebEngine imports Direct3D, but Qt picks the graphics when it runs.
    #expect(report.graphics.isEmpty)
    #expect(report.antiCheat.isEmpty)
    #expect(report.fileCount == 10)
}

@Test func prefersGraphicalProgramNamedLikeTheFolder() throws {
    let folder = try TemporaryFolder()
    var tool = SyntheticPE()
    tool.subsystem = 3
    try folder.write("Paint Studio/tools/convert.exe", tool)
    try folder.write("Paint Studio/bin/PaintStudio.exe", SyntheticPE())
    try folder.write("Paint Studio/bin/other.exe", SyntheticPE())

    let report = try ProgramAnalyzer.analyze(folderAt: folder.url.appendingPathComponent("Paint Studio"))
    #expect(report.mainExecutable == "bin/PaintStudio.exe")
    #expect(report.alternatives == ["bin/other.exe", "tools/convert.exe"])
}

@Test func detectsGameGraphicsAndAntiCheat() throws {
    let folder = try TemporaryFolder()
    var game = SyntheticPE()
    game.is64Bit = true
    game.machine = 0x8664
    game.imports = ["d3d11.dll", "dxgi.dll", "xinput1_3.dll", "msvcp120.dll"]
    try folder.write("Game/Game.exe", game)
    try folder.write("Game/EasyAntiCheat/EasyAntiCheat_x64.dll", SyntheticPE(isDLL: true))
    try folder.write("Game/_CommonRedist/DXSETUP.exe", SyntheticPE())

    let report = try ProgramAnalyzer.analyze(folderAt: folder.url.appendingPathComponent("Game"))
    #expect(report.mainExecutable == "Game.exe")
    #expect(report.executable?.bits == 64)
    #expect(report.graphics == [.direct3D11])
    #expect(report.antiCheat == [.easyAntiCheat])
    #expect(report.technology(.visualCpp)?.version == "2013")
    #expect(report.bundledRedistributables == ["_CommonRedist/DXSETUP.exe"])
}

@Test func detectsDotNetVersions() throws {
    let folder = try TemporaryFolder()
    var framework = SyntheticPE()
    framework.imports = ["mscoree.dll"]
    framework.dotNetRuntime = "v4.0.30319"
    try folder.write("Old/Old.exe", framework)

    try folder.write("New/New.exe", SyntheticPE())
    let config = """
    {"runtimeOptions": {"tfm": "net8.0", "frameworks": [
      {"name": "Microsoft.NETCore.App", "version": "8.0.0"},
      {"name": "Microsoft.WindowsDesktop.App", "version": "8.0.1"}]}}
    """
    try folder.write("New/New.runtimeconfig.json", Data(config.utf8))

    let old = try ProgramAnalyzer.analyze(folderAt: folder.url.appendingPathComponent("Old"))
    #expect(old.technology(.dotNetFramework)?.version == "v4.0.30319")
    let new = try ProgramAnalyzer.analyze(folderAt: folder.url.appendingPathComponent("New"))
    #expect(new.technology(.dotNet)?.version == "8.0.1")
}

@Test func skipsSymbolicLinksLikeWineDrives() throws {
    let folder = try TemporaryFolder()
    try folder.write("App/App.exe", SyntheticPE())
    // A Wine prefix links z: to the whole disk; following it would scan the entire Mac.
    try FileManager.default.createSymbolicLink(
        at: folder.url.appendingPathComponent("App/z:"), withDestinationURL: URL(fileURLWithPath: "/")
    )
    let report = try ProgramAnalyzer.analyze(folderAt: folder.url.appendingPathComponent("App"))
    #expect(report.fileCount == 1)
    #expect(report.mainExecutable == "App.exe")
}

@Test func folderWithoutProgramsHasNoMainExecutable() throws {
    let folder = try TemporaryFolder()
    try folder.write("Docs/readme.txt", Data("hi".utf8))
    try folder.write("Docs/unins000.exe", SyntheticPE())
    let report = try ProgramAnalyzer.analyze(folderAt: folder.url.appendingPathComponent("Docs"))
    #expect(report.mainExecutable == nil)
    #expect(report.executable == nil)
}

@Test func programAnalyzerRejectsFilesAndMissingFolders() throws {
    let folder = try TemporaryFolder()
    try folder.write("file.txt", Data("x".utf8))
    #expect(throws: ProgramAnalyzerError.notAFolder) {
        try ProgramAnalyzer.analyze(folderAt: folder.url.appendingPathComponent("file.txt"))
    }
    #expect(throws: ProgramAnalyzerError.notFound) {
        try ProgramAnalyzer.analyze(folderAt: folder.url.appendingPathComponent("missing"))
    }
}

@Test func helperNamesAreNeverTheProgram() {
    for name in ["unins000.exe", "Uninstall.exe", "vc_redist.x64.exe", "QtWebEngineProcess.exe",
                 "crashpad_handler.exe", "UnityCrashHandler64.exe", "setup.exe", "notification_helper.exe"] {
        #expect(ProgramAnalyzer.isHelper(name), "\(name)")
    }
    for name in ["Shape it Level 1 PPlus.exe", "notepad++.exe", "Game.exe"] {
        #expect(!ProgramAnalyzer.isHelper(name), "\(name)")
    }
}

@Test func prefersTheProgramWhoseProductIsNamedLikeTheFolder() throws {
    let folder = try TemporaryFolder()
    var editor = SyntheticPE()
    editor.versionStrings = ["ProductName": "MetaQuotes Language 5 Editor"]
    var terminal = SyntheticPE()
    terminal.versionStrings = ["ProductName": "MetaTrader 5 Client Terminal"]
    try folder.write("MetaTrader 5/MetaEditor64.exe", editor)
    try folder.write("MetaTrader 5/terminal64.exe", terminal)

    let report = try ProgramAnalyzer.analyze(folderAt: folder.url.appendingPathComponent("MetaTrader 5"))
    #expect(report.mainExecutable == "terminal64.exe")
}
