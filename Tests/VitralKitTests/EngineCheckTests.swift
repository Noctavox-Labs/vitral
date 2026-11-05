import Foundation
import Testing
@testable import VitralKit

// MARK: Import and export tables

@Test(arguments: [false, true])
func readsImportedAndExportedFunctions(is64Bit: Bool) throws {
    var program = SyntheticPE(machine: is64Bit ? 0x8664 : 0x014C, is64Bit: is64Bit)
    program.imports = ["user32.dll", "kernel32.dll"]
    program.delayImports = ["ole32.dll"]
    program.functions = ["user32.dll": ["CreateWindowExW", "IsWindowArranged"], "ole32.dll": ["RoGetAgileReference"]]
    let image = try #require(PortableExecutable.image(program.build()))
    #expect(image.importTable() == [
        .init(name: "user32.dll", functions: ["CreateWindowExW", "IsWindowArranged"], delayLoaded: false),
        .init(name: "kernel32.dll", functions: [], delayLoaded: false),
        .init(name: "ole32.dll", functions: ["RoGetAgileReference"], delayLoaded: true),
    ])
    #expect(image.importedDLLs() == ["kernel32.dll", "ole32.dll", "user32.dll"])
    #expect(image.exportedNames().isEmpty)

    var library = SyntheticPE(machine: is64Bit ? 0x8664 : 0x014C, is64Bit: is64Bit, isDLL: true)
    library.exports = ["CreateWindowExW", "GetPointerType"]
    #expect(try #require(PortableExecutable.image(library.build())).exportedNames() == ["CreateWindowExW", "GetPointerType"])
}

// MARK: Program against engine

/// An engine folder with a few DLLs, and a program like aTube Catcher (Electron) beside its own DLLs.
private func makeElectronLikeProgram(_ folder: TemporaryFolder) throws -> URL {
    func dll(_ exports: [String]) -> SyntheticPE {
        var pe = SyntheticPE(machine: 0x8664, is64Bit: true, isDLL: true)
        pe.exports = exports
        return pe
    }
    try folder.write("engine/user32.dll", dll(["CreateWindowExW", "GetPointerType"]))
    try folder.write("engine/ole32.dll", dll(["CoInitializeEx"]))
    try folder.write("engine/kernel32.dll", dll(["CreateFileW"]))

    var main = SyntheticPE(machine: 0x8664, is64Bit: true)
    main.imports = ["kernel32.dll", "api-ms-win-core-synch-l1-2-0.dll", "ffmpeg.dll", "userenv.dll"]
    main.delayImports = ["user32.dll", "ole32.dll"]
    main.functions = [
        "kernel32.dll": ["CreateFileW"],
        "api-ms-win-core-synch-l1-2-0.dll": ["WaitOnAddress"],   // an API set: Wine resolves it
        "ffmpeg.dll": ["av_malloc"],                             // the program's own DLL
        "userenv.dll": ["DeriveAppContainerSidFromAppContainerName"],
        "user32.dll": ["CreateWindowExW", "GetPointerDevice", "IsWindowArranged"],
        "ole32.dll": ["CoInitializeEx", "RoGetAgileReference"],
    ]
    try folder.write("app/Program.exe", main)

    var ffmpeg = SyntheticPE(machine: 0x8664, is64Bit: true, isDLL: true)
    ffmpeg.imports = ["kernel32.dll", "bcrypt.dll"]
    ffmpeg.functions = ["kernel32.dll": ["CreateFileW", "GetFileInformationByName"], "bcrypt.dll": ["BCryptGenRandom"]]
    ffmpeg.exports = ["av_malloc"]
    try folder.write("app/FFmpeg.dll", ffmpeg)

    // Installed in Windows' system folder of the prefix (a runtime): it counts as present.
    try folder.write("prefix/drive_c/windows/system32/bcrypt.dll", dll(["BCryptGenRandom"]))
    return folder.url.appendingPathComponent("app/Program.exe")
}

@Test func findsWhatTheEngineLacks() throws {
    let folder = try TemporaryFolder()
    let program = try makeElectronLikeProgram(folder)
    let engine = folder.url.appendingPathComponent("engine")
    let system = folder.url.appendingPathComponent("prefix/drive_c/windows/system32")

    let missing = EngineCheck.missingImports(program: program, systemFolders: [engine, system])
    #expect(missing.map(\.label) == [
        "user32.IsWindowArranged",   // seen stopping Electron: it goes first
        "userenv.dll",               // the whole DLL is missing
        "user32.GetPointerDevice",
        "ole32.RoGetAgileReference",
        "kernel32.GetFileInformationByName",
    ])
    #expect(missing[0] == MissingImport(dll: "user32.dll", function: "IsWindowArranged", delayLoaded: true, usedBy: "Program.exe"))
    #expect(missing[1].function == nil && !missing[1].delayLoaded)
    #expect(missing.last?.usedBy == "FFmpeg.dll")

    // Without the prefix, the runtime installed in it is missing too.
    #expect(EngineCheck.missingImports(program: program, systemFolders: [engine]).map(\.label).contains("bcrypt.dll"))
}

@Test func summarizesWithoutRepeats() {
    let items = ["IsWindowArranged", "GetPointerDevice", "GetPointerPenInfo", "IsWindowArranged", "EnableMouseInPointer"].map {
        MissingImport(dll: "user32.dll", function: $0, delayLoaded: true, usedBy: "a.exe")
    }
    let summary = MissingImport.summary(items)
    #expect(summary.hasPrefix("user32.IsWindowArranged, user32.GetPointerDevice, user32.GetPointerPenInfo "))
    #expect(summary.hasSuffix(" 1 más") || summary.hasSuffix(" 1 more"))
    #expect(MissingImport.summary(Array(items.prefix(2))) == "user32.IsWindowArranged, user32.GetPointerDevice")
    #expect(EngineCheck.warning([], engine: EngineCatalog.default) == nil)
    #expect(EngineCheck.warning(items, engine: EngineCatalog.default)?.contains("user32.IsWindowArranged") == true)
}

@Test func warnsOnlyAboutWhatStopsPrograms() {
    // aTube Catcher on CrossOver 26: three delay-loaded functions missing, and it opens fine.
    let harmless = [("userenv.dll", "DeriveAppContainerSidFromAppContainerName"),
                    ("uiautomationcore.dll", "UiaDisconnectAllProviders"), ("user32.dll", "GetPointerDevice")].map {
        MissingImport(dll: $0.0, function: $0.1, delayLoaded: true, usedBy: "aTube Catcher.exe")
    }
    #expect(EngineCheck.warning(harmless, engine: EngineCatalog.default) == nil)
    let missingAtStart = MissingImport(dll: "d3d12core.dll", function: nil, delayLoaded: false, usedBy: "a.exe")
    #expect(EngineCheck.warning(harmless + [missingAtStart], engine: EngineCatalog.default)?.contains("d3d12core.dll") == true)
    #expect(EngineCheck.warning(harmless + [missingAtStart], engine: EngineCatalog.default)?.contains("GetPointerDevice") == false)
}

@Test func tellsMissingFunctionsFromMissingDLLs() {
    let function = MissingImport(dll: "user32.dll", function: "IsWindowArranged", delayLoaded: true, usedBy: "a.exe")
    let dll = MissingImport(dll: "ffmpeg.dll", function: nil, delayLoaded: true, usedBy: "a.exe")
    let engine = EngineCatalog.default
    // A DLL that is nowhere is not "a Windows function the engine lacks".
    let onlyDLL = EngineCheck.explanation([dll], engine: engine) ?? ""
    #expect(onlyDLL.contains("ffmpeg.dll") && !onlyDLL.contains(engine.name))
    let both = EngineCheck.explanation([function, dll], engine: engine) ?? ""
    #expect(both.contains(engine.name) && both.contains("user32.IsWindowArranged") && both.contains("ffmpeg.dll"))
    #expect(function.logLine.contains("user32.IsWindowArranged") && function.logLine.contains("a.exe"))
    #expect(function.logLine != dll.logLine.replacingOccurrences(of: "ffmpeg.dll", with: "user32.IsWindowArranged"))
}

@Test func checksAgainstTheRightEngineFolder() {
    let engine = InstalledEngine(engine: EngineCatalog.default, home: VitralHome(url: URL(fileURLWithPath: "/tmp/home")))
    #expect(EngineCheck.dllFolder(of: engine, bits: 32).path.hasSuffix("/lib/wine/i386-windows"))
    #expect(EngineCheck.dllFolder(of: engine, bits: 64).path.hasSuffix("/lib/wine/x86_64-windows"))
}

// MARK: Failed start

@Test func reportsStartsThatEndWithAnError() {
    // aTube Catcher on CrossOver 24: Chromium stops on purpose, status 3, no "Unhandled" line.
    let crashpad = "[0x1:ERROR:crashpad_client_win.cc(869)] not connected"
    #expect(StartupWatch.failedToStart(ranFor: 13, sawWindow: false, status: 3, log: crashpad))
    #expect(!StartupWatch.shouldRetry(ranFor: 13, sawWindow: false, log: crashpad, attempt: 1))
    // A Wine crash, whatever the status.
    #expect(StartupWatch.failedToStart(ranFor: 5, sawWindow: false, status: 0, log: "Unhandled page fault on read access"))
    // Not a failure: it showed a window, it ran a long time, or it ended cleanly.
    #expect(!StartupWatch.failedToStart(ranFor: 13, sawWindow: true, status: 3, log: ""))
    #expect(!StartupWatch.failedToStart(ranFor: 300, sawWindow: false, status: 3, log: ""))
    #expect(!StartupWatch.failedToStart(ranFor: 5, sawWindow: false, status: 0, log: "fixme:ole:something"))
}
