import Foundation

/// Reads the logs WiX Burn bundles (Power BI, many Microsoft installers) leave in the Windows
/// temporary folder, to notice a bundle that keeps installing the same prerequisite: under Wine
/// the .NET Framework installer ends "successfully" without installing anything, the bundle checks
/// again, finds it missing and starts over, forever.
public enum BurnLog {
    /// The package a Burn log shows installed successfully more than once, if any.
    public static func repeatedPackage(in log: String) -> String? {
        var counts: [String: Int] = [:]
        for line in log.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: "Applied execute package: ") else { continue }
            let rest = line[range.upperBound...]
            guard let comma = rest.firstIndex(of: ","), rest.contains("result: 0x0") else { continue }
            let package = String(rest[..<comma])
            counts[package, default: 0] += 1
            if counts[package]! >= 2 { return package }
        }
        return nil
    }

    /// The repeated package in any Burn log of the prefix's temporary folders.
    static func repeatedPackage(driveC: URL) -> String? {
        let fm = FileManager.default
        let users = driveC.appendingPathComponent("users")
        for user in (try? fm.contentsOfDirectory(atPath: users.path)) ?? [] {
            let temp = users.appendingPathComponent(user).appendingPathComponent("AppData/Local/Temp")
            for name in (try? fm.contentsOfDirectory(atPath: temp.path)) ?? [] where name.hasSuffix(".log") {
                guard let data = fm.contents(atPath: temp.appendingPathComponent(name).path),
                      data.count < 20_000_000 else { continue }
                if let package = repeatedPackage(in: String(decoding: data, as: UTF8.self)) { return package }
            }
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
    static func waitForRepeat(driveC: URL) async -> String? {
        while !Task.isCancelled {
            if let package = repeatedPackage(driveC: driveC) { return package }
            try? await Task.sleep(for: .seconds(2))
        }
        return nil
    }
}
