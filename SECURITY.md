# Security / Seguridad

## Reporting a vulnerability / Reportar una vulnerabilidad

Please report security problems privately through GitHub: **Security → Report a vulnerability**
in this repository. Do not open a public issue.

Reporta los problemas de seguridad en privado desde GitHub: **Security → Report a vulnerability**
en este repositorio. No abras un issue público.

## What to keep in mind / Qué tener en cuenta

- **Wine is not a sandbox.** A Windows program running through Vitral can read the files Wine
  lets it see. Install only software you trust. Vitral will limit which folders are visible
  by default.
  **Wine no es una caja aislada.** Un programa de Windows en Vitral puede leer los archivos que
  Wine le deje ver. Instala solo programas de confianza. Vitral va a limitar por defecto qué
  carpetas son visibles.
- Shared apps will be imported through Vitral, which will verify them before removing macOS
  quarantine.
  Las apps compartidas se van a importar con Vitral, que las verificará antes de quitar la
  cuarentena de macOS.
