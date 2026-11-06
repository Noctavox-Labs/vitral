import Foundation

/// What an installer is doing right now, read from the Windows processes it started: "Installing
/// MSXML 6 (MSXML6_X64.MSI)", "Preparing .NET Framework: System.Windows.Forms". Vitral shows it
/// under its progress bar, because the installer's own windows do not always say it: they may be
/// hidden, have no progress bar, or show their text cut under Wine (Encarta 2009's status window
/// draws its text before growing to fit it, and Wine only shows what fit at first).
public enum InstallerActivity {
    /// A Windows process: its file name and its command line (`arguments[0]` is the program).
    public struct Process: Sendable, Equatable {
        public let pid: pid_t
        public let name: String
        public let arguments: [String]

        public init(pid: pid_t, name: String, arguments: [String]) {
            self.pid = pid
            self.name = name
            self.arguments = arguments
        }
    }

    /// The current step in the prefix, or nil if nothing says more than "the installer is open".
    public static func current(prefix: URL, installer: String) -> String? {
        describe(WineProcesses.commandLines(prefix: prefix), installer: installer)
    }

    /// The newest process that says what is happening (the one started last is the deepest step).
    static func describe(_ processes: [Process], installer: String) -> String? {
        for process in processes.sorted(by: { $0.pid > $1.pid }) {
            if let step = describe(process, installer: installer) { return step }
        }
        return nil
    }

    static func describe(_ process: Process, installer: String) -> String? {
        let name = process.name.lowercased()
        let arguments = Array(process.arguments.dropFirst())
        switch name {
        case "ngen.exe":
            // "ngen.exe install System.Windows.Forms, Version=2.0.0.0, …"
            guard let index = arguments.firstIndex(where: { $0.lowercased() == "install" }), index + 1 < arguments.count else {
                return tr("Preparando .NET Framework…", "Preparing .NET Framework…")
            }
            let assembly = arguments[(index + 1)...].joined(separator: " ").split(separator: ",").first.map(String.init) ?? ""
            return tr("Preparando .NET Framework: \(assembly)…", "Preparing .NET Framework: \(assembly)…")
        case "msiexec.exe":
            guard let index = arguments.firstIndex(where: { ["/i", "-i", "/package", "/p", "/update"].contains($0.lowercased()) }),
                  index + 1 < arguments.count else { return nil }
            let package = fileName(arguments[index + 1])
            // The installer's own package: its window shows the progress.
            guard package.lowercased() != installer.lowercased() else { return nil }
            return installing(package)
        default:
            guard name != installer.lowercased(), friendlyName(of: name) != nil else { return nil }
            return installing(process.name)
        }
    }

    /// "Installing MSXML 6 (MSXML6_X64.MSI)…", or with the file's name alone.
    static func installing(_ file: String) -> String {
        if let friendly = friendlyName(of: file) {
            return tr("Instalando \(friendly) (\(file))…", "Installing \(friendly) (\(file))…")
        }
        return tr("Instalando \(file)…", "Installing \(file)…")
    }

    /// Prerequisites that installers bring along, by their usual file names.
    static func friendlyName(of file: String) -> String? {
        let name = file.lowercased()
        let known: [(prefixes: [String], name: String)] = [
            (["netfx", "dotnetfx", "ndp", "dotnet"], ".NET Framework"),
            (["msxml"], "MSXML"),
            (["vcredist", "vc_redist"], "Visual C++"),
            (["dxsetup", "dxwebsetup", "directx"], "DirectX"),
            (["instmsi", "windowsinstaller", "instwi"], "Windows Installer"),
            (["sqlncli", "sqlexpr"], "SQL Server"),
        ]
        return known.first { $0.prefixes.contains { name.hasPrefix($0) } }?.name
    }

    /// "E:\LRNGESSL\MSXML6_X64.MSI" → "MSXML6_X64.MSI".
    static func fileName(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return trimmed.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? trimmed
    }
}
