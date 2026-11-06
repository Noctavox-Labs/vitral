import Foundation

/// "Force Quit" for an app Vitral made, when its program hung or does not close (see
/// `WineSession.forceQuit`).
public enum ForceQuit {
    /// Ends every Windows process of the app's prefix: the program, what it left running, and
    /// the other programs of its installer, which share the prefix. Returns whether none is left.
    public static func quit(_ app: URL, home: VitralHome = .default) async throws -> Bool {
        let wrapper = Wrapper(url: app)
        let manifest = try wrapper.readManifest()
        let engine = EngineCatalog.engine(id: manifest.engine) ?? EngineCatalog.default
        let session = WineSession(engine: InstalledEngine(engine: engine, home: home), prefix: wrapper.prefix(in: home))
        return await session.forceQuit()
    }
}
