# Contributing / Cómo colaborar

Thanks for your interest! / ¡Gracias por el interés!

## Build and test / Compilar y probar

```sh
swift build
swift test
swift run vitral analyze "path/to/Setup.exe"
```

Requires a Mac with Apple silicon, macOS 14+, and Xcode or the Command Line Tools.

## Rules / Reglas

- **Two languages.** Every user-facing text needs Spanish and English (`tr("…", "…")` for now).
  Code, comments and commit messages are in English.
  **Dos idiomas.** Todo texto que vea el usuario va en español e inglés. El código, los
  comentarios y los commits van en inglés.
- **Never run what you are analyzing.** The analyzer only reads bytes.
  **Nunca ejecutar lo que se analiza.** El analizador solo lee bytes.
- **No telemetry**, and downloads only from official sources with pinned SHA-256 checksums.
  **Sin telemetría**, y descargas solo de fuentes oficiales con SHA-256 fijado.
- **Anti-cheat is detected and explained, never bypassed or disguised.**
  **Los antitrampas se detectan y se explican; nunca se eluden ni se disfraza el entorno.**
- **Licenses.** Only bring in code under a GPL-3.0-compatible license, and record it in
  `NOTICE.md`. Code without a license (for example Sikarugir's Creator, Template and Engines)
  cannot be used.
  **Licencias.** Solo código con licencia compatible con GPL-3.0, anotado en `NOTICE.md`. El
  código sin licencia no se puede usar.
- **No installers or copyrighted files in the repository.** Tests use synthetic files.
  **Nada de instaladores ni archivos con derechos de autor en el repositorio.** Las pruebas usan
  archivos sintéticos.

## Reporting a program that doesn't work / Reportar un programa que no funciona

In Vitral, use **Report a Problem…** (in the alert when a program closes while opening, or in the
library's menu), or run `vitral report --open <app>`: it opens the "An app doesn't work" form
filled in, with a report you can read and edit first. Please don't attach the installer.

En Vitral, usa **Informar un problema…** (en el aviso cuando un programa se cierra al abrir, o en
el menú de la biblioteca), o `vitral informe --abrir <app>`: abre el formulario «Una app no
funciona» lleno, con un informe que puedes leer y cambiar antes. No adjuntes el instalador.

## Known failures / Fallas conocidas

`catalog/failures.json` lists the failures Vitral recognizes and the fixes it tries by itself:
each with how it shows in the logs, when it applies, what to try (settings, recipes, official
components; never code) and where it was learned. To propose one, edit that file, raise its
`revision` (`YYYYMMDDnn`), run `scripts/embed-catalog.py` and `swift test`, and add a test with
the real log lines. Publishing it signed (`scripts/sign-catalog.sh`) needs the release key, so
only maintainers do that.

`catalog/failures.json` lista las fallas que Vitral reconoce y los arreglos que prueba solo: cómo
se ve cada una en los registros, cuándo aplica, qué probar (ajustes, recetas, componentes
oficiales; nunca código) y de dónde salió. Para proponer una, edita ese archivo, sube su
`revision` (`AAAAMMDDnn`), corre `scripts/embed-catalog.py` y `swift test`, y suma una prueba con
las líneas reales del registro. Publicarlo firmado (`scripts/sign-catalog.sh`) necesita la llave
de las versiones, así que lo hacen los mantenedores.
