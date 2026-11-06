import Foundation
import Testing
@testable import VitralKit

private func process(_ pid: pid_t, _ arguments: String...) -> InstallerActivity.Process {
    InstallerActivity.Process(pid: pid, name: InstallerActivity.fileName(arguments[0]), arguments: arguments)
}

/// What Encarta 2009's disc ran while it installed (seen with ps on 2026-11-06).
@Test func encartaPrerequisites() {
    let setup = process(10, #"E:\SETUP.EXE"#)
    let helper = process(11, #"E:\SETUPREQ.EXE"#)
    #expect(InstallerActivity.describe([setup, helper], installer: "SETUP.EXE") == nil)

    let msxml = process(12, #"C:\windows\system32\msiexec.exe"#, "/i", #"E:\LRNGESSL\MSXML6_X64.MSI"#, "/qn")
    #expect(InstallerActivity.describe([setup, helper, msxml], installer: "SETUP.EXE")
        == tr("Instalando MSXML (MSXML6_X64.MSI)…", "Installing MSXML (MSXML6_X64.MSI)…"))

    let dotNet = process(13, #"E:\LRNGESSL\NETFX64.EXE"#, "/q")
    #expect(InstallerActivity.describe([setup, dotNet], installer: "SETUP.EXE")
        == tr("Instalando .NET Framework (NETFX64.EXE)…", "Installing .NET Framework (NETFX64.EXE)…"))

    // The newest step wins: .NET compiles its libraries while its installer is still open.
    let ngen = process(14, #"C:\windows\Microsoft.NET\Framework\v2.0.50727\ngen.exe"#, "install",
                       "System.Windows.Forms,", "Version=2.0.0.0,", "Culture=neutral", "/queue:1")
    #expect(InstallerActivity.describe([setup, dotNet, ngen], installer: "SETUP.EXE")
        == tr("Preparando .NET Framework: System.Windows.Forms…", "Preparing .NET Framework: System.Windows.Forms…"))
}

@Test func theInstallersOwnPackageSaysNothing() {
    // Its own window shows its progress.
    let own = process(20, #"C:\windows\system32\msiexec.exe"#, "/i", #"Z:\Users\x\Downloads\Programa.msi"#)
    #expect(InstallerActivity.describe([own], installer: "programa.msi") == nil)
    let other = process(21, #"C:\windows\system32\msiexec.exe"#, "/I", #""C:\temp\extra.msi""#)
    #expect(InstallerActivity.describe([own, other], installer: "programa.msi")
        == tr("Instalando extra.msi…", "Installing extra.msi…"))
    // msiexec running as a service, with no package.
    #expect(InstallerActivity.describe([process(22, #"C:\windows\system32\msiexec.exe"#, "/V")], installer: "x.exe") == nil)
}

@Test func knownPrerequisitesByName() {
    #expect(InstallerActivity.friendlyName(of: "vcredist_x86.exe") == "Visual C++")
    #expect(InstallerActivity.friendlyName(of: "VC_redist.x64.exe") == "Visual C++")
    #expect(InstallerActivity.friendlyName(of: "DXSETUP.exe") == "DirectX")
    #expect(InstallerActivity.friendlyName(of: "dotNetFx40_Full_x86_x64.exe") == ".NET Framework")
    #expect(InstallerActivity.friendlyName(of: "Leeme.exe") == nil)
    // A program that is not a known prerequisite is not a step to show.
    #expect(InstallerActivity.describe([process(30, #"C:\Program Files\App\app.exe"#)], installer: "setup.exe") == nil)
    #expect(InstallerActivity.describe([process(31, #"C:\temp\vcredist_x86.exe"#, "/q")], installer: "setup.exe")
        == tr("Instalando Visual C++ (vcredist_x86.exe)…", "Installing Visual C++ (vcredist_x86.exe)…"))
}

@Test func environmentAfterTheArguments() {
    // Seen with svchost.exe: argc counts one string of the environment.
    #expect(WineProcesses.windowsArguments([#"C:\windows\system32\svchost.exe"#, "-k", "LocalService", "TMPDIR=/var/folders/x/T/"])
        == [#"C:\windows\system32\svchost.exe"#, "-k", "LocalService"])
    #expect(WineProcesses.windowsArguments(["ngen.exe", "install", "System.Xml,", "Version=2.0.0.0,"])
        == ["ngen.exe", "install", "System.Xml,", "Version=2.0.0.0,"])
}
