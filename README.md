# Grabar pantalla

Graba una pantalla del Mac con ScreenCaptureKit y enseña el estado en la barra de menús. Se lanza
desde Spotlight o desde la terminal.

- Captura con ScreenCaptureKit (puntero y clics marcados) y escribe H.264 por hardware con
  AVAssetWriter, todo dentro de la app. Medido en un MacBook Pro con una animación a 120 Hz: de 86
  a 101 fps en la pantalla integrada (con ffmpeg y avfoundation eran 70-76) y los 75 de una
  externa a 75 Hz.
- Graba la pantalla donde está el puntero al arrancar.
- App residente en la barra de menús: en espera (icono gris), cuenta atrás, punto rojo con el
  tiempo, «Guardando…», ✓ al acabar (y de vuelta a espera) y ⚠ si la captura no arranca.
- Clic izquierdo en el icono: detiene si graba (cancela en la cuenta atrás) y abre el menú en
  espera. Clic derecho o Control + clic: abren el menú siempre.
- Atajo global ⌃⌥⌘R para empezar y detener.
- Deja el vídeo en `~/Movies/pantalla-AAAAMMDD-HHMMSS.mp4`.

## Requisitos

- macOS 13 o posterior (los clics marcados, desde macOS 15).
- Xcode o las Command Line Tools, para `swiftc`.
- `ffmpeg` (`brew install ffmpeg`), solo para `fotogramas`: la grabación no lo usa.

## Instalar

```sh
git clone https://github.com/fodaveg/grabar-pantalla.git
cd grabar-pantalla
app/instalar.sh
ln -s "$PWD/grabar-pantalla" ~/.local/bin/grabar-pantalla   # opcional, para la terminal
```

`app/instalar.sh` compila la app y la deja en `~/Applications/Grabar pantalla.app`. La firma con
el certificado «Apple Development» del llavero si lo hay. Si no lo hay, la firma ad hoc, y
entonces macOS vuelve a pedir el permiso de Grabación de pantalla tras cada reinstalación.

La primera vez macOS pide el permiso de «Grabación de pantalla» para «Grabar pantalla». Sin él,
la app pasa a ⚠ al acabar la cuenta atrás y dice dónde activarlo. `grabar-pantalla` en la
terminal necesita la app instalada: sin ella, lo dice y sale con 1.

La primera vez que graba, la app pide permiso para enviar notificaciones: hay que aceptarlo para
ver el aviso «Grabación terminada» (con «Mostrar» y «Copiar ruta»). Se cambia en Ajustes del
Sistema > Notificaciones.

## Usar

| Desde | Cómo | Duración |
|---|---|---|
| Spotlight, Finder, `open` | «Grabar pantalla» | Graba al instante la pantalla del puntero, hasta Detener (tope de 30 min). |
| Terminal | `grabar-pantalla [segundos]` | 15 s por defecto; `0` = hasta Detener |

La app de Spotlight es residente: tras cada grabación vuelve a espera y se queda en la barra de
menús hasta «Salir» (⌘Q). Si ya está abierta, abrirla otra vez detiene la grabación en curso o,
en espera, empieza una. Arrancada como ítem de inicio de sesión queda en espera sin grabar.

En espera, el menú tiene «Grabar» (pantalla del puntero), «Grabar pantalla ▸» (una entrada por
pantalla), «Ajustes…» (todavía deshabilitado) y «Salir». El atajo global ⌃⌥⌘R empieza y detiene
desde cualquier app, sin permiso de Accesibilidad.

Al terminar, una notificación con el número de fotogramas y los fps ofrece «Mostrar» (Finder; es
también lo que hace pulsarla) y «Copiar ruta».

«Sacar fotogramas» (en el menú del ✓, y en espera para la última grabación) pasa el vídeo por
[`fotogramas`](#fotogramas-para-agentes) con el muestreo por defecto y abre la carpeta en Finder.
Si falta `fotogramas` o ffmpeg, lo avisa.

`grabar-pantalla` en la terminal es un proceso aparte de un solo uso: espera hasta el final,
imprime los fotogramas escritos y la ruta, sale con 0 si hay vídeo válido y no reutiliza la app
residente (conviven; durante esa grabación hay dos iconos en la barra). Ctrl-C detiene y deja el
mp4 cerrado.

Para forzar una pantalla: `GRABAR_PANTALLA_INDICE=1 grabar-pantalla 10`. 0 es la principal de
Ajustes > Pantallas y el resto siguen el orden del sistema (`CGGetActiveDisplayList`, el mismo que
numeraba `ffmpeg -f avfoundation -list_devices true -i ""`).

## Fotogramas para agentes

Un agente lee imágenes, no vídeo. `fotogramas` saca PNG de una grabación, con el tiempo en el
nombre (`t002345ms.png`) para poder citarlos:

| Comando | Qué saca |
|---|---|
| `fotogramas video.mp4 [N]` | N fotogramas repartidos por todo el vídeo (12 por defecto) |
| `fotogramas video.mp4 --hoja [N]` | un solo PNG, `hoja.png`, con N miniaturas y su tiempo |
| `fotogramas video.mp4 --tramo 2.0 3.5` | TODOS los fotogramas entre esos segundos, sin saltarse ni duplicar ninguno |

La carpeta sale junto al vídeo (`<nombre>-fotogramas/` o `<nombre>-tramo-<desde>-<hasta>/`) o donde
diga `--salida <dir>`. Con `--tramo` imprime también el intervalo medio y máximo entre fotogramas
en ms: un máximo muy por encima del medio delata saltos en la grabación. Más de 300 imágenes en un
tramo exigen `--forzar`. `--ancho <px>` escala; sin él, el muestreo y la hoja salen a 1600 px y
`--tramo` a tamaño original. El tiempo sobre las miniaturas de la hoja usa ImageMagick
(`brew install imagemagick`); sin él, la hoja sale sin texto.

## Cómo está hecho

- `fotogramas`: script de zsh que saca los PNG con ffmpeg (el vídeo no se toca).
- `grabar-pantalla`: lanzador de la terminal. Se reemplaza (`exec`) por la app con los mismos
  argumentos y entorno; sin la app instalada, dice cómo instalarla.
- `app/main.swift`: la app de la barra de menús, que graba ella misma. Sin argumentos es
  residente (espera, atajo global, una captura nueva por grabación); con argumentos, de un solo
  uso para la terminal.
  - Captura: `SCStream` de ScreenCaptureKit sobre la pantalla elegida, a su resolución nativa en
    píxeles, con `minimumFrameInterval` de 1/120 s, puntero y, en macOS 15 o posterior, clics
    marcados. El filtro de contenido deja fuera las ventanas de la propia app (también las de la
    otra instancia, residente o de terminal). Solo se escriben los fotogramas completos:
    ScreenCaptureKit entrega cuando cambia algo, así que el vídeo sale con fps variable y las
    marcas de tiempo de la captura, sin remuestrear.
  - Escritura: `AVAssetWriter` a mp4, H.264 por hardware a 40 Mb/s. La sesión empieza en el primer
    fotograma completo y el último dura hasta el momento de detener, aunque la pantalla estuviera
    quieta. Detener por cualquier vía (clic, atajo, reapertura, Salir, Ctrl-C, SIGTERM, el tope o
    los segundos pedidos) cierra el mp4 con `finishWriting`. Si la app muere de golpe (SIGKILL),
    ese vídeo se pierde.
  - fps y bitrate están juntos en `Calidad`, al principio del fichero, para los Ajustes.
- `app/icono.swift`: dibuja el icono de la app (círculo rojo con una pantalla).
- `app/instalar.sh`: compila, monta el bundle, genera el icono y firma. Guarda en el Info.plist la
  ruta del repo, que la app usa para encontrar `fotogramas`.

Tocar `app/` exige reinstalar; los scripts, no.

## Licencia

MIT. Ver [LICENSE](LICENSE).
