import Foundation

/// Removes a Windows program installed with Vitral: its app (Windows and the program live inside
/// it) and its logs go to the Trash, so they can be put back. The person's own files are not
/// touched: the prefix's Documents, Downloads, Music, Pictures and Videos are links to the Mac's
/// folders, and moving the app moves the links, never what they point to.
public struct Uninstaller: Sendable {
    public var home: VitralHome
    public var logs: URL
    /// Moves an item to the Trash. Tests replace it.
    public var trash: @Sendable (URL) throws -> Void

    public init(home: VitralHome = .default, logs: URL = ProgramInstaller.logs,
                trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.home = home
        self.logs = logs
        self.trash = trash
    }

    /// What uninstalling `app` sends to the Trash: the app, then its logs. The launcher names its
    /// logs after the app ("aTube Catcher 2.log"); the installation log, after the installer, so it
    /// stays if another installed app came from the same installer.
    public func items(for app: URL) throws -> [URL] {
        let manifest = try Wrapper(url: app).readManifest()
        let fm = FileManager.default
        let others = Self.otherManifests(besides: app)

        let base = Wrapper.safeName(app.deletingPathExtension().lastPathComponent)
        var items = [app]
        // Its Windows, when it lives outside the app (apps made since Vitral 0.1.1) and no other
        // app opens a program of it (suites: MetaTrader 5 and MetaEditor share one).
        if manifest.prefix != nil, !Self.sharesWindows(app, manifest: manifest, others: others) {
            items.append(Wrapper(url: app).prefix(in: home))
        }
        items += [base + ".log", base + " (anterior).log"].map { logs.appendingPathComponent($0) }
        if let installer = manifest.installer.map(Self.installLogName),
           !others.contains(where: { $0.installer.map(Self.installLogName) == installer }) {
            items.append(logs.appendingPathComponent(installer))
        }
        return items.filter { fm.fileExists(atPath: $0.path) }
    }

    /// Closes the program if it is open, then sends the app and its logs to the Trash.
    /// Returns what went to the Trash.
    @discardableResult
    public func uninstall(_ app: URL) async throws -> [URL] {
        let items = try items(for: app)
        let manifest = try Wrapper(url: app).readManifest()
        if let engine = EngineCatalog.engine(id: manifest.engine),
           ComponentInstaller(home: home).isInstalled(engine.wine),
           !Self.sharesWindows(app, manifest: manifest, others: Self.otherManifests(besides: app)) {
            // Ends every Windows process of this app's prefix (and only that prefix).
            await WineSession(engine: InstalledEngine(engine: engine, home: home), prefix: Wrapper(url: app).prefix(in: home)).killServer()
        }
        for item in items { try trash(item) }
        return items
    }

    /// Uninstalls `app` and every other app on its Windows (the programs of one installer, such as
    /// MetaTrader 5 and MetaEditor). The last one takes the Windows with it.
    @discardableResult
    public func uninstallWithCompanions(_ app: URL) async throws -> [URL] {
        var trashed: [URL] = []
        for other in Self.companions(of: app) { trashed += try await uninstall(other) }
        trashed += try await uninstall(app)
        return trashed
    }

    /// The other apps in the same folder that open a program of the same Windows.
    public static func companions(of app: URL) -> [URL] {
        guard let prefix = (try? Wrapper(url: app).readManifest())?.prefix else { return [] }
        let folder = app.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".app") }.sorted()
            .map { folder.appendingPathComponent($0) }
            .filter { $0.standardizedFileURL != app.standardizedFileURL }
            .filter { (try? Wrapper(url: $0).readManifest())?.prefix == prefix }
    }

    /// Whether another app opens a program of the same Windows.
    static func sharesWindows(_ app: URL, manifest: WrapperManifest, others: [WrapperManifest]) -> Bool {
        guard let prefix = manifest.prefix else { return false }
        return others.contains { $0.prefix == prefix }
    }

    /// Name of the installation log Vitral writes for an installer file.
    static func installLogName(_ installer: String) -> String {
        "Instalación - " + Wrapper.safeName((installer as NSString).deletingPathExtension) + ".log"
    }

    /// Manifests of the other Vitral apps in the same folder.
    static func otherManifests(besides app: URL) -> [WrapperManifest] {
        let folder = app.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".app") }
            .map { folder.appendingPathComponent($0) }
            .filter { $0.standardizedFileURL != app.standardizedFileURL }
            .compactMap { try? Wrapper(url: $0).readManifest() }
    }
}

/// Which installed engine pieces the apps still use.
public enum EngineUsage {
    /// Installed components that neither the recommended engine nor any app in `apps` uses.
    /// Each can be downloaded again if a program needs it later.
    public static func unusedComponents(home: VitralHome = .default,
                                        apps: URL = InstallOptions.defaultDestination) -> [Component] {
        let installer = ComponentInstaller(home: home)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: apps.path)) ?? []
        let usedEngines = Set(names.filter { $0.hasSuffix(".app") }
            .compactMap { try? Wrapper(url: apps.appendingPathComponent($0)).readManifest().engine })
            .union([EngineCatalog.default.id])
        let used = Set(EngineCatalog.all.filter { usedEngines.contains($0.id) }.flatMap(\.components).map(\.id))
        var seen = Set<String>()
        return EngineCatalog.all.flatMap(\.components)
            .filter { seen.insert($0.id).inserted && !used.contains($0.id) && installer.isInstalled($0) }
    }

    /// Deletes those components (they are downloads, not the person's data). Returns the bytes freed.
    @discardableResult
    public static func removeUnused(home: VitralHome = .default,
                                    apps: URL = InstallOptions.defaultDestination) throws -> Int64 {
        var freed: Int64 = 0
        for component in unusedComponents(home: home, apps: apps) {
            let folder = home.folder(of: component)
            freed += folderSize(folder)
            try FileManager.default.removeItem(at: folder)
        }
        return freed
    }

    /// Bytes of the regular files under a folder, without following links.
    public static func folderSize(_ folder: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }
}
