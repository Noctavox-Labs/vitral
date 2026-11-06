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
| **Vitral's engine** ([`engine-cx26.3.0-2`](https://github.com/noctavox-labs/vitral/releases/tag/engine-cx26.3.0-2)): Wine from CrossOver 26.3.0, built by `scripts/build-engine.sh` with Vitral's fixes to Wine (`engine-patches/`, under Wine's license). The first build, [`engine-cx26.3.0-1`](https://github.com/noctavox-labs/vitral/releases/tag/engine-cx26.3.0-1), without fixes, stays for apps that have not moved to the new one | LGPL-2.1-or-later (Wine) | [CodeWeavers: crossover-sources-26.3.0](https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz) |
| DXMT 0.80, official build, inside Vitral's engine (license in its `share/licenses/`) | MIT | [3Shain/dxmt v0.80](https://github.com/3Shain/dxmt/releases/tag/v0.80) |
| Wine from CrossOver 24.0.7, built by the Sikarugir project ([`WS12WineCX24.0.7_7`](https://github.com/Sikarugir-App/Engines/releases/tag/v1.0)), only for apps installed with it before | LGPL-2.1-or-later (Wine) | [CodeWeavers: crossover-sources-24.0.7](https://media.codeweavers.com/pub/crossover/source/crossover-sources-24.0.7.tar.gz) |
| macOS libraries from Gcenx's official Wine build ([`wine-stable-11.0_1`](https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.0_1)): FreeType, GnuTLS and its dependencies, MoltenVK, SDL2, libinotify, gettext | Each project's own (FreeType License or GPL-2.0, LGPL, Apache-2.0, zlib, MIT) | [Gcenx/macOS_Wine_builds](https://github.com/Gcenx/macOS_Wine_builds) |
| Wine Gecko 2.47.4 (32 and 64-bit), WineHQ's official build, only for programs that show pages with Internet Explorer's control (checksums in `Sources/VitralKit/Install/WineGecko.swift`) | MPL-2.0 | [WineHQ: wine-gecko 2.47.4](https://dl.winehq.org/wine/wine-gecko/2.47.4/) |

Why CrossOver's Wine: the official builds crash with 32-bit programs such as Qt 5 apps on macOS,
and CrossOver's patches fix that. Vitral builds its own engine from CodeWeavers' sources; the
older Sikarugir build is only downloaded for apps that were installed with it, and none of
Sikarugir's code is copied. The way to build CrossOver's Wine on Apple silicon was learned from
[calimocho](https://github.com/dragoshont/calimocho) (LGPL-2.1-or-later); no code from it is
used, and Vitral does not ship Apple's D3DMetal as it does.

Por qué el Wine de CrossOver: las versiones oficiales se caen con programas de 32 bits como las
apps en Qt 5, y los parches de CrossOver lo resuelven. Vitral compila su propio motor desde el
código de CodeWeavers; la compilación de Sikarugir solo se baja para las apps que se instalaron
con ella, y no se copia código de Sikarugir. La forma de compilar el Wine de CrossOver en chip
Apple se aprendió de calimocho (LGPL-2.1 o posterior); no se usa código suyo, y Vitral no incluye
el D3DMetal de Apple como hace ese proyecto.

**Bundled in the app / Incluido en la app:**

| Component | License | Source |
|-----------|---------|--------|
| Sparkle 2.10.1 (automatic updates / actualizaciones automáticas) | MIT, plus the notices in its `LICENSE` file | [sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle) |

**Planned / Previstos:**

| Component | License | Source |
|-----------|---------|--------|
| DXVK-macOS | Zlib | [Gcenx/DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) |
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
