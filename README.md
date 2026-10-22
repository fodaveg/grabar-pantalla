# Grabar pantalla

Graba una pantalla del Mac con ffmpeg y enseña el estado en la barra de menús. Se lanza desde
Spotlight o desde la terminal.

- Captura con `avfoundation` (puntero y clics marcados) y codifica en H.264 por hardware
  (VideoToolbox). Medido en un MacBook Pro: unos 80 fps.
- Graba la pantalla donde está el puntero al arrancar.
- App residente en la barra de menús: en espera (icono gris), cuenta atrás, punto rojo con el
  tiempo, «Guardando…», ✓ al acabar (y de vuelta a espera) y ⚠ si la captura no arranca.
- Clic izquierdo en el icono: detiene si graba (cancela en la cuenta atrás) y abre el menú en
  espera. Clic derecho o Control + clic: abren el menú siempre.
- Atajo global ⌃⌥⌘R para empezar y detener.
- Deja el vídeo en `~/Movies/pantalla-AAAAMMDD-HHMMSS.mp4`.

## Requisitos

- macOS 13 o posterior.
- `ffmpeg` (`brew install ffmpeg`).
- Xcode o las Command Line Tools, para `swiftc`.

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

La primera vez macOS pide el permiso de «Grabación de pantalla» para «Grabar pantalla» (o para
la terminal, si no hay app). Si ffmpeg no consigue capturar en 10 s, la app lo avisa y dice
dónde activarlo.

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

`grabar-pantalla` en la terminal es un proceso aparte de un solo uso: espera hasta el final,
imprime la ruta, devuelve el código de salida y no reutiliza la app residente (conviven; durante
esa grabación hay dos iconos en la barra).

Para forzar una pantalla: `GRABAR_PANTALLA_INDICE=1 grabar-pantalla 10`. El número es el de
`Capture screen N` en `ffmpeg -f avfoundation -list_devices true -i ""`.

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
- `grabar-pantalla`: script de zsh con toda la lógica de grabación. Si la app está instalada, se
  relanza a través de ella para que salga el icono. Con la app no avisa por `osascript`: la
  notificación es de la app.
- `app/main.swift`: la app de la barra de menús. Sin argumentos es residente (espera, atajo
  global, un `Process` nuevo por grabación); con argumentos, de un solo uso para la terminal.
  Lanza el script como hijo y lee de su salida las líneas `@estado …`.
- `app/icono.swift`: dibuja el icono de la app (círculo rojo con una pantalla).
- `app/instalar.sh`: compila, monta el bundle, genera el icono y firma.

Editar el script no exige reinstalar: la app guarda su ruta. Tocar `app/` sí.

## Licencia

MIT. Ver [LICENSE](LICENSE).
