import Foundation

/// Reads the logs WiX Burn bundles (Power BI, many Microsoft installers) leave in the Windows
/// temporary folder, to notice a bundle that keeps installing the same prerequisite: under Wine
/// the .NET Framework installer ends "successfully" without installing anything, the bundle checks
/// again, finds it missing and starts over, forever.
public enum BurnLog {
    /// The package a Burn log shows installed successfully and then missing again (or
    /// installed twice), if any.
    public static func repeatedPackage(in log: String) -> String? {
        var counts: [String: Int] = [:]
        for line in log.split(whereSeparator: \.isNewline) {
            // Detected missing after it was installed: the bundle is starting over.
            if let range = line.range(of: "Detected package: "), line.contains("state: Absent") {
                let rest = line[range.upperBound...]
                if let comma = rest.firstIndex(of: ","), counts[String(rest[..<comma]), default: 0] > 0 {
                    return String(rest[..<comma])
                }
                continue
            }
            guard let range = line.range(of: "Applied execute package: ") else { continue }
            let rest = line[range.upperBound...]
            guard let comma = rest.firstIndex(of: ","), rest.contains("result: 0x0") else { continue }
            let package = String(rest[..<comma])
            counts[package, default: 0] += 1
            if counts[package]! >= 2 { return package }
        }
        return nil
    }

    /// Whether a Burn package is a .NET Framework installer ("NetFx462Web", "NDP48…").
    public static func isDotNetFramework(_ package: String) -> Bool {
        let lower = package.lowercased()
        return lower.hasPrefix("netfx") || lower.hasPrefix("ndp")
    }

    /// The Burn logs in the prefix's temporary folders, relative to drive_c.
    static func logs(driveC: URL) -> Set<String> {
        let fm = FileManager.default
        var found = Set<String>()
        let users = driveC.appendingPathComponent("users")
        for user in (try? fm.contentsOfDirectory(atPath: users.path)) ?? [] {
            let temp = "users/\(user)/AppData/Local/Temp"
            for name in (try? fm.contentsOfDirectory(atPath: driveC.appendingPathComponent(temp).path)) ?? [] where name.hasSuffix(".log") {
                found.insert(temp + "/" + name)
            }
        }
        return found
    }

    /// The repeated package in any Burn log of the prefix's temporary folders, except `ignoring`
    /// (the logs of an earlier run).
    static func repeatedPackage(driveC: URL, ignoring: Set<String> = []) -> String? {
        for log in logs(driveC: driveC).subtracting(ignoring) {
            guard let data = FileManager.default.contents(atPath: driveC.appendingPathComponent(log).path),
                  data.count < 20_000_000 else { continue }
            if let package = repeatedPackage(in: String(decoding: data, as: UTF8.self)) { return package }
        }
        return nil
    }

    /// A name people recognize for a Burn package id ("NetFx462Web" → ".NET Framework 4.6.2").
    public static func friendlyName(_ package: String) -> String {
        let lower = package.lowercased()
        if lower.hasPrefix("netfx") || lower.hasPrefix("ndp") {
            let digits = package.filter(\.isNumber)
            if digits.count >= 2 { return ".NET Framework " + digits.map(String.init).joined(separator: ".") }
            return ".NET Framework"
        }
        if lower.contains("vcredist") || lower.contains("vc_redist") { return "Visual C++ (\(package))" }
        if lower.contains("webview2") { return "Microsoft Edge WebView2" }
        return package
    }

    /// Waits until a Burn bundle repeats a prerequisite; returns it.
    static func waitForRepeat(driveC: URL, ignoring: Set<String> = []) async -> String? {
        while !Task.isCancelled {
            if let package = repeatedPackage(driveC: driveC, ignoring: ignoring) { return package }
            try? await Task.sleep(for: .seconds(2))
        }
        return nil
    }
}
