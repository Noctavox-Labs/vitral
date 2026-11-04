# Vitral

**Programas de Windows en tu Mac, con la menor cantidad de decisiones posible.**

[Read in English](README.md)

> **Estado: en desarrollo temprano.** Todavía no hay una app para instalar. Hoy el repositorio
> tiene `vitral analizar`, una herramienta de línea de comandos que revisa un instalador de
> Windows sin ejecutarlo. En la [hoja de ruta](#hoja-de-ruta) está lo que viene.

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
git clone https://github.com/noctavoxfilms/vitral.git
cd vitral
swift run vitral analizar "ruta/al/Setup.exe"
swift run vitral analizar --json "ruta/al/Setup.exe"   # para otros programas
```

Ejemplo:

```text
Setup.exe  (422 KB)
  Tipo:     Instalador Inno Setup 5.5.7
  Archivo:  Windows de 32 bits, con ventanas
  Necesita: Setup-1a.bin (1,36 GB)
            (tienen que estar en la misma carpeta)
```

Reconoce Inno Setup, NSIS, Windows Installer (`.msi`), WiX Burn, InstallShield, archivos 7-Zip
autoextraíbles, ZIP y programas sueltos, y distingue 16, 32 y 64 bits. Habla español e inglés
(sigue el idioma de macOS; `VITRAL_LANG=es` fuerza español).

## Hoja de ruta

| Fase | Meta |
|------|------|
| **0. Cimientos** *(ahora)* | Repositorio, pruebas automáticas, analizador de instaladores |
| **1. Un comando** | `vitral instalar Setup.exe` crea una app de Mac nítida, portable y con ícono, sin pasos a mano aparte del instalador del programa. Primer objetivo: una app educativa en Qt 5 + QtWebEngine que hoy necesita una docena de arreglos manuales |
| **2. La app** | App en SwiftUI: biblioteca, arrastrar y soltar, «¿Se ve bien?», ajustes avanzados |
| **3. Compartir** | Exportar e importar, versiones firmadas y notarizadas, actualizaciones |
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

[Wine](https://www.winehq.org) · [Wine para macOS de Gcenx](https://github.com/Gcenx/macOS_Wine_builds) ·
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

Un proyecto de [Noctavox Films](https://github.com/noctavoxfilms).
