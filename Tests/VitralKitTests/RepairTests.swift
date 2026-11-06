import Foundation
import Testing
@testable import VitralKit

private func diagnose(_ log: String, phase: FailurePhase = .start) -> [Diagnosis] {
    Diagnoser.diagnose(FailureObservation(phase: phase, logs: [log], status: 1, sawWindow: false), language: .english)
}

private let noPrefix = URL(fileURLWithPath: "/nonexistent-vitral-prefix")

@Test func qtOpenGLFixesInOrder() {
    let repairs = RepairPlanner.plan(diagnose("Failed to create OpenGL context"), settings: LaunchSettings(), prefix: noPrefix)
    #expect(repairs.map(\.key) == ["qt-opengl#0", "qt-opengl#1"])
    // First the recipe: a variable Wine passes on.
    #expect(repairs[0].settings?.environment == ["QMLSCENE_DEVICE": "softwarecontext"])
    #expect(repairs[0].recipe == AppliedRecipe(id: "qt5-quick-software", because: "qt-opengl"))
    #expect(!repairs[0].changesPrefix)
    // Then QT_OPENGL, which Wine does not pass from the Mac: in the registry.
    #expect(repairs[1].settings?.environment == [:])
    #expect(repairs[1].settings?.registry == [.string(Recipes.windowsEnvironment, "QT_OPENGL", "software")])
    #expect(repairs[1].changesPrefix)
}

@Test func skipsFixesAlreadyInPlaceOrTried() {
    let current = LaunchSettings(environment: ["QMLSCENE_DEVICE": "softwarecontext"])
    let diagnoses = diagnose("Failed to create OpenGL context")
    #expect(RepairPlanner.plan(diagnoses, settings: current, prefix: noPrefix).map(\.key) == ["qt-opengl#1"])
    #expect(RepairPlanner.plan(diagnoses, settings: LaunchSettings(), prefix: noPrefix, tried: ["qt-opengl#0"]).map(\.key) == ["qt-opengl#1"])
    // Electron's argument once: already there, nothing to try.
    let blank = diagnose("err:   CreateSwapChain: cross-process swapchain not supported yet")
    #expect(RepairPlanner.plan(blank, settings: LaunchSettings(arguments: ["--in-process-gpu"]), prefix: noPrefix).isEmpty)
    #expect(RepairPlanner.plan(blank, settings: LaunchSettings(), prefix: noPrefix).first?.settings?.arguments == ["--in-process-gpu"])
}

@Test func onlyFixableFailuresGetRepairs() {
    // A newer engine, a library Vitral does not install, a crash to retry: nothing to try here.
    let log = """
        [1234:5678:ERROR:crashpad_client_win.cc(869)] not connected
        Library MSVCP140.dll (which is needed by L"C:\\\\x.exe") not found
        wine: Unhandled page fault on read access to 00000000
        """
    #expect(!diagnose(log).isEmpty)
    #expect(RepairPlanner.plan(diagnose(log), settings: LaunchSettings(), prefix: noPrefix).isEmpty)
}

@Test func offersDotNetOnlyWhenMissing() throws {
    let log = "0024:err:module:import_dll Library mscoree.dll (which is needed by L\"C:\\\\app.exe\") not found"
    let repairs = RepairPlanner.plan(diagnose(log), settings: LaunchSettings(), prefix: noPrefix)
    #expect(repairs.map(\.component) == ["dotnet48"])
    #expect(repairs.first?.recipe.id == "dotnet-framework-4.8")
    #expect(repairs.first?.changesPrefix == true)
}

@Test func recipesAreTheSameFragments() {
    // Adding a recipe twice changes nothing; another value for the same registry entry replaces it.
    let retina = Recipes.fragment("qt5-retina")!
    let once = LaunchSettings().adding(retina)
    #expect(once.adding(retina) == once)
    let other = LaunchSettings(registry: [.string(Recipes.windowsEnvironment, "QT_SCALE_FACTOR", "1")])
    #expect(once.adding(other).registry.filter { $0.name == "QT_SCALE_FACTOR" }.map(\.value) == ["1"])
    #expect(LaunchSettings().registryMissing(from: once) == once.registry)
    #expect(Recipes.fragment("dotnet-framework-4.8") == nil)
}

@Test func registryCopyGoesBack() throws {
    let folder = try TemporaryFolder()
    let home = VitralHome(url: folder.url.appendingPathComponent("home"))
    let prefix = home.prefixes.appendingPathComponent("app")
    try folder.write("home/Prefixes/app/user.reg", Data("antes".utf8))
    try folder.write("home/Prefixes/app/system.reg", Data("sistema".utf8))
    try folder.write("home/Prefixes/app/drive_c/file.txt", Data("archivo".utf8))

    let backup = try PrefixBackup.make(of: prefix, scope: .registry, home: home)
    try Data("después".utf8).write(to: prefix.appendingPathComponent("user.reg"))
    try Data("cambiado".utf8).write(to: prefix.appendingPathComponent("drive_c/file.txt"))
    #expect(PrefixBackup.leftovers(of: prefix, home: home).map(\.lastPathComponent) == [backup.copy.lastPathComponent])
    try backup.restore()
    #expect(try String(contentsOf: prefix.appendingPathComponent("user.reg"), encoding: .utf8) == "antes")
    #expect(try String(contentsOf: prefix.appendingPathComponent("system.reg"), encoding: .utf8) == "sistema")
    // Only the registry goes back.
    #expect(try String(contentsOf: prefix.appendingPathComponent("drive_c/file.txt"), encoding: .utf8) == "cambiado")
    #expect(PrefixBackup.leftovers(of: prefix, home: home).isEmpty)
}

@Test func wholeCopyGoesBackWithItsLinks() throws {
    let folder = try TemporaryFolder()
    let home = VitralHome(url: folder.url.appendingPathComponent("home"))
    let prefix = home.prefixes.appendingPathComponent("app")
    try folder.write("home/Prefixes/app/user.reg", Data("antes".utf8))
    try folder.write("outside/Documents/private.txt", Data("de la persona".utf8))
    let link = prefix.appendingPathComponent("drive_c/users/crossover/Documents")
    try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder.url.appendingPathComponent("outside/Documents"))

    let backup = try PrefixBackup.make(of: prefix, scope: .everything, home: home)
    try folder.write("home/Prefixes/app/drive_c/windows/Microsoft.NET/new.dll", Data("nuevo".utf8))
    try Data("después".utf8).write(to: prefix.appendingPathComponent("user.reg"))
    try backup.restore()

    let fm = FileManager.default
    #expect(try String(contentsOf: prefix.appendingPathComponent("user.reg"), encoding: .utf8) == "antes")
    #expect(!fm.fileExists(atPath: prefix.appendingPathComponent("drive_c/windows/Microsoft.NET/new.dll").path))
    // The link is still a link, and what it points to was not copied or touched.
    #expect((try? fm.destinationOfSymbolicLink(atPath: link.path)) == folder.url.appendingPathComponent("outside/Documents").path)
    #expect(try String(contentsOf: folder.url.appendingPathComponent("outside/Documents/private.txt"), encoding: .utf8) == "de la persona")
    #expect(PrefixBackup.leftovers(of: prefix, home: home).isEmpty)
    #expect((try fm.contentsOfDirectory(atPath: home.url.appendingPathComponent("Staging").path)).isEmpty)
}

@Test func savingAManifestKeepsTheAppSigned() throws {
    let folder = try TemporaryFolder()
    let app = Wrapper(url: folder.url.appendingPathComponent("Ejemplo.app"))
    let manifest = WrapperManifest(name: "Ejemplo", program: "Program Files/Ejemplo/ejemplo.exe", engine: "cx-test",
                                   settings: LaunchSettings())
    try app.write(manifest: manifest, icns: nil, launcher: URL(fileURLWithPath: "/usr/bin/true"), bundleIdentifier: "com.example.test")
    var changed = manifest
    changed.settings.environment["QMLSCENE_DEVICE"] = "softwarecontext"
    changed.recipes.append(AppliedRecipe(id: "qt5-quick-software", because: "qt-opengl"))
    try app.save(changed)
    let saved = try app.readManifest()
    #expect(saved.settings == changed.settings && saved.recipes == changed.recipes)
    #expect(app.hasValidSignature)
}
