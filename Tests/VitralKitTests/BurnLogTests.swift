import Foundation
import Testing
@testable import VitralKit

@Test func noticesABurnBundleThatRepeatsAPrerequisite() {
    let once = """
    [00D8:00DC][2026-11-05T12:26:16]i052: Condition 'NETFRAMEWORK45 >= 394802' evaluates to false.
    [00D8:00DC][2026-11-05T12:26:28]i319: Applied execute package: NetFx462Web, result: 0x0, restart: None
    [00D8:00DC][2026-11-05T12:26:28]i319: Applied execute package: ProductMSI, result: 0x0, restart: None
    """
    #expect(BurnLog.repeatedPackage(in: once) == nil)
    let twice = once + "\r\n[00D8:00DC][2026-11-05T12:26:47]i319: Applied execute package: NetFx462Web, result: 0x0, restart: None\r\n"
    #expect(BurnLog.repeatedPackage(in: twice) == "NetFx462Web")
    // A failed attempt followed by a retry is not a loop.
    let failed = "i319: Applied execute package: VCRedist, result: 0x80070643, restart: None\ni319: Applied execute package: VCRedist, result: 0x0, restart: None\n"
    #expect(BurnLog.repeatedPackage(in: failed) == nil)

    #expect(BurnLog.friendlyName("NetFx462Web") == ".NET Framework 4.6.2")
    #expect(BurnLog.friendlyName("NetFx48") == ".NET Framework 4.8")
    #expect(BurnLog.friendlyName("ProductMSI") == "ProductMSI")
}

@Test func noticesTheLoopAsSoonAsThePrerequisiteIsMissingAgain() {
    let log = """
    i101: Detected package: NetFx462Web, state: Absent, cached: None
    i319: Applied execute package: NetFx462Web, result: 0x0, restart: None
    i101: Detected package: NetFx462Web, state: Absent, cached: Complete
    """
    #expect(BurnLog.repeatedPackage(in: log) == "NetFx462Web")
    #expect(BurnLog.isDotNetFramework("NetFx462Web"))
    #expect(!BurnLog.isDotNetFramework("ProductMSI"))
}

@Test func readsTheDotNetFrameworkReleaseOfAPrefix() throws {
    let folder = try TemporaryFolder()
    try folder.write("prefix/system.reg", Data("""
    WINE REGISTRY Version 2

    [Software\\\\Microsoft\\\\NET Framework Setup\\\\NDP\\\\v4\\\\Client] 1730000000
    "Release"=dword:00000001

    [Software\\\\Microsoft\\\\NET Framework Setup\\\\NDP\\\\v4\\\\Full] 1730000000
    #time=1db
    "Install"=dword:00000001
    "Release"=dword:00080eb1
    "Version"="4.8.03761"

    """.utf8))
    let prefix = folder.url.appendingPathComponent("prefix")
    #expect(DotNetFramework.installedRelease(prefix: prefix) == 528_049)
    #expect(DotNetFramework.isInstalled(prefix: prefix))
    #expect(!DotNetFramework.isInstalled(prefix: folder.url))
    #expect(DotNetFramework.needed(by: "v4.0.30319"))
    #expect(!DotNetFramework.needed(by: "v2.0.50727"))
    #expect(!DotNetFramework.needed(by: nil))
}

@Test func keepsAnInstallerDownloadAsItIs() async throws {
    let folder = try TemporaryFolder()
    let payload = Data("MZ installer".utf8)
    try folder.write("download/setup.exe", payload)
    let component = Component(id: "test-setup", name: "Setup", url: URL(string: "https://example.com/setup.exe")!,
                              sha256: try ComponentInstaller.sha256(of: folder.url.appendingPathComponent("download/setup.exe")),
                              bytes: Int64(payload.count), archiveRoot: "", license: "test",
                              source: URL(string: "https://example.com")!, fileName: "setup.exe")
    let source = folder.url.appendingPathComponent("download/setup.exe")
    let root = folder.url
    let installer = ComponentInstaller(home: VitralHome(url: folder.url.appendingPathComponent("home"))) { _, _ in
        let copy = root.appendingPathComponent("fetched-\(UUID().uuidString).exe")
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }
    let installed = try await installer.install(component)
    #expect(try Data(contentsOf: installed.appendingPathComponent("setup.exe")) == payload)
    #expect(installer.isInstalled(component))
}

@Test func readsWhyAnInnoSetupInstallerStopped() {
    let log = """
    2026-11-05 14:03:54.731   Successfully imported the DLL function. Delay loaded? No
    2026-11-05 14:03:54.735   InitializeSetup raised an exception (fatal).
    2026-11-05 14:03:54.736   Exception message:
    2026-11-05 14:03:54.736   Defaulting to OK for suppressed message box (OK):
                              Runtime error (at 65:679):

                              Internal error: Unknown custom message name "lcid"
    2026-11-05 14:03:54.736   Deinitializing Setup.
    2026-11-05 14:03:54.741   Log closed.
    """
    #expect(InnoSetupLog.fatalError(in: log) == #"Runtime error (at 65:679): Internal error: Unknown custom message name "lcid""#)
    #expect(InnoSetupLog.fatalError(in: "2026-11-05 14:04:27.061   Installation process succeeded.") == nil)
}

@Test func dotNetProgressMovesOnWithoutReachingTheEndOfTheStep() {
    let at = { (seconds: Double) in DotNetFramework.creep(from: 0.2, to: 0.6, elapsed: seconds, expected: 180) }
    #expect(at(0) == 0.2)
    #expect(at(30) > 0.2 && at(30) < at(60))
    #expect(abs(at(180) - (0.2 + 0.4 * 0.86)) < 0.01)
    // A slower Mac keeps moving, but never past the step.
    #expect(at(900) < 0.6 && at(900) > at(600))
}
