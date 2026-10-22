# Grabar pantalla

Graba una pantalla del Mac con ffmpeg y enseña el estado en la barra de menús. Se lanza desde
Spotlight o desde la terminal.

- Captura con `avfoundation` (puntero y clics marcados) y codifica en H.264 por hardware
  (VideoToolbox). Medido en un MacBook Pro: unos 80 fps.
- Graba la pantalla donde está el puntero al arrancar.
- Icono en la barra de menús: cuenta atrás, punto rojo con el tiempo, «Guardando…», ✓ al acabar
  y ⚠ si la captura no arranca.
- Clic derecho en el icono: detiene la grabación. Clic izquierdo: menú.
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

## Usar

| Desde | Cómo | Duración |
|---|---|---|
| Spotlight | «Grabar pantalla» | Hasta pulsar Detener (tope de 30 min). Volver a abrirla también detiene. |
| Terminal | `grabar-pantalla [segundos]` | 15 s por defecto; `0` = hasta Detener |

Para forzar una pantalla: `GRABAR_PANTALLA_INDICE=1 grabar-pantalla 10`. El número es el de
`Capture screen N` en `ffmpeg -f avfoundation -list_devices true -i ""`.

## Cómo está hecho

- `grabar-pantalla`: script de zsh con toda la lógica de grabación. Si la app está instalada, se
  relanza a través de ella para que salga el icono.
- `app/main.swift`: la app de la barra de menús. Lanza el script como hijo y lee de su salida
  las líneas `@estado …`.
- `app/icono.swift`: dibuja el icono de la app (círculo rojo con una pantalla).
- `app/instalar.sh`: compila, monta el bundle, genera el icono y firma.

Editar el script no exige reinstalar: la app guarda su ruta. Tocar `app/` sí.
