# Grabar pantalla

Graba una pantalla del Mac con ScreenCaptureKit y enseña el estado en la barra de menús. Se lanza
desde Spotlight o desde la terminal.

- Captura con ScreenCaptureKit (puntero y clics marcados) y escribe H.264 por hardware con
  AVAssetWriter, todo dentro de la app, con audio AAC opcional (sistema y micrófono). Medido en un
  MacBook Pro con una animación a 120 Hz y la calidad «Animaciones»: de 86 a 101 fps en la
  pantalla integrada (con ffmpeg y avfoundation eran 70-76) y los 75 de una externa a 75 Hz.
- Graba la pantalla donde está el puntero al arrancar, una región elegida con un selector sobre
  la pantalla (o con `--region` en la terminal) o una sola ventana de otra app, aunque otra la
  tape (desde el menú o con `--ventana`).
- App residente en la barra de menús, con un icono propio (una circunferencia con algo dentro):
  en espera un punto, cuenta atrás, punto rojo con el tiempo, «Guardando…», ✓ al acabar (y de
  vuelta a espera) y ⚠ si la captura no arranca. Con la memoria encendida, circunferencia a trazos
  y punto rojo pequeño.
- [Memoria de los últimos N segundos](#memoria-de-los-últimos-n-segundos-experimento)
  (experimento): encendida desde el menú, graba en segundo plano y ⌃⌥⌘S guarda los últimos 30 s
  (de 5 a 120), para capturar un fallo intermitente después de verlo.
- Clic izquierdo en el icono: detiene si graba (cancela en la cuenta atrás) y abre el menú en
  espera. Clic derecho o Control + clic: abren el menú siempre.
- Atajo global ⌃⌥⌘R para empezar y detener.
- [Ajustes](#ajustes) (⌘,): carpeta, calidad, cuenta atrás, duración, segundos de la memoria,
  puntero, audio, qué hacer al terminar y abrir al iniciar sesión.
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
| Terminal, una región | `grabar-pantalla --region X,Y,ANCHO,ALTO [segundos]` | Igual |
| Terminal, una ventana | `grabar-pantalla --ventana TEXTO [segundos]` | Igual, o hasta que se cierre la ventana |

La cuenta atrás (3 s por defecto) y todo lo demás sale de los [Ajustes](#ajustes), también en la
terminal; la duración de la terminal es siempre su argumento.

La app de Spotlight es residente: tras cada grabación vuelve a espera y se queda en la barra de
menús hasta «Salir» (⌘Q). Si ya está abierta, abrirla otra vez detiene la grabación en curso o,
en espera, empieza una. Arrancada como ítem de inicio de sesión queda en espera sin grabar.

En espera, el menú tiene «Grabar» (pantalla del puntero), «Grabar una región…», «Grabar una
ventana ▸», «Grabar pantalla ▸» (una entrada por pantalla), «Memoria de los últimos N s» y «Guardar
los últimos N s» ([abajo](#memoria-de-los-últimos-n-segundos-experimento)), «Ajustes…» (⌘,) y «Salir». El atajo
global ⌃⌥⌘R empieza y detiene desde cualquier app, sin permiso de Accesibilidad; siempre graba la
pantalla entera del puntero.

«Grabar una región…» abre un selector como el de ⌘⇧5 en todas las pantallas: las oscurece, pone
el cursor en cruz y, al arrastrar, dibuja el rectángulo con sus medidas en píxeles al lado. El
rectángulo no sale de la pantalla donde empezó el arrastre. Soltar el ratón confirma; Esc, el clic
derecho o un rectángulo de menos de 32x32 píxeles cancelan y vuelven a espera. Tras confirmar, la
grabación es la de siempre (cuenta atrás, duración, calidad, puntero, clics y audio de los
Ajustes), solo de esa zona, y un marco rojo fino la señala mientras tanto. El marco no sale en el
vídeo ni recibe clics.

«Grabar una ventana ▸» lista, al abrirse, las ventanas que hay en ese momento en pantalla de las
otras apps, como «App: título» (el título, recortado a 60 caracteres) y ordenadas por app. Se
quedan fuera las de esta app, las que no tienen título, las de menos de 50x50 puntos y las que no
son ventanas normales (barra de menús, Dock, avisos). Elegir una la graba como siempre (cuenta
atrás, duración, calidad, puntero, clics y audio de los Ajustes), sin marco en pantalla: el vídeo
sale solo con esa ventana, con su barra de título, aunque otra la tape o esté detrás de todo. El
vídeo mide lo que mide la ventana al empezar,
en píxeles de su pantalla (el doble en una Retina) y redondeado a par. Si la ventana cambia de
tamaño mientras se graba, el tamaño del vídeo no cambia: ScreenCaptureKit la escala para que quepa
entera sin deformarla y deja en negro lo que sobra (abajo o a la derecha; en macOS 13 la estira).
Si la ventana se cierra, la grabación se detiene y guarda lo grabado hasta ese momento.

Al terminar, una notificación con el número de fotogramas y los fps ofrece «Mostrar» (Finder; es
también lo que hace pulsarla) y «Copiar ruta», y la ruta del vídeo ya queda en el portapapeles. Los
Ajustes quitan la notificación, su sonido o la copia, y añaden mostrar el vídeo en Finder.

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

`--region X,Y,ANCHO,ALTO` graba solo ese rectángulo de la pantalla elegida (la del puntero o la de
`GRABAR_PANTALLA_INDICE`), en puntos y desde su esquina superior izquierda, con punto decimal si
hace falta: `GRABAR_PANTALLA_INDICE=0 grabar-pantalla --region 100,100,400,300 5`. El vídeo sale a
la resolución nativa, así que en la pantalla Retina mide el doble en píxeles (800x600) y en una
externa a 1x lo mismo; ancho y alto se redondean a par hacia abajo (H.264 lo pide). Una región que
se sale de la pantalla, o mal escrita, es un error con código 2, como cualquier argumento que no
se entiende.

`--ventana TEXTO` graba la primera ventana del submenú «Grabar una ventana» (mismas reglas y mismo
orden) cuyo «App: título» contenga ese texto, sin distinguir mayúsculas ni tildes y mirando el
título entero: `grabar-pantalla --ventana "finder: videos" 10`. Antes de la cuenta atrás imprime
`Ventana: App: título`. `GRABAR_PANTALLA_INDICE` no cuenta: la escala es la de la pantalla donde
está la ventana. Sin ninguna que coincida, sale con 2 y la lista de las que hay; `--ventana` con
`--region` es un error de uso, también con 2. Si la ventana se cierra antes de acabar, avisa en
stderr, guarda lo grabado y sale con 0.

## Memoria de los últimos N segundos (experimento)

Para capturar un fallo intermitente después de verlo, sin haber estado grabando a propósito.
Vive solo en la app residente; la terminal no tiene comando para esto.

- «Memoria de los últimos N s» (una casilla del menú en espera, con el N de los Ajustes) la
  enciende y la apaga. **Siempre empieza apagada** al abrir la app, por privacidad y batería, y no
  hay ajuste para encenderla sola.
- Encendida, graba en segundo plano la pantalla entera donde estaba el puntero al encenderla, con
  la calidad, el puntero y los clics de los Ajustes y **sin audio**. El icono de la barra lo
  enseña: circunferencia a trazos y punto rojo pequeño (distinto de espera y de grabando).
- «Guardar los últimos N s» (activo solo con la memoria encendida) o el atajo global ⌃⌥⌘S guardan
  esos segundos en la carpeta de los Ajustes como `pantalla-AAAAMMDD-HHMMSS-ultimos-Ns.mp4`, y
  después pasa lo mismo que al terminar una grabación (✓, notificación «Últimos N s guardados»,
  copiar la ruta, mostrar en Finder, según los Ajustes). La memoria sigue encendida. Si lleva menos
  de N s encendida, guarda lo que hay, lo dice en la notificación y el nombre lleva los segundos
  reales (`-ultimos-8s`). Si macOS no deja registrar ⌃⌥⌘S, el menú lo dice y queda el menú (que
otro proceso ya tenga la combinación no hace fallar el registro: medido en macOS 27).
- Una grabación normal (menú, atajo, Spotlight, región o ventana) con la memoria encendida la pone
  en pausa: su captura para antes de que arranque la de la grabación, y vuelve al acabar esa
  grabación. Lo guardado después salta del antes al después de la grabación, sin hueco negro.
- El N de los Ajustes vale la próxima vez que se encienda.
- Apagarla o salir de la app (⌘Q, «Salir», SIGTERM) borra lo grabado. Una app muerta de golpe
  deja sus segmentos, y se borran la próxima vez que se enciende la memoria.

Coste, medido en el MacBook Pro (pantalla integrada 3024x1964 a 120 Hz, calidad Normal, 60 s
encendida): la app gasta de media un **5,9 % de un núcleo** con una animación en una esquina
(3,5 s de CPU en 60 s) y un **0,8 %** con el escritorio quieto (0,5 s). La codificación H.264 va en
el codificador por hardware y la captura en los procesos del sistema (WindowServer), que no
cuentan en esa cifra. En disco, los segmentos de N = 30 s ocupan **13,4 MB** con la animación
(16 segmentos) y **5,6 MB** quieto, en `~/Library/Caches/net.fodaveg.grabar-pantalla/memoria/`.
Con toda la pantalla en movimiento serán del orden del peso de Normal de la tabla de los
Ajustes: unos 30-40 MB por 30 s (calculado, no medido).

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
| Memoria | 30 s | De 5 a 120 s: lo que guarda «Guardar los últimos N s» (⌃⌥⌘S). La memoria se enciende en el menú, nunca sola. |
| Puntero | Mostrar, marcar clics | Cada uno por separado. Marcar los clics necesita macOS 15. |
| Audio | Ninguno | Sonido del sistema (todo el Mac salvo esta app), micrófono (el de por defecto; macOS 15), o los dos. |
| Al terminar | Notificación, sonido y copiar la ruta | Además, mostrar el vídeo en Finder. Sin notificación, el sonido es el de alerta del sistema. |
| Abrir al iniciar sesión | No | Con `SMAppService`; la ventana enseña lo que diga macOS, también «pendiente de tu aprobación», con un botón a Ajustes del Sistema. |

Los atajos ⌃⌥⌘R y ⌃⌥⌘S aparecen en la ventana como información; no se cambian.

Las tres calidades son H.264 y las mismas marcas de tiempo variables de la captura. HEVC pesaría
menos, pero Compacta es para adjuntar y un mp4 en HEVC no se ve en todos los navegadores. Peso
medido en un MacBook Pro grabando 15 s de la integrada (3024x1964) con una animación en una
esquina, en dos tandas: A con el resto del escritorio casi quieto (carga 7-9) y B con texto
escribiéndose y desplazándose en otra app (carga 12-15). La ventana enseña el intervalo.

| Calidad | fps medidos (A / B) | Intervalos min / mediana / máx (A) | Vídeo (A / B) | Peso (A / B) |
|---|---|---|---|---|
| Compacta | 29,1 / 28,4 | 25,0 / 33,3 / 50,0 ms | 2,2 / 2,9 Mb/s | 17 / 22 MB/min |
| Normal | 56,5 / 56,1 | 8,3 / 16,7 / 33,3 ms | 6,9 / 9,7 Mb/s | 52 / 73 MB/min |
| Animaciones | 101,5 / 94,3 | 8,3 / 8,3 / 25,0 ms | 14,6 / 27,5 Mb/s | 110 / 206 MB/min |

El bitrate de cada calidad es un objetivo medio, no un límite estricto: con la pantalla quieta pesa
mucho menos y en una grabación corta con mucho detalle puede pasarse algo (Compacta, 2,9 Mb/s con
un objetivo de 2).

El audio va en pistas AAC de 48 kHz del mismo mp4, una por fuente (sistema, estéreo; micrófono,
mono), con las marcas de tiempo de la captura, así que está sincronizado con la imagen. Con las dos
fuentes son dos pistas y no una mezcla: mezclar en vivo dos relojes de audio es frágil y una pista
por fuente no pierde nada. QuickTime las reproduce juntas; otros reproductores dejan elegir o
solo suenan la primera (la del sistema). El vídeo empieza en el primer fotograma y el audio de
antes se descarta.

Las claves se pueden cambiar a mano, p. ej. `defaults write net.fodaveg.grabar-pantalla calidad
animaciones`: `carpeta`, `calidad` (`compacta`, `normal`, `animaciones`), `cuentaAtras`,
`duracion` (0 = hasta Detener), `mostrarPuntero`, `marcarClics`, `audio` (`ninguno`, `sistema`,
`microfono`, `sistemaYMicrofono`), `notificar`, `sonido`, `abrirEnFinder`, `copiarRuta` y `memoria`
(segundos). Un valor
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
| `fotogramas video.mp4 --lento 4` | no saca PNG: un mp4 `<nombre>-lento-4x.mp4` N veces más lento (N de 2 a 20, admite decimales como 2.5), con todos los fotogramas reales y sin audio |

La carpeta sale junto al vídeo (`<nombre>-fotogramas/` o `<nombre>-tramo-<desde>-<hasta>/`) o donde
diga `--salida <dir>`. Con `--tramo` imprime también el intervalo medio y máximo entre fotogramas
en ms: un máximo muy por encima del medio delata saltos en la grabación. Más de 300 imágenes en un
tramo exigen `--forzar`. `--ancho <px>` escala; sin él, el muestreo y la hoja salen a 1600 px y
`--tramo` a tamaño original. El tiempo sobre las miniaturas de la hoja usa ImageMagick
(`brew install imagemagick`); sin él, la hoja sale sin texto.

`--lento N` sirve para ver a cámara lenta una animación grabada. No reencoda ni remuestrea: multiplica
por N las marcas de tiempo de cada fotograma (`ffmpeg -itsscale N ... -c:v copy`), así que la copia
tiene exactamente los mismos fotogramas, cada uno N veces más tiempo en pantalla, sin inventar
ninguno. **La copia no lleva audio**: a esa velocidad no se entiende. Sale junto al vídeo o en
`--salida <dir>`, y si ya existe se sobrescribe. Al acabar imprime la ruta, la duración antes y
después y el número de fotogramas. La duración de la copia puede quedar unos milisegundos por debajo
de N veces la original, porque el mp4 no guarda cuánto dura el último fotograma.

## Cómo está hecho

- `fotogramas`: script de zsh que saca los PNG con ffmpeg (el vídeo no se toca).
- `grabar-pantalla`: lanzador de la terminal. Se reemplaza (`exec`) por la app con los mismos
  argumentos y entorno; sin la app instalada, dice cómo instalarla.
- `app/main.swift`: la app de la barra de menús, que graba ella misma. Sin argumentos es
  residente (espera, atajo global, Ajustes, una captura nueva por grabación); con argumentos, de
  un solo uso para la terminal. Las dos leen los Ajustes al empezar cada grabación.
  - Captura: `SCStream` de ScreenCaptureKit sobre la pantalla elegida, a su resolución nativa en
    píxeles, con el `minimumFrameInterval` de la calidad, puntero y, en macOS 15 o posterior, clics
    marcados (los dos según los Ajustes). Qué se graba es un `Destino`: la pantalla entera, una
    región, que es la misma captura con `sourceRect` (en puntos) y `width`/`height` en píxeles a
    la escala de esa pantalla, ajustados a píxeles enteros y pares, o una ventana. El filtro de
    contenido de pantalla y región deja fuera las ventanas de la propia app (también las de la
    otra instancia, residente o de terminal, y el marco de la región). La ventana es
    `SCContentFilter(desktopIndependentWindow:)`, que la compone sola aunque esté tapada, con
    `width`/`height` fijos al empezar (su marco por la escala de su pantalla), `scalesToFit` y
    `preservesAspectRatio`. Al cerrarse, ScreenCaptureKit da unos fotogramas en blanco (que no
    se escriben) y para el stream con el error -3815 (sin nada que capturar), que guarda lo
    grabado como cualquier corte de la captura. Solo se escriben los
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
- `app/region.swift`: el selector de región (una ventana sin borde por pantalla, por encima de la
  barra de menús, que toma el teclado mientras está abierto y al cerrarse devuelve el foco a la
  app de antes), el marco de la región y el paso de coordenadas de AppKit (origen abajo a la
  izquierda de la pantalla principal) a puntos de la pantalla desde arriba a la izquierda.
- `app/ventana.swift`: qué ventanas se ofrecen (de `SCShareableContent`, solo las que están en
  pantalla, y el filtro de arriba), su nombre «App: título», la búsqueda de `--ventana`, la
  pantalla donde está cada una (la que tiene más superficie de ella) y el relleno del submenú,
  que hace la app al abrirse (`menuNeedsUpdate`), esperando la respuesta de ScreenCaptureKit
  (unas decenas de ms) para enseñarlo ya relleno.
- `app/memoria.swift`: la memoria de los últimos N segundos. Un `SCStream` propio de la pantalla
  entera (la misma configuración que una grabación, sin audio) y un `AVAssetWriter` nuevo cada
  unos 2 s, cortando en un fotograma: ese fotograma es el primero del escritor nuevo, y por eso
  fotograma clave, y el último del segmento anterior dura justo hasta él, así que entre segmentos
  no hay hueco. El escritor siguiente se prepara a mitad de segmento para que el corte no espere
  al codificador. Se conservan los segmentos justos para cubrir N s, en una carpeta por proceso
  dentro de `~/Library/Caches/net.fodaveg.grabar-pantalla/memoria/`. Al guardar se cierra el
  segmento en curso en ese instante (el mismo fotograma abre el siguiente, y la memoria sigue), se
  unen los segmentos con `AVMutableComposition` recortando por delante a N s y se exporta con
  `AVAssetExportSession` en passthrough, sin reencodar. La pausa para el stream y la grabación
  normal espera a que haya parado: nunca hay dos `SCStream` de la app a la vez.
- `app/icono.swift`: dibuja el icono de la app (círculo rojo con una pantalla).
- `app/instalar.sh`: compila `main.swift`, `ajustes.swift`, `region.swift`, `ventana.swift` y `memoria.swift`, monta el bundle,
  genera el icono y firma. Guarda en el Info.plist la ruta del repo, que la app usa para encontrar `fotogramas`.

Tocar `app/` exige reinstalar; los scripts, no.

## Para desarrolladores: probar la memoria sin la residente

La memoria vive en la app residente. Para probarla desde la terminal, sin abrirla, hay un punto de
entrada de prueba (no es para usarlo a diario): la variable `GRABAR_PANTALLA_PRUEBA_MEMORIA`, al
lanzar el binario de la app directamente.

```sh
app=~/"Applications/Grabar pantalla.app/Contents/MacOS/grabar-pantalla"
GRABAR_PANTALLA_INDICE=0 GRABAR_PANTALLA_PRUEBA_MEMORIA=40,30 "$app"           # 40 s encendida, N = 30
GRABAR_PANTALLA_PRUEBA_MEMORIA=40,30,10+5 "$app"                              # y a los 10 s, una grabación normal de 5 s
GRABAR_PANTALLA_PRUEBA_MEMORIA=14,10,5+3 "$app" -cuentaAtras 0                # igual, sin cuenta atrás
```

Con `SEGUNDOS,N` enciende la memoria con ese N (de 5 a 120), espera esos segundos, guarda por el
mismo camino que ⌃⌥⌘S (notificación y portapapeles incluidos, según los Ajustes), imprime
`Hecho: <ruta>`, los segmentos antes y después de apagarla y los instantes de las uniones entre
segmentos en el vídeo, vuelve a encenderla 3 s y sale por el camino de ⌘Q (la carpeta de segmentos,
con el pid, se mira desde fuera cuando el proceso ha terminado). Con `,DESDE+DURANTE` hace además
una grabación normal (`Hecho: <ruta>` también) a los DESDE s, que pone la memoria en pausa. No lee
argumentos de grabación; sí `-clave valor` de los Ajustes para ese proceso, como `-cuentaAtras 0`.
`GRABAR_PANTALLA_INDICE` elige la pantalla como en la terminal. Sale con 0 si guardó un vídeo, con
1 si no y con 2 si la variable está mal escrita.

Medido así (MacBook Pro, integrada a 120 Hz, Normal, una animación de prueba en una esquina):
`40,30` da un vídeo de 30,000 s, sin errores de `ffmpeg -v error -i x -f null -`, con 15 uniones;
el intervalo entre fotogramas alrededor de cada unión no pasa de 33,3 ms, el mismo máximo que
fuera de ellas (60 fps pedidos en una pantalla de 120 Hz dan 16,7 ms casi siempre, y 8,3, 25 o
33,3 ms a ratos), y `fotogramas --tramo` alrededor de dos uniones da 18,2 y 17,3 ms de media. `8,30`
guarda 8,06 s y lo dice.

## Licencia

MIT. Ver [LICENSE](LICENSE).
