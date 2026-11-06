import Foundation
import Testing
@testable import VitralKit

@Test func messageBoxesFromWinesLog() {
    // As Vitral's engine writes them (engine-patches/0008), and as others do (text only).
    let log = #"""
        00cc:err:ntoskrnl:ZwLoadDriver failed to create driver L"\\Registry\\Machine\\System"
        0100:trace:msgbox:MSGBOX_OnInit L"Application cannot start.\r\nRuta: C:\\x" caption L"Microsoft Encarta" style 0x30
        0104:trace:msgbox:MSGBOX_OnInit L"\00bfGuardar los cambios?" caption L"Bloc" style 0x23
        0108:trace:msgbox:MSGBOX_OnInit L"Listo" caption L"Copia" style 0x40
        010c:trace:msgbox:MSGBOX_OnInit L"Sin icono" caption L"" style 0
        0110:trace:msgbox:MSGBOX_OnInit L"Only the text, from an older engine"
        0114:trace:msgbox:MSGBOX_OnInit L"A very long text"... caption L"Cut \"quoted\"" style 0x1010
        """#
    let boxes = WineMessageBox.all(in: log)
    #expect(boxes.count == 6)
    #expect(boxes[0] == WineMessageBox(text: "Application cannot start.\r\nRuta: C:\\x", caption: "Microsoft Encarta", style: 0x30))
    #expect(boxes[0].icon == .warning && boxes[0].isError)
    #expect(boxes[0].summary == #"Microsoft Encarta: Application cannot start. Ruta: C:\x"#)
    #expect(boxes[1].text == "¿Guardar los cambios?" && boxes[1].icon == .question && !boxes[1].isError)
    #expect(boxes[2].icon == .information && !boxes[2].isError)
    #expect(boxes[3].style == 0 && boxes[3].icon == WineMessageBox.Icon.none && boxes[3].isError)
    #expect(boxes[3].summary == "Sin icono")
    #expect(boxes[4] == WineMessageBox(text: "Only the text, from an older engine"))
    #expect(boxes[4].icon == nil && boxes[4].isError)
    #expect(boxes[5].truncated && boxes[5].caption == #"Cut "quoted""# && boxes[5].icon == .error)
    #expect(boxes[5].summary == #"Cut "quoted": A very long text…"#)
    #expect(WineMessageBox.all(in: "0024:err:module:import_dll Library x.dll not found").isEmpty)
    // What a program says in a box is one of the useful lines of a report.
    #expect(LogExcerpt.priority(of: "0100:trace:msgbox:MSGBOX_OnInit L\"x\"") == 0)
    #expect(LogExcerpt.priority(of: "0100:trace:module:load_dll x") == nil)
}

@Test func errorBoxesAreNotTheProgramsWindow() {
    let owner = WineWindows.Owner(pid: 42, name: "ENCARTA.EXE")
    func window(_ number: Int, _ width: Double, _ height: Double, layer: Int = 0) -> WineWindows.Window {
        WineWindows.Window(number: number, owner: owner, layer: layer, width: width, height: height)
    }
    let error = WineMessageBox(text: "Application cannot start.", caption: "Encarta", style: 0x30)
    let start = Date()
    var boxes = StartupBoxes()

    // Written before it shows: waiting, and nothing is the program's yet.
    #expect(boxes.look(at: [], newBoxes: [error], now: start).window == nil)
    #expect(boxes.busy(now: start))
    // A system-modal box is above the normal layer; it is the box, not the program.
    let box = window(7, 300, 120, layer: 21)
    let seen = boxes.look(at: [box], newBoxes: [], now: start + 0.5)
    #expect(seen.window == nil && seen.boxes.map(\.0) == [error])
    #expect(boxes.shown == [error] && boxes.lastShowing == start + 0.5)
    // Only boxes, and then it closed: however long the box stayed.
    #expect(boxes.closedOnBox(started: start, opened: false, end: start + 300))
    // Its main window after the box, and it went on: the program opened.
    #expect(boxes.look(at: [window(9, 1500, 900)], newBoxes: [], now: start + 5).window?.number == 9)
    #expect(!boxes.busy(now: start + 11))
    #expect(!boxes.closedOnBox(started: start, opened: true, end: start + 600))

    // Encarta 2009: a splash screen, then the box; OK closes it.
    var splash = StartupBoxes()
    #expect(splash.look(at: [window(1, 225, 400)], newBoxes: [], now: start + 3).window?.number == 1)
    _ = splash.look(at: [window(1, 225, 400), window(2, 323, 173)], newBoxes: [error], now: start + 4)
    _ = splash.look(at: [window(1, 225, 400), window(2, 323, 173)], newBoxes: [], now: start + 42)
    #expect(splash.busy(now: start + 43))
    #expect(splash.closedOnBox(started: start, opened: true, end: start + 43))
    // The same, but it carried on after OK for a while: not because of the box.
    #expect(!splash.closedOnBox(started: start, opened: true, end: start + 120))
    // A box first shown once the program was well under way does not count.
    var later = StartupBoxes()
    _ = later.look(at: [window(1, 1500, 900)], newBoxes: [], now: start + 3)
    _ = later.look(at: [window(1, 1500, 900), window(2, 323, 173)], newBoxes: [error], now: start + 90)
    #expect(!later.closedOnBox(started: start, opened: true, end: start + 91))

    // A box and the main window at once: the smaller one is the box.
    var together = StartupBoxes()
    let both = together.look(at: [window(1, 1500, 900), window(2, 300, 120)], newBoxes: [error], now: start)
    #expect(both.window?.number == 1 && both.boxes.map(\.1.number) == [2])

    // A question is a window of the program, as before.
    var question = StartupBoxes()
    let asked = question.look(at: [window(3, 300, 120)], newBoxes: [WineMessageBox(text: "Save?", style: 0x24)], now: start)
    #expect(asked.window?.number == 3 && question.shown.isEmpty)

    // A box no window of the program took (another process's) is dropped after a while.
    var other = StartupBoxes()
    _ = other.look(at: [], newBoxes: [error], now: start)
    #expect(other.look(at: [window(4, 1500, 900)], newBoxes: [], now: start + 10).window?.number == 4)
    #expect(other.shown.isEmpty)
}

@Test func errorBoxThenClosedIsAFailedStart() {
    // Encarta's "Application cannot start" stayed 43 s and ended with status 0.
    #expect(StartupWatch.failedToStart(ranFor: 43, sawWindow: false, status: 0, log: "", errorBox: true))
    #expect(!StartupWatch.failedToStart(ranFor: 43, sawWindow: false, status: 0, log: ""))
    #expect(!StartupWatch.failedToStart(ranFor: 3, sawWindow: true, status: 1, log: "", errorBox: true))
    // The same box would show again: no new attempt.
    #expect(!StartupWatch.shouldRetry(ranFor: 2, sawWindow: false, log: "Unhandled page fault", attempt: 1, errorBox: true))
    #expect(StartupWatch.shouldRetry(ranFor: 2, sawWindow: false, log: "Unhandled page fault", attempt: 1))

    let log = """
        [Vitral 10:38:20] Vitral 0.1.7 · Encarta Premium DVD 2009 · ENCARTA.EXE · cx26.3.0-2
        [Vitral 10:37:00] Opening (attempt 1)…
        0100:trace:msgbox:MSGBOX_OnInit L"Older run" caption L"Encarta" style 0x10
        [Vitral 10:37:05] Ended after 5 s (status 0, window: yes)
        [Vitral 10:38:20] Opening (attempt 1)…
        0100:trace:msgbox:MSGBOX_OnInit L"Application cannot start." caption L"Microsoft Encarta" style 0x30
        0100:trace:msgbox:MSGBOX_OnInit L"Seguro?" caption L"Encarta" style 0x24
        [Vitral 10:38:24] Error box after 4.2 s: «Microsoft Encarta: Application cannot start.»
        [Vitral 10:39:04] Ended after 43 s (status 0, window: no, error box: yes)
        """
    let run = LaunchLog.lastRun(in: log)
    #expect(run == LaunchLog.Run(seconds: 43, status: 0, sawWindow: false, errorBox: true,
                                 messageBoxes: [WineMessageBox(text: "Application cannot start.", caption: "Microsoft Encarta", style: 0x30)]))
    #expect(run.map(LaunchLog.failedToStart) == true)
    let spanish = LaunchLog.lastRun(in: "[Vitral] Abriendo (intento 2)…\n[Vitral] Terminó a los 40 s (código 0, ventana: no, cuadro de error: sí)")
    #expect(spanish?.errorBox == true && spanish?.messageBoxes == [])
}

@Test func reportSaysWhatTheBoxSaid() {
    let report = ProblemReport(kind: .errorBox("Encarta: Application cannot start."), productName: "Encarta",
                               program: "Encarta 16.0", mac: "Mac", facts: [], log: [], logFile: nil)
    #expect(report.title == tr("Encarta 16.0: muestra un error al abrir", "Encarta 16.0: shows an error while opening"))
    #expect(report.summary.hasSuffix("«Encarta: Application cannot start.»"))
    // Personal data goes out of the box's text too.
    let privacy = PrivateData(home: "/Users/ana", userName: "ana", fullName: "Ana Pérez", computerName: nil)
    let finished = ProblemReporter.finish(ProblemReport(kind: .errorBox(#"No se encontró C:\users\ana\x.dat"#), productName: "X",
                                                        program: "X", mac: "Mac", facts: [], log: [], logFile: nil), privacy: privacy)
    #expect(finished.kind != .errorBox(#"No se encontró C:\users\ana\x.dat"#))
}
