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

Open an issue with the "An app doesn't work" template and paste the output of
`vitral analyze --json`. Please don't attach the installer.

Abre un issue con la plantilla «Una app no funciona» y pega el resultado de
`vitral analizar --json`. No adjuntes el instalador.
