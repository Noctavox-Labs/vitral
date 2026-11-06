import Foundation
import Testing
@testable import VitralKit

/// A 64-bit prefix, with 32-bit programs in `syswow64`.
private func wow64Prefix(_ folder: TemporaryFolder) throws -> URL {
    let prefix = folder.url.appendingPathComponent("prefix")
    try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c/windows/syswow64"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c/windows/system32"), withIntermediateDirectories: true)
    return prefix
}

@Test func geckoGoesWhereWinePutsIt() throws {
    let folder = try TemporaryFolder()
    let prefix = try wow64Prefix(folder)
    // 32-bit MSHTML reads the 32-bit registry view.
    #expect(WineGecko.registry(.x86, prefix: prefix) == .string(#"HKEY_LOCAL_MACHINE\Software\Wow6432Node\Wine\MSHTML\2.47.4"#,
                                                                "GeckoPath", #"C:\windows\syswow64\gecko\2.47.4\wine_gecko"#))
    #expect(WineGecko.registry(.x86_64, prefix: prefix) == .string(#"HKEY_LOCAL_MACHINE\Software\Wine\MSHTML\2.47.4"#,
                                                                   "GeckoPath", #"C:\windows\system32\gecko\2.47.4\wine_gecko"#))
    #expect(WineGecko.folder(.x86, in: prefix).path.hasSuffix("drive_c/windows/syswow64/gecko/2.47.4/wine_gecko"))
    #expect(WineGecko.architecture(of: nil) == .x86)
}

@Test func internetExplorerOnlyWhereGeckoIs() throws {
    let folder = try TemporaryFolder()
    let prefix = try wow64Prefix(folder)
    #expect(!WineGecko.isInstalled(prefix: prefix))
    #expect(InstalledEngine.dllOverrides(prefix: prefix) == "winemenubuilder.exe=d;mshtml=d")

    try folder.write("prefix/drive_c/windows/syswow64/gecko/2.47.4/wine_gecko/VERSION", Data("Wine Gecko 2.47.4".utf8))
    #expect(WineGecko.isInstalled(.x86, prefix: prefix))
    #expect(!WineGecko.isInstalled(.x86_64, prefix: prefix))
    #expect(InstalledEngine.dllOverrides(prefix: prefix) == "winemenubuilder.exe=d")
    let engine = InstalledEngine(engine: EngineCatalog.default, home: VitralHome(url: folder.url))
    #expect(engine.environment(prefix: prefix)["WINEDLLOVERRIDES"] == "winemenubuilder.exe=d")
}

@Test func programsWithInternetExplorersBrowser() throws {
    // CLSID_WebBrowser as programs store it (Encarta 2009's ENCARTA.EXE has it).
    let webBrowser = Data([0x61, 0xF9, 0x56, 0x88, 0x0A, 0x34, 0xD0, 0x11, 0xA9, 0x6B, 0x00, 0xC0, 0x4F, 0xD7, 0x05, 0xA2])
    #expect(WineGecko.browserMarkers.first == webBrowser)
    #expect(WineGecko.usesBrowser(imports: [], contents: Data([1, 2, 3]) + webBrowser + Data([4])))
    #expect(WineGecko.usesBrowser(imports: [], contents: "x Shell.Explorer.2 x".data(using: .utf16LittleEndian)))
    #expect(WineGecko.usesBrowser(imports: ["kernel32.dll", "MSHTML.dll"], contents: nil))
    #expect(!WineGecko.usesBrowser(imports: ["kernel32.dll", "user32.dll"], contents: Data("Explorer".utf8)))

    let folder = try TemporaryFolder()
    var app = SyntheticPE()
    app.imports = ["kernel32.dll", "Pages.dll"]
    var pages = SyntheticPE()
    pages.isDLL = true
    try folder.write("Encyclopedia/Encyclopedia.exe", app)
    try folder.write("Encyclopedia/Pages.dll", pages.build() + webBrowser)
    try folder.write("Encyclopedia/unused.dll", pages.build() + webBrowser)

    // Found in a DLL of its own that the program loads.
    let report = try ProgramAnalyzer.analyze(folderAt: folder.url.appendingPathComponent("Encyclopedia"))
    #expect(report.mainExecutable == "Encyclopedia.exe")
    #expect(report.technology(.internetExplorer)?.evidence == "Pages.dll")
    #expect(WineGecko.usesBrowser(program: folder.url.appendingPathComponent("Encyclopedia/Encyclopedia.exe")))

    // A DLL in the folder that the program does not load says nothing.
    try folder.write("Encyclopedia/Pages.dll", pages)
    let without = try ProgramAnalyzer.analyze(folderAt: folder.url.appendingPathComponent("Encyclopedia"))
    #expect(without.technology(.internetExplorer) == nil)
    #expect(!WineGecko.usesBrowser(program: folder.url.appendingPathComponent("Encyclopedia/Encyclopedia.exe")))
}

@Test func registryCheckReadsEscapedText() throws {
    // Wine writes `\` as `\\` in system.reg, as .reg files do.
    let folder = try TemporaryFolder()
    let prefix = folder.url.appendingPathComponent("prefix")
    try folder.write("prefix/system.reg", Data(#"""
        [Software\\Wow6432Node\\Wine\\MSHTML\\2.47.4] 1793986270
        "GeckoPath"="C:\\windows\\syswow64\\gecko\\2.47.4\\wine_gecko"
        """#.utf8))
    let session = WineSession(engine: InstalledEngine(engine: EngineCatalog.default, home: VitralHome(url: folder.url)), prefix: prefix)
    #expect(session.registryContains([.string(#"HKEY_LOCAL_MACHINE\Software\Wow6432Node\Wine\MSHTML\2.47.4"#,
                                              "GeckoPath", #"C:\windows\syswow64\gecko\2.47.4\wine_gecko"#)]))
    #expect(!session.registryContains([.string(#"HKEY_LOCAL_MACHINE\Software\Wine\MSHTML\2.47.4"#,
                                               "GeckoPath", #"C:\windows\system32\gecko\2.47.4\wine_gecko"#)]))
}

@Test func newerBuildReplacesTheEngine() throws {
    #expect(EngineCatalog.default.id == "cx26.3.0-2")
    #expect(EngineCatalog.successor(of: "cx26.3.0-1")?.id == "cx26.3.0-2")
    #expect(EngineCatalog.successor(of: "cx26.3.0-2") == nil)
    // A different Wine is not a newer build of the same one.
    #expect(EngineCatalog.successor(of: "cx24.0.7_7") == nil)
    #expect(EngineCatalog.engine(id: "cx26.3.0-1") != nil)
    #expect(Recipes.describe(EngineCatalog.stayRecipe) != EngineCatalog.stayRecipe)

    // Updating a prefix never offers Wine Mono; MSHTML registers again only where Gecko is.
    let folder = try TemporaryFolder()
    let prefix = try wow64Prefix(folder)
    #expect(InstalledEngine.prefixUpdateOverrides(prefix: prefix) == "winemenubuilder.exe=d;mscoree=d;mshtml=d")
    try folder.write("prefix/drive_c/windows/syswow64/gecko/2.47.4/wine_gecko/VERSION", Data("Wine Gecko 2.47.4".utf8))
    #expect(InstalledEngine.prefixUpdateOverrides(prefix: prefix) == "winemenubuilder.exe=d;mscoree=d")
}
