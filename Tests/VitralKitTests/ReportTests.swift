import Foundation
import Testing
@testable import VitralKit

// MARK: Personal data

@Test func removesPersonalData() {
    let privacy = PrivateData(home: "/Users/ana", userName: "ana", fullName: "Ana Pérez", computerName: "MacBook de Ana")
    let text = """
        open /Users/ana/Downloads/setup.exe
        Z:\\Users\\ana\\Documents\\x.txt and C:\\users\\ana\\Temp
        Ana Pérez (ana.perez@example.com) on MacBook de Ana
        banana analysis
        """
    let redacted = privacy.redact(text)
    #expect(!redacted.contains("/Users/ana"))
    #expect(redacted.contains("~/Downloads/setup.exe"))
    #expect(!redacted.localizedCaseInsensitiveContains("\\ana\\"))
    #expect(!redacted.contains("Ana Pérez"))
    #expect(!redacted.contains("example.com"))
    #expect(!redacted.contains("MacBook de Ana"))
    // Parts of other words stay.
    #expect(redacted.contains("banana analysis"))
}

// MARK: Log excerpt

@Test func keepsTheUsefulLinesOfALog() {
    let log = """
        [Vitral 8:19:35 p. m.] Opening (attempt 1)…
        009c:err:ntoskrnl:ZwLoadDriver failed to create driver L"\\\\Registry\\\\Machine\\\\System\\\\CurrentControlSet\\\\Services\\\\winebth": c00000e5
        0024:fixme:ver:GetCurrentPackageId (000000000011FE30 0000000000000000): stub
        warn:  D3D11Device: Unknown interface query 10ec4d5b-975a-4689-b9e4-d0aac30fe333
        01d8:err:ole:com_get_class_object class {92f35e78-15a5-486b-888e-575f99651ce2} not registered
        01dc:err:ole:com_get_class_object class {92f35e78-15a5-486b-888e-575f99651ce2} not registered
        01d8:err:ole:com_get_class_object class {11111111-15a5-486b-888e-575f99651ce2} not registered
        wine: Unhandled page fault on read access to 0000000000000000 at address 0000000140001000
        [Vitral 8:19:40 p. m.] Ended after 5 s (status 3, window: no)
        """
    #expect(LogExcerpt.lines(of: log) == [
        "[Vitral 8:19:35 p. m.] Opening (attempt 1)…",
        "01d8:err:ole:com_get_class_object class {92f35e78-15a5-486b-888e-575f99651ce2} not registered (×3)",
        "wine: Unhandled page fault on read access to 0000000000000000 at address 0000000140001000",
        "[Vitral 8:19:40 p. m.] Ended after 5 s (status 3, window: no)",
    ])
}

@Test func overTheLimitKeepsWhatSaysWhatFailed() {
    var lines = (0..<50).map { "line \($0) printed by the program, different text \(String(repeating: "x", count: $0))" }
    lines.insert("0024:err:module:import_dll Library d3dcompiler_47.dll not found", at: 3)
    lines.append("[Vitral 1:00:00] Ended after 2 s (status 1, window: no)")
    let kept = LogExcerpt.lines(of: lines.joined(separator: "\n"), limit: 5)
    #expect(kept.count == 5)
    #expect(kept.first == "0024:err:module:import_dll Library d3dcompiler_47.dll not found")
    #expect(kept.last == "[Vitral 1:00:00] Ended after 2 s (status 1, window: no)")
}

@Test func readsTheBeginningAndEndOfALargeLog() throws {
    let folder = try TemporaryFolder()
    let file = folder.url.appendingPathComponent("big.log")
    let middle = String(repeating: "0024:err:ole:noise\n", count: 2_000)
    try ("[Vitral] first\n" + middle + "[Vitral] last\n").write(to: file, atomically: true, encoding: .utf8)
    let text = LogExcerpt.read(file, head: 1000, tail: 1000)
    #expect(text.hasPrefix("[Vitral] first"))
    #expect(text.contains("\n…\n"))
    #expect(text.hasSuffix("[Vitral] last\n"))
    #expect(text.count < 3000)
}

// MARK: Report and GitHub link

private func sampleReport(logLines: Int) -> ProblemReport {
    ProblemReport(kind: .start(attempts: 3), productName: "Ejemplo", program: "Ejemplo 1.0",
                  mac: "MacBookPro18,3 · Apple M1 Pro · 16 GB · macOS 27.2 · Rosetta",
                  facts: [.init("Motor", "cx26.3.0-1"), .init("Recetas", "electron-in-process-gpu")],
                  log: (0..<logLines).map { "0024:err:módulo línea \($0) con acentos áéíóú y algo más de texto" },
                  logFile: nil)
}

@Test func fillsGitHubsFormByFieldID() throws {
    let report = sampleReport(logLines: 3)
    let url = report.issueURL()
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    let fields = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    #expect(url.absoluteString.hasPrefix("https://github.com/noctavox-labs/vitral/issues/new?template=app-not-working.yml&"))
    #expect(fields["program"] == "Ejemplo 1.0")
    #expect(fields["vitral-version"] == Vitral.version)
    #expect(fields["report"] == report.text)
    #expect(fields["what-happened"] == report.summary)
    #expect(fields["title"] == report.title)
    // A "+" would read as a space.
    #expect(!url.absoluteString.contains("+"))
}

@Test func longReportsDropTheOldestLogLines() throws {
    let report = sampleReport(logLines: 200)
    let url = report.issueURL()
    #expect(url.absoluteString.count <= ProblemReport.maxURLLength)
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    let text = try #require(items.first { $0.name == "report" }?.value)
    #expect(text.hasPrefix("Motor: cx26.3.0-1"))
    // The newest line stays; the oldest go, with a note of how many.
    #expect(text.hasSuffix("línea 199 con acentos áéíóú y algo más de texto"))
    #expect(!text.contains("línea 0 con"))
    #expect(text.contains("[…"))
}

@Test func anEditedReportStillFits() {
    let report = sampleReport(logLines: 2)
    let url = report.issueURL(text: String(repeating: "texto sin registro ", count: 1000),
                              summary: String(repeating: "Lo que vi: ñ ", count: 1000))
    #expect(url.absoluteString.count <= ProblemReport.maxURLLength)
}

@Test func installationReportsSayWhereItStopped() {
    var report = sampleReport(logLines: 0)
    report.kind = .install("The installer stopped: “lcid”.")
    #expect(report.summary.contains("lcid"))
    #expect(!report.title.hasSuffix(": "))
    #expect(!report.text.contains(ProblemReport.logHeading))
}

@Test func findsTheNewestInstallationLog() throws {
    let folder = try TemporaryFolder()
    let start = Date()
    let old = folder.url.appendingPathComponent("Instalación - viejo.log")
    let new = folder.url.appendingPathComponent("Instalación - nuevo.log")
    let other = folder.url.appendingPathComponent("Programa.log")
    for file in [old, new, other] { FileManager.default.createFile(atPath: file.path, contents: Data()) }
    try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(-60)], ofItemAtPath: old.path)
    #expect(ProgramInstaller.latestInstallLog(since: start.addingTimeInterval(-1), in: folder.url)?.lastPathComponent == new.lastPathComponent)
    #expect(ProgramInstaller.latestInstallLog(since: start.addingTimeInterval(-120), in: folder.url)?.lastPathComponent == new.lastPathComponent)
    #expect(ProgramInstaller.latestInstallLog(since: start.addingTimeInterval(60), in: folder.url) == nil)
}
