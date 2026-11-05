# Vitral

**Programas de Windows en tu Mac, con la menor cantidad de decisiones posible.**

[Read in English](README.md)

> **Estado: en desarrollo temprano.** [**Descarga Vitral**](https://github.com/noctavox-labs/vitral/releases/latest)
> (Mac con chip de Apple y macOS 14 o más nuevo; instala Rosetta si tu Mac no la tiene). Va
> firmada y notarizada, y se actualiza sola. Puede tener detalles por pulir. El repositorio tiene `vitral`, una herramienta de línea de comandos que
> revisa instaladores de Windows y convierte programas en apps de Mac, y la primera versión de
> la app: un asistente que revisa tu Mac e instala lo que falta, una ventana donde sueltas un
> instalador para instalarlo, y tu biblioteca de apps de Windows. Ya instala y abre, desde sus
> propios instaladores, una app educativa en Qt 5 + QtWebEngine de 32 bits y una app en
> Electron 37, con el motor de Wine propio de Vitral. En la [hoja de ruta](#hoja-de-ruta) está
> lo que viene.

## La idea

Arrastras un instalador de Windows (`.exe`, `.msi` o `.zip`) a Vitral. Obtienes una app de Mac
con su propio ícono, que abre con doble clic, se ve nítida en una pantalla Retina y ya viene
configurada para ese programa.

- **Decide por ti.** Vitral lee el instalador antes de ejecutar nada: tipo de instalador, 32 o 64
  bits, la tecnología que usa (Qt, Electron, .NET…) y lo que necesita. Con eso elige la
  configuración que se sabe que funciona.
- **Revisa su propio trabajo.** La primera vez que se abre el programa, Vitral espera a que
  aparezca la ventana, lee los registros de Wine y los del propio programa, y corrige solo los
  problemas conocidos.
- **Puedes cambiarlo todo.** Los ajustes avanzados están a un clic, con un botón
  **Volver a lo recomendado**.
- **Compartir es fácil.** Exportas la app y la mandas; la otra persona la importa en Vitral, sin
  comandos de Terminal. Vitral se encarga de Rosetta y de la cuarentena de macOS.

## En qué se diferencia

|                                              | Whisky / Rum | Sikarugir | CrossOver | **Vitral** |
|----------------------------------------------|--------------|-----------|-----------|------------|
| Cualquier programa de Windows                | ✓            | ✓         | ✓         | ✓          |
| Analiza el instalador y elige la configuración | –          | –         | en parte  | ✓          |
| Detecta y corrige fallas al primer arranque  | –            | –         | –         | ✓          |
| Una app de Mac por programa, para compartir  | –            | ✓ (hay que usar la Terminal) | – | ✓     |
| Gratis                                       | ✓            | ✓         | –         | ✓          |

## Probar el analizador

Necesitas una Mac con chip Apple, macOS 14 o más nuevo, y Xcode (o sus herramientas de línea de
comandos).

```sh
git clone https://github.com/noctavox-labs/vitral.git
cd vitral
swift run vitral analizar "ruta/al/Setup.exe"          # un instalador
swift run vitral analizar "ruta/a/Mi Programa"         # la carpeta de un programa instalado
swift run vitral analizar --json "ruta/al/Setup.exe"   # para otros programas
swift run vitral icono "ruta/al/Programa.exe" Programa.icns
swift run vitral motores                               # motores de Wine y Rosetta
swift run vitral motores instalar                      # baja y verifica el motor recomendado
swift build && .build/debug/vitral instalar "ruta/a/Setup.exe"   # instalarlo como app de Mac
```

`vitral instalar` crea un Windows (un prefijo de Wine) para el programa, abre el instalador
para que sigas sus pasos, encuentra el programa instalado, aplica los ajustes que necesita su
tecnología y deja `~/Applications/<Programa>.app` con el ícono del programa. La app es pequeña
y se firma en tu Mac; su Windows vive en `~/Library/Application Support/Vitral/Prefixes/`,
porque macOS solo abre apps cuya firma cubre todo lo que llevan dentro:

- **Qt 5:** nítido en Retina, Qt Quick sin OpenGL y sin el candado de instancia única trabado.
- **Electron:** dibuja dentro del programa (`--in-process-gpu`) para que DXMT lo muestre; en los
  instaladores de electron-builder se desactiva el PowerShell sustituto de Wine (le hacía creer
  al instalador que el programa seguía abierto).

Los accesos directos del propio instalador le dicen a Vitral qué programas trae. Si son varios
(una suite, o un programa con su editor, como MetaTrader 5 y MetaEditor), Vitral crea la app del
principal y ofrece los demás; cada uno que elijas queda como su propia app, sobre el mismo
Windows. Al desinstalar una, Vitral ofrece quitar también las demás y su Windows. Desde la Terminal:
`vitral programas <app>`, `vitral agregar <app> <programa>` y `vitral desinstalar --todas <app>`.

Si el instalador abre el programa al terminar, Vitral cierra esa copia (corre sin estos ajustes)
y sigue. Antes de terminar compara las funciones de Windows que usa el programa con las que tiene
el motor, y avisa si falta algo que le impediría abrir. Cada app lleva un lanzador pequeño que
revisa Rosetta y el motor, abre el programa, vuelve a intentar si se cae al arrancar y guarda un
registro en `~/Library/Logs/Vitral/`.

Ejemplos:

```text
Setup.exe  (422 KB)
  Tipo:     Instalador Inno Setup 5.5.7
  Archivo:  Windows de 32 bits, con interfaz gráfica
  Instala:  Mi Programa 28.0.0.0 · Ejemplo S.A.
  Necesita: Setup-1a.bin (1,36 GB)
            (tienen que estar en la misma carpeta)

Mi Programa  (carpeta · 1203 archivos · 1,67 GB)
  Programa:    Mi Programa.exe
               Windows de 32 bits, con interfaz gráfica · con ícono
  Producto:    Mi Programa 28.0.0 · Ejemplo S.A.
  Hecho con:   Qt 5.12.4 · Qt Quick (QML) · navegador QtWebEngine (Chromium) · ANGLE (OpenGL ES → Direct3D)
  Necesita:    Visual C++ 2015-2022 de 32 bits (trae vc_redist.x86.exe)
```

En los instaladores reconoce Inno Setup, NSIS, Windows Installer (`.msi`), WiX Burn,
InstallShield, archivos 7-Zip autoextraíbles, ZIP y programas sueltos, y distingue 16, 32 y 64
bits. En un programa instalado encuentra el archivo que hay que abrir y detecta Qt, Electron,
CEF, .NET, Java, Unity, Unreal, el runtime de Visual C++, la interfaz gráfica (DirectX, OpenGL,
Vulkan) y los antitrampas. `vitral icono` convierte el ícono del programa en uno de Mac, con
todos los tamaños Retina. Habla español e inglés (sigue el idioma de macOS; `VITRAL_LANG=es`
fuerza español).

## Compilar la app

Necesitas Xcode 26 o más nuevo y [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). El proyecto de Xcode se genera desde `project.yml` y no está en el
repositorio.

```sh
xcodegen generate
xcodebuild -project Vitral.xcodeproj -scheme Vitral -configuration Debug \
  -derivedDataPath .build/xcode build
open .build/xcode/Build/Products/Debug/Vitral.app
```

`scripts/make-dmg.sh` compila la versión Release y la empaqueta en
`.build/dmg/Vitral-<versión>.dmg`, lista para arrastrar a Aplicaciones. Va firmada ad hoc, así
que abre en la Mac que la compiló. `scripts/release.sh` arma la versión publicada: firmada con
Developer ID, notarizada por Apple y con el `appcast.xml` firmado que el actualizador lee de la
última versión.

En macOS 26 o más nuevo la app usa Liquid Glass; en macOS 14 y 15, materiales translúcidos. Las
copias compiladas desde el código no se actualizan solas; las versiones publicadas se actualizan
dentro de la app con [Sparkle](https://sparkle-project.org), que comprueba la firma de cada
actualización.

Para agregar o cambiar textos de la app: compilar, sincronizar el catálogo con
`xcrun xcstringstool sync App/Resources/Localizable.xcstrings --stringsdata $(find .build/xcode -name '*.stringsdata')`,
poner la traducción en `scripts/translations-en.json` y correr `python3 scripts/apply-translations.py`.

## El motor de Wine

Vitral abre los programas de Windows con su propia compilación del **Wine de CrossOver**, desde
el código que CodeWeavers publica bajo la LGPL: hoy CrossOver 26.3.0 (Wine 11.0), para
programas de 32 y 64 bits, con [DXMT](https://github.com/3Shain/dxmt) 0.80 (Direct3D 11 sobre
Metal, MIT) adentro. Las versiones oficiales de Wine se caen con programas de 32 bits como las
apps en Qt 5 en macOS; los parches de CrossOver lo resuelven, y CrossOver 26 tiene lo que
necesitan las apps de Electron.

- `scripts/build-engine.sh` lo compila en una Mac con chip Apple en pocos minutos (Rosetta, más
  `brew install mingw-w64 bison flex freetype gnutls sdl2`; no hace falta un Homebrew de Intel).
- El [flujo Engine](.github/workflows/engine.yml) lo compila en GitHub Actions y lo deja en una
  versión borrador; una vez revisado, se publica como `engine-cx<versión>-<n>` en las
  [versiones](https://github.com/noctavox-labs/vitral/releases) de este repositorio.
- Vitral lo baja la primera vez que hace falta y lo comprueba contra el SHA-256 fijado en
  `Sources/VitralKit/Engines/WineEngine.swift`. Adentro, `share/licenses/` dice de dónde sale
  cada parte.
## Hoja de ruta

| Fase | Meta |
|------|------|
| **0. Cimientos** *(hecho)* | Repositorio, pruebas automáticas, analizador de instaladores y programas, descarga del motor de Wine |
| **1. Un comando** *(ahora)* | `vitral instalar Setup.exe` crea una app de Mac nítida, portable y con ícono, sin pasos a mano aparte del instalador del programa. Logrado con sus primeros objetivos: una app educativa en Qt 5 + QtWebEngine de 32 bits que necesitaba una docena de arreglos manuales, y una app en Electron 37, con el motor propio. Sigue: más Macs y programas de prueba |
| **2. La app** *(empezada)* | App en SwiftUI con Liquid Glass: asistente de preparación (Rosetta, motor), arrastrar y soltar, biblioteca, «¿Se ve bien?», ajustes avanzados |
| **3. Compartir** *(empezada)* | Versiones firmadas y notarizadas y actualizaciones automáticas dentro de la app (hecho); exportar e importar |
| **4. Más programas** | Lista de compatibilidad, recetas de la comunidad |
| **5. Después de Rosetta** | Apple deja Rosetta para uso general después de macOS 27; Vitral está hecho para cambiar a un motor de Wine que no lo necesite |

## Principios

- **Sin telemetría.** Nada sale de tu Mac, salvo un informe que tú decidas enviar.
- **Descargas solo de fuentes oficiales**, con sumas SHA-256 fijadas.
- **Los antitrampas se detectan y se explican, nunca se eluden.**
- **Respeto a las licencias.** Comparte un programa solo con personas cubiertas por su licencia,
  o comparte solo la receta para que cada quien use su propio instalador.
- **Wine no es una caja aislada.** Instala solo programas de confianza. Vitral va a limitar
  qué carpetas puede ver cada programa.

## Requisitos

Mac con chip Apple (M1 o posterior, A18 Pro) y macOS 14 o más nuevo. Las Mac con Intel no tienen
soporte oficial.

## Sobre hombros de gigantes

[Wine](https://www.winehq.org) · [código de CrossOver](https://www.codeweavers.com/crossover/source) · [Wine para macOS de Gcenx](https://github.com/Gcenx/macOS_Wine_builds) ·
[Whisky](https://github.com/Whisky-App/Whisky) · [Rum](https://github.com/lunguini/rum) ·
[Obelisk](https://github.com/Zagrios/Obelisk) · [mapc-engine](https://github.com/abduzeedo/mapc-engine) ·
[Sikarugir](https://github.com/Sikarugir-App) · [DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) ·
[DXMT](https://github.com/3Shain/dxmt) · [MoltenVK](https://github.com/KhronosGroup/MoltenVK) ·
[Winetricks](https://github.com/Winetricks/winetricks) · [innoextract](https://constexpr.org/innoextract/).
Ver [NOTICE.md](NOTICE.md).

## Licencia

Vitral es software libre bajo la [Licencia Pública General de GNU, versión 3](LICENSE).

Windows es una marca de Microsoft. Vitral no está afiliado a Microsoft, Apple, CodeWeavers ni al
proyecto Wine.

Un proyecto de [Noctavox Labs](https://github.com/noctavox-labs).
