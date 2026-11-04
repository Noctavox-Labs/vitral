import Foundation

/// Facts about this Mac.
public struct MacInfo: Sendable {
    /// "Apple M1 Pro", "Apple A18 Pro"…
    public let chip: String
    public let isAppleSilicon: Bool
    public let memoryBytes: UInt64
    public let macOSVersion: OperatingSystemVersion
    /// Space available for important files in the user's home volume.
    public let freeBytes: Int64?
    public let hasRosetta: Bool

    public static func current() -> MacInfo {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let free = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        return MacInfo(
            chip: sysctlString("machdep.cpu.brand_string") ?? "Mac",
            isAppleSilicon: sysctlInt("hw.optional.arm64") == 1,
            memoryBytes: UInt64(sysctlInt("hw.memsize") ?? 0),
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersion,
            freeBytes: free,
            hasRosetta: MacSystem.hasRosetta
        )
    }

    public var macOSVersionText: String {
        let v = macOSVersion
        return v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)" : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func sysctlInt(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return size == 4 ? Int64(Int32(truncatingIfNeeded: value)) : value
    }
}

/// One requirement for running Windows programs, and whether this Mac meets it.
public struct Requirement: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case appleSilicon, macOS, memory, rosetta, diskSpace, engine
    }

    public enum Status: Sendable, Equatable {
        case ok
        /// Works, but the person should know something.
        case warning
        /// Vitral can fix it (install Rosetta, download the engine).
        case fixable
        /// Vitral cannot fix it.
        case blocking
    }

    public let kind: Kind
    public let status: Status
    /// What was found, ready to show ("Apple M1 Pro", "16 GB", "72 GB libres").
    public let detail: String
    public var id: String { kind.rawValue }
}

/// Everything a fresh Mac needs before Vitral can install Windows programs.
public enum SystemCheck {
    /// Space for the engine (about 600 MB unpacked) plus a Windows prefix and a program.
    public static let neededFreeBytes: Int64 = 3_000_000_000
    public static let minimumMacOS = 14
    /// Apple keeps Rosetta for general use up to macOS 27 (see PLAN, risk 1).
    public static let lastMacOSWithRosetta = 27

    public static func requirements(
        mac: MacInfo = .current(),
        engineInstalled: Bool,
        language: Language = .current
    ) -> [Requirement] {
        func t(_ es: String, _ en: String) -> String { tr(es, en, language) }
        let gb = Double(mac.memoryBytes) / 1_073_741_824

        return [
            Requirement(
                kind: .appleSilicon,
                status: mac.isAppleSilicon ? .ok : .warning,
                detail: mac.isAppleSilicon ? mac.chip : t("\(mac.chip) (Intel: sin soporte oficial)", "\(mac.chip) (Intel: not officially supported)")
            ),
            Requirement(
                kind: .macOS,
                status: mac.macOSVersion.majorVersion < minimumMacOS ? .blocking
                    : mac.macOSVersion.majorVersion > lastMacOSWithRosetta ? .warning : .ok,
                detail: "macOS \(mac.macOSVersionText)"
            ),
            Requirement(
                kind: .memory,
                status: gb < 8 ? .warning : .ok,
                detail: "\(Int(gb.rounded())) GB"
            ),
            Requirement(
                kind: .rosetta,
                status: mac.hasRosetta ? .ok : .fixable,
                detail: mac.hasRosetta ? t("Instalada", "Installed") : t("Falta", "Missing")
            ),
            Requirement(
                kind: .diskSpace,
                status: (mac.freeBytes ?? .max) < neededFreeBytes ? .blocking : .ok,
                detail: mac.freeBytes.map {
                    t("\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) libres",
                      "\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) free")
                } ?? "?"
            ),
            Requirement(
                kind: .engine,
                status: engineInstalled ? .ok : .fixable,
                detail: engineInstalled ? EngineCatalog.default.name : t("Sin descargar", "Not downloaded")
            ),
        ]
    }
}
