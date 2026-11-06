import CryptoKit
import Foundation
import Testing
@testable import VitralKit

private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func catalogJSON(revision: Int, format: Int = 1, entries: String = "") -> Data {
    Data("""
    {"format": \(format), "revision": \(revision), "entries": [
      {"id": "ejemplo", "kind": "fixable", "title": {"es": "Ejemplo", "en": "Example"},
       "explanation": {"es": "E", "en": "E"}, "when": [{"log": ["ejemplo falla"]}],
       "fixes": [{"arguments": ["--ejemplo"]}]}\(entries.isEmpty ? "" : ",\n" + entries)
    ]}
    """.utf8)
}

private func signed(_ data: Data, with key: Curve25519.Signing.PrivateKey) throws -> Data {
    try JSONEncoder().encode(SignedCatalog(catalog: data, signature: key.signature(for: data)))
}

// MARK: The published catalog

@Test func theBuiltInCatalogIsTheRepositorysFile() throws {
    // scripts/embed-catalog.py copies it; forgetting to run it fails here.
    let file = try Data(contentsOf: repository.appendingPathComponent("catalog/failures.json"))
    #expect(try FailureCatalog.decode(file) == FailureCatalog.builtIn)
    #expect(String(decoding: file, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            == FailureCatalog.builtInJSON.trimmingCharacters(in: .whitespacesAndNewlines))
}

@Test func signsWithSparklesReleaseKey() throws {
    let project = try String(contentsOf: repository.appendingPathComponent("project.yml"), encoding: .utf8)
    #expect(project.contains("SUPublicEDKey: \(CatalogStore.publicKey)"))
}

@Test func thePublishedCatalogIsSignedAndCurrent() throws {
    let url = repository.appendingPathComponent("catalog/failures.signed.json")
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let published = try JSONDecoder().decode(SignedCatalog.self, from: Data(contentsOf: url)).verified(publicKey: CatalogStore.publicKey)
    // Never behind the code: a Vitral built from here must not read an older catalog as newer.
    #expect(published.revision <= FailureCatalog.builtIn.revision)
}

// MARK: Signature

@Test func onlyTheReleaseKeysSignatureCounts() throws {
    let key = Curve25519.Signing.PrivateKey()
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    let data = catalogJSON(revision: 2099010101)
    let envelope = try JSONDecoder().decode(SignedCatalog.self, from: signed(data, with: key))
    #expect(try envelope.verified(publicKey: publicKey).revision == 2099010101)

    // Another key.
    #expect(throws: CatalogError.badSignature) {
        try envelope.verified(publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString())
    }
    // A changed catalog with the old signature.
    var changed = data
    changed[changed.startIndex + 30] ^= 1
    let forged = SignedCatalog(catalog: changed, signature: Data(base64Encoded: envelope.signature)!)
    #expect(throws: CatalogError.badSignature) { try forged.verified(publicKey: publicKey) }
}

@Test func usesTheNewestCatalogAtHand() throws {
    let folder = try TemporaryFolder()
    let key = Curve25519.Signing.PrivateKey()
    let store = CatalogStore(home: VitralHome(url: folder.url), publicKey: key.publicKey.rawRepresentation.base64EncodedString())
    #expect(store.best() == .builtIn)
    #expect(store.isDue(every: 3600))

    // Older than the one Vitral came with: kept, not used.
    try store.accept(signed(catalogJSON(revision: 2000010101), with: key))
    #expect(store.best() == .builtIn)
    #expect(!store.isDue(every: 3600))

    // Newer: used.
    try store.accept(signed(catalogJSON(revision: 2099010101), with: key))
    #expect(store.best().revision == 2099010101)
    #expect(store.best().entries.map(\.id) == ["ejemplo"])

    // An older one later does not replace it.
    try store.accept(signed(catalogJSON(revision: 2098010101), with: key))
    #expect(store.best().revision == 2099010101)

    // A file changed on disk is not used.
    var data = try Data(contentsOf: store.file)
    data[data.startIndex + 20] ^= 1
    try data.write(to: store.file)
    #expect(store.best() == .builtIn)
}

// MARK: Catalogs for a newer Vitral

@Test func leavesOutWhatItCannotReadInFull() throws {
    let entries = """
      {"id": "nuevo-tipo", "kind": "someNewKind", "title": {"es": "A", "en": "A"}, "when": [{"log": ["x"]}]},
      {"id": "nueva-condicion", "kind": "fixable", "title": {"es": "B", "en": "B"},
       "when": [{"log": ["y"], "processRepeats": 5}], "fixes": [{"arguments": ["--b"]}]},
      {"id": "nuevo-arreglo", "kind": "fixable", "title": {"es": "C", "en": "C"},
       "when": [{"log": ["z"]}], "fixes": [{"dllOverride": {"d3d11": "native"}}]}
    """
    let catalog = try FailureCatalog.decode(catalogJSON(revision: 1, entries: entries))
    // Read in part, "nueva-condicion" would match any line with "y".
    #expect(catalog.entries.map(\.id) == ["ejemplo"])
    #expect(throws: CatalogError.newerFormat(2)) { try FailureCatalog.decode(catalogJSON(revision: 1, format: 2)) }
}

// MARK: Fixes that did not help

@Test func remembersFixesThatDidNotHelpUntilSomethingChanges() throws {
    let folder = try TemporaryFolder()
    let url = RepairHistory.url(app: URL(fileURLWithPath: "/Applications/Shape it! 2.app"), prefix: folder.url)
    #expect(url.path.hasSuffix("/.vitral/Shape it! 2 - arreglos probados.json"))
    var history = RepairHistory.load(from: url)
    history.record("qt-opengl#0", outcome: .notEnough, revision: 5, engine: "cx26")
    history.record("dotnet-framework-missing#0", outcome: .declined, revision: 5, engine: "cx26")
    try history.save(to: url)

    let loaded = RepairHistory.load(from: url)
    #expect(loaded.entries.map(\.key) == history.entries.map(\.key) && loaded.entries.map(\.outcome) == [.notEnough, .declined])
    #expect(loaded.tried(revision: 5, engine: "cx26") == ["qt-opengl#0", "dotnet-framework-missing#0"])
    // Another catalog or engine: try again.
    #expect(loaded.tried(revision: 6, engine: "cx26").isEmpty)
    #expect(loaded.tried(revision: 5, engine: "cx27").isEmpty)
    history.forget("qt-opengl#0")
    #expect(history.tried(revision: 5, engine: "cx26") == ["dotnet-framework-missing#0"])
}

// MARK: Known programs

@Test func knownProgramsGetTheirFixWhenTheAppIsMade() throws {
    let entries = """
      {"id": "programa-conocido", "kind": "fixable", "title": {"es": "P", "en": "P"},
       "when": [{"phase": ["analysis", "start"], "product": "(?i)^Ejemplo Studio 4\\\\."}],
       "fixes": [{"recipe": "electron-in-process-gpu"}, {"arguments": ["--otro"]}]}
    """
    let catalog = try FailureCatalog.decode(catalogJSON(revision: 1, entries: entries))
    var product = VersionInfo()
    product.productName = "Ejemplo Studio"
    product.productVersion = "4.2"
    let names = RepairPlanner.names(of: product, installer: "ejemplo-setup.exe")
    #expect(names == ["ejemplo-setup.exe", "Ejemplo Studio 4.2"])

    let known = RepairPlanner.knownProgram(names: names, settings: LaunchSettings(), catalog: catalog)
    // Only the first fix; the others stay for the launcher if it still does not open.
    #expect(known.settings.arguments == ["--in-process-gpu"])
    #expect(known.applied == [AppliedRecipe(id: "electron-in-process-gpu", because: "programa-conocido")])
    // Other programs, and failures seen only in logs, change nothing.
    #expect(RepairPlanner.knownProgram(names: ["otro.exe"], settings: LaunchSettings(), catalog: catalog).applied.isEmpty)
    #expect(RepairPlanner.knownProgram(names: names, settings: LaunchSettings(), catalog: .builtIn).applied.isEmpty)
}
