# Vitral

**Windows programs on your Mac, with as few decisions as possible.**

[Leer en español](README.es.md)

> **Status: early development.** There is no app to install yet. Today the repository has
> `vitral analyze`, a command-line tool that inspects a Windows installer or an installed
> program without running it. Follow the [roadmap](#roadmap) to see what comes next.

## The idea

You drag a Windows installer (`.exe`, `.msi` or `.zip`) onto Vitral. You get back a Mac app with
its own icon that opens with a double click, looks sharp on a Retina display and is already set
up for that program.

- **It decides for you.** Vitral reads the installer before running anything: installer type,
  32 or 64 bits, the framework inside (Qt, Electron, .NET…), what it needs. Then it picks the
  settings that are known to work.
- **It checks its own work.** The first time the program opens, Vitral watches for a window,
  reads Wine's logs and the program's own logs, and fixes known problems by itself.
- **You can still change everything.** Advanced settings are one click away, with a
  **Reset to recommended** button.
- **Sharing is easy.** Export the app and send it; the other person imports it in Vitral, with no
  Terminal commands. Vitral checks Rosetta and macOS quarantine for them.

## How it compares

|                                         | Whisky / Rum | Sikarugir | CrossOver | **Vitral** |
|-----------------------------------------|--------------|-----------|-----------|------------|
| Any Windows program                     | ✓            | ✓         | ✓         | ✓          |
| Analyzes the installer and picks settings | –          | –         | partly    | ✓          |
| Detects and fixes problems on first run | –            | –         | –         | ✓          |
| One shareable Mac app per program       | –            | ✓ (Terminal needed to share) | – | ✓      |
| Free                                    | ✓            | ✓         | –         | ✓          |

## Try the analyzer

You need a Mac with Apple silicon, macOS 14 or later, and Xcode (or the Command Line Tools).

```sh
git clone https://github.com/noctavoxfilms/vitral.git
cd vitral
swift run vitral analyze "path/to/Setup.exe"          # an installer
swift run vitral analyze "path/to/My Program"         # the folder of an installed program
swift run vitral analyze --json "path/to/Setup.exe"   # machine-readable
swift run vitral icon "path/to/Program.exe" Program.icns
swift run vitral engines                             # Wine engines and Rosetta
swift run vitral engines install                     # download and verify the recommended engine
```

Examples:

```text
Setup.exe  (422 KB)
  Type:     Inno Setup installer 5.5.7
  File:     32-bit Windows, graphical
  Installs: My Program 28.0.0.0 · Example Ltd
  Needs:    Setup-1a.bin (1.36 GB)
            (they must stay in the same folder)

My Program  (folder · 1203 files · 1.67 GB)
  Program:     My Program.exe
               32-bit Windows, graphical · has an icon
  Product:     My Program 28.0.0 · Example Ltd
  Built with:  Qt 5.12.4 · Qt Quick (QML) · QtWebEngine browser (Chromium) · ANGLE (OpenGL ES → Direct3D)
  Needs:       Visual C++ 2015-2022 (32-bit) (ships vc_redist.x86.exe)
```

For installers it recognizes Inno Setup, NSIS, Windows Installer (`.msi`), WiX Burn,
InstallShield, 7-Zip self-extracting archives, ZIP files and plain programs, and tells 16-, 32-
and 64-bit apart. For an installed program it finds the file to open and detects Qt, Electron,
CEF, .NET, Java, Unity, Unreal, the Visual C++ runtime, the graphics interface (DirectX, OpenGL,
Vulkan) and anti-cheat systems. `vitral icon` turns the program's icon into a macOS icon with
every Retina size. The tool speaks English and Spanish (it follows your macOS language;
`VITRAL_LANG=en` forces English).

## Roadmap

| Phase | Goal |
|-------|------|
| **0. Foundations** *(now)* | Repository, CI, installer analyzer |
| **1. One command** | `vitral install Setup.exe` creates a sharp, portable Mac app with its icon, with no manual steps beyond the program's own installer. First target: a Qt 5 + QtWebEngine educational app that today needs a dozen manual fixes |
| **2. The app** | SwiftUI app: library, drag and drop, "Does it look right?", advanced settings |
| **3. Sharing** | Export and import, signed and notarized releases, updates |
| **4. More programs** | Compatibility list, community recipes |
| **5. After Rosetta** | Apple is phasing out general Rosetta support after macOS 27; Vitral is built so a Rosetta-free Wine engine can drop in |

## Principles

- **No telemetry.** Nothing leaves your Mac unless you send a report yourself.
- **Downloads only from official sources**, with pinned SHA-256 checksums.
- **Anti-cheat is detected and explained, never bypassed.**
- **Respect software licenses.** Share a program only with people covered by its license, or
  share just the recipe so they use their own installer.
- **Wine is not a sandbox.** Only install software you trust. Vitral will limit which folders
  a program can see.

## Requirements

Mac with Apple silicon (M1 or later, A18 Pro) and macOS 14 or later. Intel Macs are not
officially supported.

## Standing on the shoulders of

[Wine](https://www.winehq.org) · [Gcenx's macOS Wine builds](https://github.com/Gcenx/macOS_Wine_builds) ·
[Whisky](https://github.com/Whisky-App/Whisky) · [Rum](https://github.com/lunguini/rum) ·
[Obelisk](https://github.com/Zagrios/Obelisk) · [mapc-engine](https://github.com/abduzeedo/mapc-engine) ·
[Sikarugir](https://github.com/Sikarugir-App) · [DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) ·
[DXMT](https://github.com/3Shain/dxmt) · [MoltenVK](https://github.com/KhronosGroup/MoltenVK) ·
[Winetricks](https://github.com/Winetricks/winetricks) · [innoextract](https://constexpr.org/innoextract/).
See [NOTICE.md](NOTICE.md).

## License

Vitral is free software under the [GNU General Public License v3.0](LICENSE).

Windows is a trademark of Microsoft. Vitral is not affiliated with Microsoft, Apple, CodeWeavers
or the Wine project.

A [Noctavox Films](https://github.com/noctavoxfilms) project.
