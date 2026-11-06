import Foundation
import Testing
@testable import VitralKit

// Lines copied from real logs (`~/Library/Logs/Vitral`, `conocimiento/Caso *.md`), without
// personal data.

private func ids(_ observation: FailureObservation) -> [String] {
    Diagnoser.diagnose(observation, language: .english).map(\.id)
}

// MARK: The catalog itself

@Test func theCatalogIsSound() throws {
    let catalog = FailureCatalog.builtIn
    #expect(Set(catalog.entries.map(\.id)).count == catalog.entries.count, "ids repeat")
    for entry in catalog.entries {
        #expect(!entry.title.es.isEmpty && !entry.title.en.isEmpty, "\(entry.id): title")
        if entry.kind != .harmless {
            #expect(!entry.explanation.es.isEmpty && !entry.explanation.en.isEmpty, "\(entry.id): explanation")
        }
        if entry.kind == .fixable { #expect(!entry.fixes.isEmpty, "\(entry.id): a fixable failure needs a fix") }
        for fix in entry.fixes {
            if let recipe = fix.recipe { #expect(Recipes.describe(recipe, language: .english) != recipe, "\(entry.id): unknown recipe \(recipe)") }
        }
        for condition in entry.when {
            // A condition with nothing to look at would match everything.
            let looksAt = condition.log != nil || condition.logAll != nil || condition.product != nil
                || condition.antiCheat != nil || condition.missingFunction != nil || condition.status != nil
            #expect(looksAt, "\(entry.id): a condition must look at something")
            for pattern in (condition.log ?? []) + (condition.logAll ?? []) + [condition.product].compactMap({ $0 }) {
                #expect((try? NSRegularExpression(pattern: pattern)) != nil, "\(entry.id): bad pattern \(pattern)")
            }
        }
    }
}

// MARK: Real cases

@Test func electronBlankWindowFromTheATubeCatcherInstallation() throws {
    let log = """
        0254:err:winediag:wined3d_adapter_create Using the Vulkan renderer for d3d10/11 applications.
        err:   CreateSwapChain: cross-process swapchain not supported yet
        """
    let found = Diagnoser.diagnose(FailureObservation(phase: .install, logs: [log]), language: .english)
    #expect(found.map(\.id) == ["chromium-gpu-process"])
    #expect(found.first?.evidence == "err:   CreateSwapChain: cross-process swapchain not supported yet")
    #expect(found.first?.fixesText.first?.contains("--in-process-gpu") == true)
}

@Test func electronMissingFunctionOnAnOlderEngine() {
    // aTube Catcher on CrossOver 24: status 3, no window, Crashpad's last words.
    let log = "[1234:5678:ERROR:crashpad_client_win.cc(869)] not connected"
    #expect(ids(FailureObservation(phase: .start, logs: [log], status: 3, sawWindow: false)) == ["chromium-missing-function"])
    // Without that line: what the engine lacks, and Electron's status.
    #expect(ids(FailureObservation(phase: .start, status: 3, sawWindow: false, technologies: ["electron"], missingFunction: true))
            == ["chromium-missing-function"])
    // It opened: not this.
    #expect(ids(FailureObservation(phase: .running, status: 0, sawWindow: true, technologies: ["electron"], missingFunction: true)).isEmpty)
}

@Test func aCrashWhileStartingIsWorthAnotherTry() {
    // Shape It! 2, 2026-11-05: the first attempt crashed, the second opened.
    let log = """
        00d4:err:d3d:wined3d_check_gl_call >>>>>>> GL_INVALID_ENUM (0x500) from extension detection
        wine: Unhandled page fault on read access to 00000000 at address 00000000 (thread 00d4), starting debugger...
        """
    let found = Diagnoser.diagnose(FailureObservation(phase: .start, logs: [log], status: 5, sawWindow: false))
    #expect(found.map(\.id) == ["crash-at-start"])
    #expect(found.first?.kind == .retry)
}

@Test func qtFailuresComeFromTheProgramsOwnLog() {
    // Shape It!'s appLogs.txt with CX 24 (Caso Shape It.md).
    let openGL = """
        [critical] : WebEngineContext used before QtWebEngine::initialize() or OpenGL context creation failed.
        [critical] : SetPixelFormat failed.
        """
    #expect(ids(FailureObservation(phase: .start, logs: ["", openGL], sawWindow: false)) == ["qt-opengl"])

    let window = """
        [critical] : EnableNonClientDpiScaling() failed for HWND 0x20072 (120) (Call not implemented.)
        [critical] : CreateWindowEx failed (Call not implemented.)
        [critical] : Failed to create platform window
        """
    #expect(ids(FailureObservation(phase: .start, logs: [window])) == ["qt-dpi-window"])
    // The same warning alone shows up when it works too: harmless.
    let fine = """
        [critical] : EnableNonClientDpiScaling() failed for HWND 0x20072 (120) (Call not implemented.)
        [critical] : Could not query audio devices. (Not implemented.)
        """
    #expect(ids(FailureObservation(phase: .running, logs: [fine], status: 0, sawWindow: true)).isEmpty)
    #expect(LogExcerpt.lines(of: fine).isEmpty)

    let lock = "[warning] : QSingleInstance: Failed to transfer arguments to master: Invalid name\n[critical] : Master did not respond in time"
    #expect(ids(FailureObservation(phase: .start, logs: [lock], sawWindow: false)) == ["qt-single-instance"])
}

@Test func dotNetFrameworkMissingInAnInstaller() {
    // Greenshot's Inno Setup without .NET (2026-11-05).
    let log = "Exception message:\nInternal error: Unknown custom message name \"lcid\"."
    let found = Diagnoser.diagnose(FailureObservation(phase: .install, logs: [log]))
    #expect(found.map(\.id) == ["dotnet-framework-missing"])
    #expect(found.first?.signature.fixes == [FailureFix(component: "dotnet48")])
}

@Test func graphicsAndEngineGaps() {
    // vMix GT Title Designer and Paint.NET's installer, DXMT 0.80.
    let gt = "warn:  D3D11Resource(tex2d): Unknown interface query cafcb56c-6ac3-4889-bf47-9e23bbd260ec"
    #expect(ids(FailureObservation(phase: .running, logs: [gt], status: 0, sawWindow: true)) == ["dxgi-surface"])
    // Another interface Electron asks for, harmless (aTube Catcher works).
    let other = "warn:  D3D11Resource(tex2d): Unknown interface query f8fb5c27-c6b3-4f75-a4c8-439af2ef564c"
    #expect(ids(FailureObservation(phase: .running, logs: [other], status: 0, sawWindow: true)).isEmpty)

    let gstreamer = #"0024:err:module:import_dll Library winegstreamer.dll (which is needed by L"C:\\windows\\system32\\ir50_32.dll") not found"#
    #expect(ids(FailureObservation(phase: .running, logs: [gstreamer])) == ["engine-without-gstreamer"])
}

@Test func namesTheMissingMicrosoftLibrary() {
    let log = #"0024:err:module:import_dll Library MSVCP140.dll (which is needed by L"C:\\Program Files\\Ejemplo\\ejemplo.exe") not found"#
    let found = Diagnoser.diagnose(FailureObservation(phase: .start, logs: [log], sawWindow: false), language: .spanish)
    #expect(found.first?.id == "microsoft-library-missing")
    #expect(found.first?.title == "Falta una biblioteca de Microsoft (MSVCP140.dll)")
    #expect(found.first?.explanation.contains("MSVCP140.dll") == true)
}

@Test func knownProgramsBeforeInstalling() {
    // Paint.NET comes as a ZIP: its name is all there is to see.
    #expect(ids(FailureObservation(phase: .analysis, names: ["paint.net.5.1.12.install.x64.zip"])) == ["paint-net-direct2d"])
    #expect(ids(FailureObservation(phase: .analysis, names: ["Paint.NET 5.0.13"])) == ["paint-net-direct2d"])
    #expect(ids(FailureObservation(phase: .analysis, names: ["paint.net.5.2.0.portable.x64.zip"])).isEmpty)
    #expect(ids(FailureObservation(phase: .analysis, names: ["PBIDesktopSetup_x64.exe", "Microsoft Power BI Desktop 2.159.1060.0"])) == ["power-bi"])
    let crash = "Unhandled Exception: System.AccessViolationException at Microsoft.PowerBI.Client.AppModule.Run()"
    #expect(ids(FailureObservation(phase: .start, logs: [crash], sawWindow: false)).first == "power-bi")
    #expect(ids(FailureObservation(phase: .running, antiCheat: true)) == ["anti-cheat"])
}

@Test func onlyNoiseMeansNothingKnown() {
    let log = """
        009c:err:ntoskrnl:ZwLoadDriver failed to create driver L"\\\\Registry\\\\Machine\\\\System\\\\CurrentControlSet\\\\Services\\\\winebth": c00000e5
        0024:err:kerberos:kerberos_LsaApInitializePackage no Kerberos support, expect problems
        info:  Failed to set Metal cache path, fallback to system default
        """
    #expect(ids(FailureObservation(phase: .start, logs: [log], status: 1, sawWindow: false)).isEmpty)
}

// MARK: Reading what happened

@Test func readsTheLastRunInBothLanguages() {
    let english = "[Vitral 8:57:22 a. m.] Ended after 2 s (status 1, window: no)"
    let spanish = "[Vitral 10:53:48] Terminó a los 4 s (código 5, ventana: no)\n[Vitral 10:54:52] Terminó a los 63 s (código 15, ventana: sí)"
    #expect(LaunchLog.lastRun(in: english) == LaunchLog.Run(seconds: 2, status: 1, sawWindow: false))
    #expect(LaunchLog.lastRun(in: spanish) == LaunchLog.Run(seconds: 63, status: 15, sawWindow: true))
    #expect(LaunchLog.failedToStart(LaunchLog.Run(seconds: 2, status: 1, sawWindow: false)))
    #expect(!LaunchLog.failedToStart(LaunchLog.Run(seconds: 63, status: 15, sawWindow: true)))
    #expect(LaunchLog.lastRun(in: "nothing") == nil)
}

@Test func findsTheLogsTheProgramWrote() throws {
    let folder = try TemporaryFolder()
    let prefix = folder.url
    let fm = FileManager.default
    let appData = prefix.appendingPathComponent("drive_c/users/crossover/AppData/Local")
    let program = prefix.appendingPathComponent("drive_c/Program Files/Ejemplo")
    let outside = folder.url.appendingPathComponent("outside")
    for dir in [appData.appendingPathComponent("Avallain/Shape it"), appData.appendingPathComponent("App/Cache"), program, outside] {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    let start = Date()
    let write = { (url: URL) in try "[critical] : something\n".write(to: url, atomically: true, encoding: .utf8) }
    try write(appData.appendingPathComponent("Avallain/Shape it/appLogs.txt"))
    try write(appData.appendingPathComponent("App/Cache/data.log"))        // a cache: skipped
    try write(program.appendingPathComponent("ejemplo.log"))
    try write(program.appendingPathComponent("readme.txt"))                // not a log
    let old = appData.appendingPathComponent("old.log")
    try write(old)
    try fm.setAttributes([.modificationDate: start.addingTimeInterval(-3600)], ofItemAtPath: old.path)
    try write(outside.appendingPathComponent("private.log"))
    try fm.createSymbolicLink(at: appData.appendingPathComponent("Linked"), withDestinationURL: outside)

    let found = ProgramLogs.written(since: start.addingTimeInterval(-5), prefix: prefix, programFolder: program)
        .map(\.lastPathComponent).sorted()
    #expect(found == ["appLogs.txt", "ejemplo.log"], "found: \(found)")
}

@Test func aReportNamesTheKnownFailure() throws {
    var report = ProblemReport(kind: .start(attempts: 1), productName: "Ejemplo", program: "Ejemplo 1.0", mac: "Mac",
                               facts: [], log: [], logFile: nil)
    report.diagnoses = Diagnoser.diagnose(FailureObservation(phase: .start, logs: ["Failed to create OpenGL context"]), language: .english)
    #expect(report.title.hasSuffix("[qt-opengl]"))
}
