# Notices / Avisos

Vitral is licensed under the GNU General Public License v3.0 (see `LICENSE`).

Vitral es software libre bajo la GPL-3.0 (ver `LICENSE`).

## Code from other projects / Código de otros proyectos

None yet. When code is adapted from another project, it is listed here with its license, and the
file keeps the original copyright notice.

Todavía ninguno. Cuando se adapte código de otro proyecto, se anota aquí con su licencia y el
archivo conserva el aviso de copyright original.

Compatible sources we expect to draw from / Fuentes compatibles previstas:

| Project | License |
|---------|---------|
| [Whisky](https://github.com/Whisky-App/Whisky) | GPL-3.0 |
| [Rum](https://github.com/lunguini/rum) | GPL-3.0 |
| [Obelisk](https://github.com/Zagrios/Obelisk) | GPL-3.0 |
| [mapc-engine](https://github.com/abduzeedo/mapc-engine) | Apache-2.0 (compatible with GPL-3.0) |

## Components Vitral downloads or bundles / Componentes que Vitral descarga o incluye

Vitral downloads these when they are needed, from their official release pages, and checks each
file against a SHA-256 pinned in the code (`Sources/VitralKit/Engines/WineEngine.swift`). Each keeps
its own license, and redistributed copies ship with it.

Vitral los descarga cuando hacen falta, desde sus páginas oficiales de versiones, y comprueba cada
archivo contra un SHA-256 fijado en el código. Cada uno conserva su licencia, y las copias que se
redistribuyan la incluyen.

**In use / En uso:**

| Component | License | Source |
|-----------|---------|--------|
| Wine from CrossOver 24.0.7, built by the Sikarugir project ([`WS12WineCX24.0.7_7`](https://github.com/Sikarugir-App/Engines/releases/tag/v1.0)) | LGPL-2.1-or-later (Wine) | [CodeWeavers: crossover-sources-24.0.7](https://media.codeweavers.com/pub/crossover/source/crossover-sources-24.0.7.tar.gz) |
| macOS libraries from Gcenx's official Wine build ([`wine-stable-11.0_1`](https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.0_1)): FreeType, GnuTLS and its dependencies, MoltenVK, SDL2, libinotify, gettext | Each project's own (FreeType License or GPL-2.0, LGPL, Apache-2.0, zlib, MIT) | [Gcenx/macOS_Wine_builds](https://github.com/Gcenx/macOS_Wine_builds) |

Why CrossOver's Wine: the official builds crash with 32-bit programs such as Qt 5 apps on macOS,
and CrossOver's patches fix that. Vitral only downloads the Sikarugir build; it does not copy any
of Sikarugir's code. A Vitral-built engine from CodeWeavers' sources will replace it.

Por qué el Wine de CrossOver: las versiones oficiales se caen con programas de 32 bits como las
apps en Qt 5, y los parches de CrossOver lo resuelven. Vitral solo descarga la compilación de
Sikarugir; no copia código de Sikarugir. La reemplazará un motor compilado por Vitral desde el
código de CodeWeavers.

**Bundled in the app / Incluido en la app:**

| Component | License | Source |
|-----------|---------|--------|
| Sparkle 2.10.1 (automatic updates / actualizaciones automáticas) | MIT, plus the notices in its `LICENSE` file | [sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle) |

**Planned / Previstos:**

| Component | License | Source |
|-----------|---------|--------|
| DXVK-macOS | Zlib | [Gcenx/DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) |
| DXMT | to be confirmed before redistribution | [3Shain/dxmt](https://github.com/3Shain/dxmt) |
| MoltenVK | Apache-2.0 | [KhronosGroup/MoltenVK](https://github.com/KhronosGroup/MoltenVK) |
| Winetricks | LGPL-2.1-or-later | [Winetricks/winetricks](https://github.com/Winetricks/winetricks) |
| innoextract | zlib-style, to be confirmed | [constexpr.org/innoextract](https://constexpr.org/innoextract/) |

Apple's D3DMetal (Game Porting Toolkit) is never redistributed.

D3DMetal de Apple (Game Porting Toolkit) nunca se redistribuye.

## Inspiration only / Solo inspiración

The portable app-wrapper idea comes from [Sikarugir](https://github.com/Sikarugir-App) (formerly
Wineskin). Its Creator, Template and Engines repositories have no license, so **no code from them
is used** (the Engines repository only hosts the Wine build listed above, which Vitral downloads).

La idea del envoltorio portable viene de Sikarugir (antes Wineskin). Sus repositorios Creator,
Template y Engines no tienen licencia, así que **no se usa código de ellos** (de Engines solo se
descarga la compilación de Wine de arriba).
