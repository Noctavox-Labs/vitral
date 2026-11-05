import Foundation

/// The log Inno Setup installers write when started with `/LOG=<file>`: when one stops before
/// showing anything (its own checks in `InitializeSetup` failed), it says why.
public enum InnoSetupLog {
    /// Where Vitral asks for it, inside the prefix.
    static let windowsPath = #"C:\windows\temp\vitral-inno-setup.log"#

    static func file(driveC: URL) -> URL { driveC.appendingPathComponent("windows/temp/vitral-inno-setup.log") }

    /// The message of a fatal error in the installer's checks, if the log has one.
    static func fatalError(driveC: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: file(driveC: driveC).path) else { return nil }
        return fatalError(in: String(decoding: data, as: UTF8.self))
    }

    public static func fatalError(in log: String) -> String? {
        let lines = log.split(whereSeparator: \.isNewline).map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains("InitializeSetup raised an exception (fatal)") }) else { return nil }
        // The message follows "Exception message:", indented, until "Deinitializing Setup.".
        var message: [String] = []
        for line in lines[(start + 1)...] {
            if line.contains("Deinitializing Setup") || line.contains("Log closed") { break }
            if line.contains("Exception message:") || line.contains("Defaulting to") || line.contains("Message box (")
                || line.contains("User chose") { continue }
            let text = line.replacingOccurrences(of: #"^\d{4}-\d\d-\d\d [\d:.]+\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { message.append(text) }
        }
        return message.isEmpty ? "InitializeSetup" : message.joined(separator: " ")
    }
}
