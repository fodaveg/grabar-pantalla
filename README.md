# Grabar pantalla

Graba una pantalla del Mac con ScreenCaptureKit y enseña el estado en la barra de menús. Se lanza
desde Spotlight o desde la terminal.

- Captura con ScreenCaptureKit (puntero y clics marcados) y escribe H.264 por hardware con
  AVAssetWriter, todo dentro de la app, con audio AAC opcional (sistema y micrófono). Medido en un
  MacBook Pro con una animación a 120 Hz y la calidad «Animaciones»: de 86 a 101 fps en la
  pantalla integrada (con ffmpeg y avfoundation eran 70-76) y los 75 de una externa a 75 Hz.
- Graba la pantalla donde está el puntero al arrancar.
- App residente en la barra de menús: en espera (icono gris), cuenta atrás, punto rojo con el
  tiempo, «Guardando…», ✓ al acabar (y de vuelta a espera) y ⚠ si la captura no arranca.
- Clic izquierdo en el icono: detiene si graba (cancela en la cuenta atrás) y abre el menú en
  espera. Clic derecho o Control + clic: abren el menú siempre.
- Atajo global ⌃⌥⌘R para empezar y detener.
- [Ajustes](#ajustes) (⌘,): carpeta, calidad, cuenta atrás, duración, puntero, audio, qué hacer al
  terminar y abrir al iniciar sesión.
- Deja el vídeo en `~/Movies/pantalla-AAAAMMDD-HHMMSS.mp4`, o en la carpeta de los Ajustes.

## Requisitos

- macOS 13 o posterior (los clics marcados y el micrófono, desde macOS 15).
- Xcode o las Command Line Tools, para `swiftc`.
- `ffmpeg` (`brew install ffmpeg`), solo para `fotogramas`: la grabación no lo usa.

## Instalar

```sh
git clone https://github.com/fodaveg/grabar-pantalla.git
cd grabar-pantalla
app/instalar.sh
ln -s "$PWD/grabar-pantalla" ~/.local/bin/grabar-pantalla   # opcional, para la terminal
```

`app/instalar.sh` compila la app y la deja en `~/Applications/Grabar pantalla.app`. Una residente
ya abierta sigue con el código de antes hasta que se cierra y se vuelve a abrir. La firma con
el certificado «Apple Development» del llavero si lo hay. Si no lo hay, la firma ad hoc, y
entonces macOS vuelve a pedir el permiso de Grabación de pantalla tras cada reinstalación.

La primera vez macOS pide el permiso de «Grabación de pantalla» para «Grabar pantalla». Sin él,
la app pasa a ⚠ al acabar la cuenta atrás y dice dónde activarlo. `grabar-pantalla` en la
terminal necesita la app instalada: sin ella, lo dice y sale con 1.

La primera vez que graba, la app pide permiso para enviar notificaciones: hay que aceptarlo para
ver el aviso «Grabación terminada» (con «Mostrar» y «Copiar ruta»). Se cambia en Ajustes del
Sistema > Notificaciones.

El audio del sistema entra con el mismo permiso de «Grabación de pantalla y audio del sistema». El
micrófono tiene permiso propio: macOS lo pide al empezar la primera grabación con micrófono. Si se
deniega, se graba sin él y la app lo avisa. Lanzada desde la terminal, la app usa los permisos de
la terminal (macOS se los atribuye a ella), no los suyos.

## Usar

| Desde | Cómo | Duración |
|---|---|---|
| Spotlight, Finder, `open` | «Grabar pantalla» | Graba la pantalla del puntero tras la cuenta atrás, hasta Detener (tope de 30 min) o los segundos de los Ajustes. |
| Terminal | `grabar-pantalla [segundos]` | 15 s por defecto; `0` = hasta Detener |

La cuenta atrás (3 s por defecto) y todo lo demás sale de los [Ajustes](#ajustes), también en la
terminal; la duración de la terminal es siempre su argumento.

La app de Spotlight es residente: tras cada grabación vuelve a espera y se queda en la barra de
menús hasta «Salir» (⌘Q). Si ya está abierta, abrirla otra vez detiene la grabación en curso o,
en espera, empieza una. Arrancada como ítem de inicio de sesión queda en espera sin grabar.

En espera, el menú tiene «Grabar» (pantalla del puntero), «Grabar pantalla ▸» (una entrada por
pantalla), «Ajustes…» (⌘,) y «Salir». El atajo global ⌃⌥⌘R empieza y detiene desde cualquier
app, sin permiso de Accesibilidad.

Al terminar, una notificación con el número de fotogramas y los fps ofrece «Mostrar» (Finder; es
también lo que hace pulsarla) y «Copiar ruta». Los Ajustes la quitan, quitan su sonido o añaden
mostrar el vídeo en Finder y copiar su ruta al momento.

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

## Ajustes

«Ajustes…» (⌘,) en el menú de la app residente abre una ventana de una sola página. Se abre en
cualquier estado salvo grabando; si está abierta cuando empieza una grabación (por el atajo, por
ejemplo), deshabilita sus controles hasta que termine. Cada cambio se guarda al momento en las
preferencias de la app y vale desde la siguiente grabación, también la de la terminal.

| Ajuste | Por defecto | Qué hace |
|---|---|---|
| Guardar en | `~/Movies` | Carpeta del mp4, con selector. Si deja de existir (un disco desconectado) o no deja escribir, la grabación va a `~/Movies` y la app avisa con una notificación; la ventana lo dice en naranja. Una carpeta que falte no se crea. |
| Calidad | Normal | Compacta: 30 fps, 2 Mb/s. Normal: 60 fps, 12 Mb/s. Animaciones: todos los fps de la pantalla (120 en la integrada, 75 en una externa a 75 Hz), 40 Mb/s. |
| Cuenta atrás | 3 s | De 0 a 10 s. Con 0 empieza al momento. |
| Duración | Hasta Detener | O N segundos, de 1 a 1800. Vale para el menú, el icono y el atajo; la terminal sigue con su argumento. El tope de 30 min no se ajusta. |
| Puntero | Mostrar, marcar clics | Cada uno por separado. Marcar los clics necesita macOS 15. |
| Audio | Ninguno | Sonido del sistema (todo el Mac salvo esta app), micrófono (el de por defecto; macOS 15), o los dos. |
| Al terminar | Notificación y sonido | Además, mostrar el vídeo en Finder y copiar su ruta. Sin notificación, el sonido es el de alerta del sistema. |
| Abrir al iniciar sesión | No | Con `SMAppService`; la ventana enseña lo que diga macOS, también «pendiente de tu aprobación», con un botón a Ajustes del Sistema. |

El atajo ⌃⌥⌘R aparece en la ventana como información; no se cambia.

Las tres calidades son H.264 y las mismas marcas de tiempo variables de la captura. HEVC pesaría
menos, pero Compacta es para adjuntar y un mp4 en HEVC no se ve en todos los navegadores. Peso
medido grabando 15 s de la integrada (3024x1964) con una animación en una esquina y el resto del
escritorio quieto, en un MacBook Pro con carga 7-9:

| Calidad | fps medidos | Vídeo | Peso |
|---|---|---|---|
| Compacta | 29,1 | 2,2 Mb/s | 17 MB/min |
| Normal | 56,5 | 6,9 Mb/s | 52 MB/min |
| Animaciones | 101,5 (intervalos de 8,3 ms de mediana, 25 ms de máximo) | 14,6 Mb/s | 110 MB/min |

El bitrate de cada calidad es un techo: con la pantalla quieta pesa mucho menos y con mucho
movimiento a pantalla completa puede llegar a él (15, 90 y 300 MB/min).

El audio va en pistas AAC de 48 kHz del mismo mp4, una por fuente (sistema, estéreo; micrófono,
mono), con las marcas de tiempo de la captura, así que está sincronizado con la imagen. Con las dos
fuentes son dos pistas y no una mezcla: mezclar en vivo dos relojes de audio es frágil y una pista
por fuente no pierde nada. QuickTime las reproduce juntas; otros reproductores dejan elegir o
solo suenan la primera (la del sistema). El vídeo empieza en el primer fotograma y el audio de
antes se descarta.

Las claves se pueden cambiar a mano, p. ej. `defaults write net.fodaveg.grabar-pantalla calidad
animaciones`: `carpeta`, `calidad` (`compacta`, `normal`, `animaciones`), `cuentaAtras`,
`duracion` (0 = hasta Detener), `mostrarPuntero`, `marcarClics`, `audio` (`ninguno`, `sistema`,
`microfono`, `sistemaYMicrofono`), `notificar`, `sonido`, `abrirEnFinder` y `copiarRuta`. Un valor
fuera de rango se ajusta al límite. `defaults delete net.fodaveg.grabar-pantalla` vuelve a todo lo
de por defecto.

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
  residente (espera, atajo global, Ajustes, una captura nueva por grabación); con argumentos, de
  un solo uso para la terminal. Las dos leen los Ajustes al empezar cada grabación.
  - Captura: `SCStream` de ScreenCaptureKit sobre la pantalla elegida, a su resolución nativa en
    píxeles, con el `minimumFrameInterval` de la calidad, puntero y, en macOS 15 o posterior, clics
    marcados (los dos según los Ajustes). El filtro de contenido deja fuera las ventanas de la
    propia app (también las de la otra instancia, residente o de terminal). Solo se escriben los
    fotogramas completos: ScreenCaptureKit entrega cuando cambia algo, así que el vídeo sale con
    fps variable y las marcas de tiempo de la captura, sin remuestrear.
  - Audio: `capturesAudio` (sin el audio de la propia app) y, en macOS 15, `captureMicrophone`, en
    la misma cola que la imagen; cada fuente a su entrada AAC del escritor.
  - Escritura: `AVAssetWriter` a mp4, H.264 por hardware al bitrate de la calidad. La sesión empieza
    en el primer fotograma completo y el último dura hasta el momento de detener, aunque la
    pantalla estuviera quieta. Detener por cualquier vía (clic, atajo, reapertura, Salir, Ctrl-C,
    SIGTERM, el tope o los segundos pedidos) cierra el mp4 con `finishWriting`. Si la app muere de
    golpe (SIGKILL), ese vídeo se pierde.
  - fps, bitrate y peso medido de cada calidad están juntos en `Calidad`, al principio del fichero.
  - Al arrancar como residente deja en el registro del sistema si macOS la abrió como ítem de
    inicio de sesión: `/usr/bin/log show --last 10m --predicate 'subsystem == "net.fodaveg.grabar-pantalla"'`.
- `app/ajustes.swift`: las claves de los Ajustes, su lectura con límites y la ventana (AppKit, sin
  storyboard).
- `app/icono.swift`: dibuja el icono de la app (círculo rojo con una pantalla).
- `app/instalar.sh`: compila `main.swift` y `ajustes.swift`, monta el bundle, genera el icono y
  firma. Guarda en el Info.plist la ruta del repo, que la app usa para encontrar `fotogramas`.

Tocar `app/` exige reinstalar; los scripts, no.

## Licencia

MIT. Ver [LICENSE](LICENSE).
