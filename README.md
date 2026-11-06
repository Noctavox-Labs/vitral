# Vitral

**Windows programs on your Mac, with as few decisions as possible.**

[Leer en español](README.es.md)

> **Status: early development.** [**Download Vitral**](https://github.com/noctavox-labs/vitral/releases/latest)
> (a Mac with Apple silicon and macOS 14 or later; it installs Rosetta if your Mac lacks it).
> It is signed and notarized, and updates itself. Expect rough edges. The repository has `vitral`, a command-line tool that inspects Windows installers and turns
> programs into Mac apps, and the first version of the app: a setup assistant that checks your
> Mac and installs what is missing, a window where you drop an installer to install it, and
> your library of Windows apps. It installs, from their own installers, Qt, Electron, Delphi,
> MFC and .NET Framework programs, on Vitral's own Wine engine: see the
> [programs tested so far](#programs-tested). Follow the [roadmap](#roadmap) to see what comes next.

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
git clone https://github.com/noctavox-labs/vitral.git
cd vitral
swift run vitral analyze "path/to/Setup.exe"          # an installer
swift run vitral analyze "path/to/My Program"         # the folder of an installed program
swift run vitral analyze --json "path/to/Setup.exe"   # machine-readable
swift run vitral icon "path/to/Program.exe" Program.icns
swift run vitral engines                             # Wine engines and Rosetta
swift run vitral engines install                     # download and verify the recommended engine
swift build && .build/debug/vitral install "path/to/Setup.exe"   # install it as a Mac app
```

`vitral install` creates Windows (a Wine prefix) for the program, opens the installer so you
can follow its steps, finds the installed program, applies the settings its framework needs and
leaves `~/Applications/<Program>.app` with the program's icon. The app is small and signed on
your Mac; its Windows lives in `~/Library/Application Support/Vitral/Prefixes/`, because macOS
only opens apps whose signature covers everything inside them:

- **Qt 5:** sharp on Retina, Qt Quick without OpenGL, no stale single-instance lock.
- **Electron:** drawn inside the program (`--in-process-gpu`), so DXMT can show it; for
  electron-builder installers, Wine's stand-in PowerShell is turned off (it made the installer
  think the program was still open).
- **.NET Framework:** under Wine its installers end without installing anything. When an
  installer or a program needs it, Vitral installs Microsoft's .NET Framework 4.8 the way
  [winetricks](https://github.com/Winetricks/winetricks) does (about five minutes, downloaded
  from Microsoft with pinned checksums) and runs the installer again if it had stopped.

The installer's own shortcuts tell Vitral which programs it brought. When there are several (a
suite, or a program with its editor, like MetaTrader 5 and MetaEditor), Vitral makes the app for
the main one and offers the others; each one you pick becomes its own app, and they share files and settings.
Uninstalling one offers to remove the others too. From the Terminal:
`vitral programs <app>`, `vitral add <app> <program>` and `vitral uninstall --all <app>`.

If the installer opens the program when it finishes, Vitral closes that copy (it runs without
these settings) and goes on. Before finishing, Vitral compares the Windows functions the program
uses with the ones the engine has, and warns if something would stop it from opening. Each app
carries a small launcher that checks Rosetta and the engine, opens the program, tries again if it
crashes while starting, and keeps a log in `~/Library/Logs/Vitral/`. Programs that live in the menu bar, with no window (such
as Greenshot), count as open. `vitral install --arguments "/VERYSILENT"` passes options to the
installer, for unattended installations.

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

## Programs tested

Installed with Vitral from their official installers, on a MacBook Pro M1 Pro with macOS 27.
Games come later.

| Program | Built with | Result |
|---|---|---|
| Notepad++ 8.9 | Win32 | Works |
| HeidiSQL 12.22 | Delphi | Works |
| WinMerge 2.16 | MFC | Works (folder and file comparisons) |
| MetaTrader 5 | Win32 | Works, together with MetaEditor (from the same installer) |
| Greenshot 1.3 | .NET Framework 4 | Opens with Vitral's .NET Framework 4.8; lives in the menu bar |
| Winamp 5.9 | Win32 (skins) | Works |
| A 32-bit educational app | Qt 5 + QtWebEngine | Works with Vitral's Qt settings |
| An Electron 37 app | Electron | Works with `--in-process-gpu` and DXMT |
| vMix 29 | .NET Framework + Direct3D 11 | Installs with .NET Framework 4.8 and plays video; GT titles and some input controls do not draw yet, and it can freeze |
| Power BI Desktop | .NET Framework + WebView2 | With .NET Framework 4.8 it installs, but crashes on start inside its own code |
| Paint.NET 5.1 | .NET 9 + Direct2D | Does not open: Wine's Direct2D is incomplete. Paint.NET 5.2 should, with a newer engine |

## Build the app

You need Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). The Xcode project is generated from `project.yml` and is not in the
repository.

```sh
xcodegen generate
xcodebuild -project Vitral.xcodeproj -scheme Vitral -configuration Debug \
  -derivedDataPath .build/xcode build
open .build/xcode/Build/Products/Debug/Vitral.app
```

`scripts/make-dmg.sh` builds the Release app and packs it in `.build/dmg/Vitral-<version>.dmg`,
ready to drag into Applications. It is signed ad hoc, so it opens on the Mac that built it.
`scripts/release.sh` builds the published version: signed with Developer ID, notarized by Apple,
and with the signed `appcast.xml` the updater reads from the latest release.

On macOS 26 and later the app uses Liquid Glass; on macOS 14 and 15 it uses translucent
materials. Copies built from source do not update themselves; published releases update inside
the app with [Sparkle](https://sparkle-project.org), checking the signature of each update.

To add or change texts in the app: build it, sync the catalog with
`xcrun xcstringstool sync App/Resources/Localizable.xcstrings --stringsdata $(find .build/xcode -name '*.stringsdata')`,
put the translation in `scripts/translations-en.json` and run `python3 scripts/apply-translations.py`.

## The Wine engine

Vitral runs Windows programs with its own build of **CrossOver's Wine**, from the source code
CodeWeavers publishes under the LGPL: today CrossOver 26.3.0 (Wine 11.0), for 32- and 64-bit
programs, with [DXMT](https://github.com/3Shain/dxmt) 0.80 (Direct3D 11 on Metal, MIT) inside.
The official Wine builds crash with 32-bit programs such as Qt 5 apps on macOS; CrossOver's
patches fix that, and CrossOver 26 has what Electron apps need.

- `scripts/build-engine.sh` builds it on a Mac with Apple silicon in a few minutes (Rosetta,
  plus `brew install mingw-w64 bison flex freetype gnutls sdl2`; no Intel Homebrew needed).
- The [Engine workflow](.github/workflows/engine.yml) builds it in GitHub Actions and leaves it
  in a draft release; once checked, it is published as `engine-cx<version>-<n>` in this
  repository's [releases](https://github.com/noctavox-labs/vitral/releases).
- Vitral downloads it the first time it is needed and checks it against the SHA-256 pinned in
  `Sources/VitralKit/Engines/WineEngine.swift`. Inside, `share/licenses/` lists each source.
## Roadmap

| Phase | Goal |
|-------|------|
| **0. Foundations** *(done)* | Repository, CI, installer and program analyzer, Wine engine download |
| **1. One command** *(now)* | `vitral install Setup.exe` creates a sharp, portable Mac app with its icon, with no manual steps beyond the program's own installer. Reached for its first targets: a 32-bit Qt 5 + QtWebEngine educational app that needed a dozen manual fixes, and an Electron 37 app, on Vitral's own engine. Next: more test Macs and programs |
| **2. The app** *(started)* | SwiftUI app with Liquid Glass: setup assistant (Rosetta, engine), drag and drop, library, "Does it look right?", advanced settings |
| **3. Sharing** *(started)* | Signed and notarized releases and automatic updates inside the app (done); export and import |
| **4. More programs** *(started)* | [Compatibility list](#programs-tested), .NET Framework, installers with several programs; next: community recipes |
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

[Wine](https://www.winehq.org) · [CrossOver's source code](https://www.codeweavers.com/crossover/source) · [Gcenx's macOS Wine builds](https://github.com/Gcenx/macOS_Wine_builds) ·
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

A [Noctavox Labs](https://github.com/noctavox-labs) project.
