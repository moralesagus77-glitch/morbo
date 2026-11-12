# Música 27

Reproductor de música para iPhone y iPad con iOS 16 o superior (funciona en iOS 27). Busca canciones en YouTube Music y las reproduce, también con la pantalla apagada, con controles en la pantalla de bloqueo. Usa el mismo método que YTMLegacy: YouTube directo y, si falla, instancias públicas de Piped e Invidious.

## Obtener el .ipa sin Mac

1. Creá un repositorio **público** en GitHub y subí todo el contenido de esta carpeta. Fijate que se suba también la carpeta oculta `.github`.
2. En la pestaña **Actions** elegí **Build IPA** y tocá **Run workflow**. Tarda unos 5 minutos.
3. Cuando termine, entrá a la ejecución y bajá el artefacto **Musica27-ipa** (adentro está `Musica27.ipa`).
4. Instalalo con Sideloadly o AltStore usando tu Apple ID. Con un Apple ID gratuito la firma vence a los 7 días y hay que renovarla.

El .ipa sale sin firmar a propósito: lo firma la herramienta con la que lo instalás.

## Con un Mac

```
brew install xcodegen
xcodegen generate
open Musica27.xcodeproj
```

Elegí tu equipo en Signing & Capabilities y ejecutá.

## Si algo no anda

- La app guarda un registro en **Ajustes > Registro**. Copialo y pasámelo.
- Si falla la compilación en GitHub, pasame el error que aparece en la pestaña Actions.
- Si no busca o no reproduce, probá agregar tu propia instancia de Piped o Invidious en Ajustes.
