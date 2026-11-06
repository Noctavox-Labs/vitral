# Vitral

**Windows programs on your Mac, with as few decisions as possible.**

[Leer en español](README.es.md)

> **Status: early development.** [**Download Vitral**](https://github.com/noctavox-labs/vitral/releases/latest)
> (a Mac with Apple silicon and macOS 14 or later; it installs Rosetta if your Mac lacks it).
> It is signed and notarized, and keeps itself up to date even if you only open your programs. Expect rough edges. The repository has `vitral`, a command-line tool that inspects Windows installers and turns
> programs into Mac apps, and the first version of the app: a setup assistant that checks your
> Mac and installs what is missing, a window where you drop an installer to install it, and
> your library of Windows apps. It installs, from their own installers or CD and DVD images, Qt,
> Electron, Delphi, MFC and .NET Framework programs, and programs that show pages with Internet
> Explorer's control, like Microsoft Encarta, on Vitral's own Wine engine: see the
> [programs tested so far](#programs-tested). Follow the [roadmap](#roadmap) to see what comes next.

## The idea

You drag a Windows installer (`.exe`, `.msi` or `.zip`, or the `.iso` image of a CD or DVD) onto
Vitral. You get back a Mac app with the program's own icon, in full color, that opens with a
double click, looks sharp on a Retina display and is already set up for that program.

- **It decides for you.** Vitral reads the installer before running anything: installer type,
  32 or 64 bits, the framework inside (Qt, Electron, .NET…), what it needs. Then it picks the
  settings that are known to work.
- **It checks its own work.** When a program closes instead of opening, or shows an error box
  and closes, Vitral reads Wine's logs, the program's own and what the box said, recognizes known failures and tries their fixes by itself, undoing
  any that does not help. If it cannot fix it (some need a newer engine), it says why and helps
  you report it on GitHub with a report you read before sending. New failures and fixes arrive
  in a signed catalog, without waiting for a new Vitral.
- **It keeps itself up to date.** Vitral updates itself, and your apps get the new engine and
  fixes when you open them, even if you never open Vitral (see [Updates](#updates)).
- **You can still change everything** *(coming)*. Advanced settings one click away, with a
  **Reset to recommended** button.
- **Sharing is easy** *(coming)*. Export the app and send it; the other person imports it in
  Vitral, with no Terminal commands. Vitral checks Rosetta and macOS quarantine for them.

## How it compares

|                                         | Whisky / Rum | Sikarugir | CrossOver | **Vitral** |
|-----------------------------------------|--------------|-----------|-----------|------------|
| Any Windows program                     | ✓            | ✓         | ✓         | ✓          |
| Analyzes the installer and picks settings | –          | –         | partly    | ✓          |
| Recognizes and fixes known problems when a program does not open | – | – | – | ✓          |
| One shareable Mac app per program       | –            | ✓ (Terminal needed to share) | – | ✓      |
| Free                                    | ✓            | ✓         | –         | ✓          |

## Try the analyzer

You need a Mac with Apple silicon, macOS 14 or later, and Xcode (or the Command Line Tools).

```sh
git clone https://github.com/noctavox-labs/vitral.git
cd vitral
swift run vitral analyze "path/to/Setup.exe"          # an installer
swift run vitral analyze "path/to/My Program"         # the folder of an installed program
swift run vitral analyze "path/to/Disc.iso"           # a CD or DVD image
swift run vitral analyze --json "path/to/Setup.exe"   # machine-readable
swift run vitral icon "path/to/Program.exe" Program.icns
swift run vitral engines                             # Wine engines and Rosetta
swift run vitral engines install                     # download and verify the recommended engine
swift build && .build/debug/vitral install "path/to/Setup.exe"   # install it as a Mac app
```

`vitral install` creates a space of its own for the program (a Wine prefix), opens the installer
so you can follow its steps, finds the installed program, applies the settings its framework
needs and leaves `~/Applications/<Program>.app` with the icon its Windows shortcut shows, at the
best resolution and color depth the program has. The app is small and signed on your Mac; the
program's files and settings live in `~/Library/Application Support/Vitral/Prefixes/`, because
macOS only opens apps whose signature covers everything inside them:

- **Qt 5:** sharp on Retina, Qt Quick without OpenGL, no stale single-instance lock.
- **Electron:** drawn inside the program (`--in-process-gpu`), so DXMT can show it; for
  electron-builder installers, Wine's stand-in PowerShell is turned off (it made the installer
  think the program was still open).
- **.NET Framework:** under Wine its installers end without installing anything. When an
  installer or a program needs it, Vitral installs Microsoft's .NET Framework 4.8 the way
  [winetricks](https://github.com/Winetricks/winetricks) does (about five minutes, downloaded
  from Microsoft with pinned checksums) and runs the installer again if it had stopped.
- **Pages with Internet Explorer's control** (MFC programs like Encarta): Vitral adds
  [Wine Gecko](https://gitlab.winehq.org/wine/wine/-/wikis/Gecko), the engine those pages need,
  downloaded once from WineHQ with pinned checksums.
- **CD and DVD images (`.iso`):** Vitral opens the image, finds its installer and shows the image
  to the installer as a disc drive. While it installs, it says what the installer is doing.

The installer's own shortcuts tell Vitral which programs it brought. When there are several (a
suite, or a program with its editor, like MetaTrader 5 and MetaEditor), Vitral makes the app for
the main one and offers the others; each one you pick becomes its own app, and they share files and settings.
In the library they share one card, like a folder on iPhone: click an app's small icon to open
it, or the card to see them all. Uninstalling one offers to remove the others too. From the Terminal:
`vitral programs <app>`, `vitral add <app> <program>` and `vitral uninstall --all <app>`.

If the installer opens the program when it finishes, Vitral closes that copy (it runs without
these settings) and goes on. Before finishing, Vitral compares the Windows functions the program
uses with the ones the engine has, and warns if something would stop it from opening. Each app
carries a small launcher that checks Rosetta and the engine, opens the program, tries again if it
crashes while starting, and keeps a log in `~/Library/Logs/Vitral/`. When Vitral brings a newer
build of the app's engine, the launcher moves the app to it the next time it opens, and puts
everything back as it was if the program does not open with it. Programs that live in the menu
bar, with no window (such as Greenshot), count as open. A program that freezes closes with
**Force Quit…** (right-click its app in the library), along with everything it left running. `vitral install --arguments "/VERYSILENT"` passes options to the
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

## Updates

Published copies of Vitral update themselves with [Sparkle](https://sparkle-project.org), which
checks the signature of each update. Many people only open their programs and never Vitral, so
the apps help:

- Once a day, opening an app checks Vitral's feed on GitHub. If there is a newer Vitral, the app
  opens it without a window or Dock icon; Vitral updates itself and quits, without opening
  again. Your program is not interrupted.
- The next time you open the app, before the program shows, it takes the new Vitral's launcher,
  and with it the new engine and fixes.

All of this happens only with "Check for updates automatically" on (Vitral's settings). Apps
made with Vitral 0.1.6 or earlier learn it the first time Vitral 0.1.7 or later opens.

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
| Microsoft Encarta 2009 (Premium DVD, from its `.iso`) | MFC + Internet Explorer pages (XSLT) | Works: search, articles, pictures and media player, with Vitral's fixes to Wine and Wine Gecko. Encarta Kids, from the same disc, too |
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
patches fix that, and CrossOver 26 has what Electron apps need. On top, Vitral applies its own
fixes to Wine, in [`engine-patches/`](engine-patches): today seven that Microsoft Encarta needed
(resources, XSLT, Internet Explorer's control) and one that lets Vitral read the error boxes a
program shows. Vitral offers them to the Wine project.

- `scripts/build-engine.sh` builds it on a Mac with Apple silicon in a few minutes (Rosetta,
  plus `brew install mingw-w64 bison flex freetype gnutls sdl2`; no Intel Homebrew needed).
- The [Engine workflow](.github/workflows/engine.yml) builds it in GitHub Actions and leaves it
  in a draft release; once checked, it is published as `engine-cx<version>-<n>` in this
  repository's [releases](https://github.com/noctavox-labs/vitral/releases).
- Vitral downloads it the first time it is needed and checks it against the SHA-256 pinned in
  `Sources/VitralKit/Engines/WineEngine.swift`. Inside, `share/licenses/` lists each source.
- A new build of the same engine (today `engine-cx26.3.0-2`) replaces the one before it: each
  app moves to it the next time it opens, and stays on the old one if the program does not open
  with the new one.

## Roadmap

| Phase | Goal |
|-------|------|
| **0. Foundations** *(done)* | Repository, CI, installer and program analyzer, Wine engine download |
| **1. One command** *(now)* | `vitral install Setup.exe` creates a sharp, portable Mac app with its icon, with no manual steps beyond the program's own installer. Reached for its first targets: a 32-bit Qt 5 + QtWebEngine educational app that needed a dozen manual fixes, and an Electron 37 app, on Vitral's own engine. Next: more test Macs and programs |
| **2. The app** *(started)* | SwiftUI app with Liquid Glass: setup assistant (Rosetta, engine), drag and drop, library, "Does it look right?", advanced settings |
| **3. Sharing** *(started)* | Signed and notarized releases and automatic updates, also for people who only open their programs (done); export and import |
| **4. More programs** *(started)* | [Compatibility list](#programs-tested), .NET Framework, installers with several programs, CD and DVD images, Internet Explorer pages (Wine Gecko), programs that show an error box and close, a catalog of known failures with fixes Vitral tries by itself (downloaded and signed); next: blank windows and programs that hang, retrying installations, community recipes |
| **5. After Rosetta** | Apple is phasing out general Rosetta support after macOS 27; Vitral is built so a Rosetta-free Wine engine can drop in |

## Principles

- **No telemetry.** Nothing leaves your Mac unless you send a report yourself. Update checks (by
  Vitral, and once a day by your apps when you open them) only read Vitral's feed on GitHub, and
  only while automatic checks are on.
- **Downloads only from official sources**, with pinned SHA-256 checksums.
- **Known failures arrive signed.** The catalog of failures and fixes comes from this repository
  (`catalog/`), only while automatic update checks are on, and Vitral uses it only if it is
  signed with the same key as its updates. A fix is a setting or an official component, never
  code.
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
[Wine Gecko](https://gitlab.winehq.org/wine/wine/-/wikis/Gecko) ·
[Winetricks](https://github.com/Winetricks/winetricks) · [innoextract](https://constexpr.org/innoextract/).
See [NOTICE.md](NOTICE.md).

## License

Vitral is free software under the [GNU General Public License v3.0](LICENSE).

Windows is a trademark of Microsoft. Vitral is not affiliated with Microsoft, Apple, CodeWeavers
or the Wine project.

A [Noctavox Labs](https://github.com/noctavox-labs) project.
