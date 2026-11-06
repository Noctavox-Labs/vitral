import Foundation

/// A Wine build plus the macOS libraries it loads (fonts, TLS, Vulkan, gamepads…).
public struct WineEngine: Sendable, Equatable {
    public let id: String
    public let name: String
    public let wine: Component
    public let libraries: Component

    public var components: [Component] { [wine, libraries] }
}

/// The engines Vitral knows, each pinned to exact downloads.
///
/// Why CrossOver: the official Wine builds (Gcenx 11.0 and 11.21) crash or hang with 32-bit
/// programs such as Qt 5 apps on macOS, while CrossOver's Wine, which carries patches for that,
/// opens them (tested 2026-11-04). Vitral builds its own from CodeWeavers' LGPL sources
/// (`scripts/build-engine.sh`, run by the Engine workflow) and publishes it in its releases.
public enum EngineCatalog {
    /// Wine from CrossOver 26.3.0 (Wine 11.0 base) with DXMT 0.80 (Direct3D 11 on Metal), built
    /// by Vitral. Opens Qt 5 programs (32-bit) and Electron 37 programs (tested 2026-11-05).
    public static let crossover26 = WineEngine(
        id: "cx26.3.0-1",
        name: "CrossOver 26.3.0 (Wine 11.0) + DXMT 0.80",
        wine: Component(
            id: "wine-cx26.3.0-1",
            name: "Wine (CrossOver 26.3.0, Vitral build, with DXMT 0.80)",
            url: URL(string: "https://github.com/noctavox-labs/vitral/releases/download/engine-cx26.3.0-1/wine-cx26.3.0.tar.xz")!,
            sha256: "a530935ad8f147171cb8faba68e2ed74fcdedf05bb1621ce8c19980702df633e",
            bytes: 91_972_016,
            archiveRoot: "wine-cx26.3.0",
            license: "LGPL-2.1-or-later (Wine), MIT (DXMT); see share/licenses",
            source: URL(string: "https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz")!
        ),
        libraries: gcenxLibraries
    )

    /// Wine from CrossOver 24.0.7 (Wine 9.0 base), built by the Sikarugir project. Kept for the
    /// programs installed with it; it cannot open Electron programs.
    public static let crossover24 = WineEngine(
        id: "cx24.0.7_7",
        name: "CrossOver 24.0.7 (Wine 9.0)",
        wine: Component(
            id: "wine-cx24.0.7_7",
            name: "Wine (CrossOver 24.0.7, Sikarugir build)",
            url: URL(string: "https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineCX24.0.7_7.tar.xz")!,
            sha256: "203f9e9fd6c2cc77e6525d798a434ced326145db34a356355e05659d3445fd1c",
            bytes: 172_348_356,
            archiveRoot: "wswine.bundle",
            license: "LGPL-2.1-or-later (Wine)",
            source: URL(string: "https://media.codeweavers.com/pub/crossover/source/crossover-sources-24.0.7.tar.gz")!
        ),
        libraries: gcenxLibraries
    )

    /// The macOS libraries shipped inside Gcenx's official Wine build (FreeType, GnuTLS,
    /// MoltenVK, SDL2, libinotify, gettext…). Only the `.dylib` files are kept (about 50 MB).
    public static let gcenxLibraries = Component(
        id: "libraries-gcenx-11.0_1",
        name: "Wine libraries (Gcenx wine-stable 11.0_1)",
        url: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.0_1/wine-stable-11.0_1-osx64.tar.xz")!,
        sha256: "b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388",
        bytes: 185_303_032,
        archiveRoot: "Wine Stable.app/Contents/Resources/wine/lib",
        members: ["Wine Stable.app/Contents/Resources/wine/lib/*.dylib"],
        license: "Various (FreeType, LGPL, Apache-2.0, zlib, MIT); see each project",
        source: URL(string: "https://github.com/Gcenx/macOS_Wine_builds")!
    )

    public static let all: [WineEngine] = [crossover26, crossover24]
    public static let `default` = crossover26

    public static func engine(id: String) -> WineEngine? { all.first { $0.id == id } }
}

/// An engine unpacked on this Mac.
public struct InstalledEngine: Sendable {
    public let engine: WineEngine
    public let wineRoot: URL
    public let libraries: URL

    public init(engine: WineEngine, home: VitralHome = .default) {
        self.engine = engine
        self.wineRoot = home.folder(of: engine.wine)
        self.libraries = home.folder(of: engine.libraries)
    }

    public var wine: URL { wineRoot.appendingPathComponent("bin/wine") }
    public var wineserver: URL { wineRoot.appendingPathComponent("bin/wineserver") }

    /// DLL overrides while the prefix is created: no Wine Mono or Gecko download offers.
    public static let prefixCreationOverrides = "winemenubuilder.exe=d;mscoree=d;mshtml=d"

    /// DLL overrides while programs run: no macOS menu entries or file associations for Windows
    /// programs; and no Internet Explorer (MSHTML) unless Wine Gecko is in the prefix, because
    /// Wine would offer to download Gecko and stop there until someone answers. Wine's .NET
    /// loader (mscoree) stays on: .NET 5 and later programs (Paint.NET) need it to load their own
    /// libraries; only creating the prefix turns it off, so wineboot does not offer to download
    /// Wine Mono (`prefixCreationOverrides`). `internetExplorer` turns MSHTML on or off whatever
    /// the prefix has (to register it before Gecko is there).
    public static func dllOverrides(prefix: URL, internetExplorer: Bool? = nil) -> String {
        (internetExplorer ?? WineGecko.isInstalled(prefix: prefix)) ? "winemenubuilder.exe=d" : "winemenubuilder.exe=d;mshtml=d"
    }

    /// Variables every Wine process of this engine needs.
    public func environment(prefix: URL) -> [String: String] {
        [
            "WINEPREFIX": prefix.path,
            // Wine finds its libraries here (it is not on the default search path).
            "DYLD_FALLBACK_LIBRARY_PATH": libraries.path + ":/usr/lib",
            "WINEDEBUG": "err+all,fixme-all",
            // MoltenVK prints every Vulkan extension otherwise.
            "MVK_CONFIG_LOG_LEVEL": "0",
            "WINEDLLOVERRIDES": Self.dllOverrides(prefix: prefix),
        ]
    }
}

/// Facts about this Mac that decide whether Windows programs can run at all.
public enum MacSystem {
    /// Rosetta 2 translates the x86-64 Wine. New Macs do not have it, and macOS does not offer
    /// it on its own for apps with a universal launcher.
    public static var hasRosetta: Bool {
        #if arch(x86_64)
        return true
        #else
        return FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime")
        #endif
    }
}
