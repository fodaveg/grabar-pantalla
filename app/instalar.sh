#!/usr/bin/env zsh
# Compila main.swift y monta ~/Applications/Grabar pantalla.app (app de barra de menús, LSUIElement)
# firmada con el certificado «Apple Development» del llavero (ad hoc si no lo hay). La ruta
# absoluta de ../grabar-pantalla queda en el Info.plist (clave GrabarPantallaScript): editar el
# script no exige reinstalar; tocar main.swift, sí. Con el certificado, el permiso de «Grabación de pantalla» sobrevive a las recompilaciones (TCC
# lo ata al identificador y al equipo); con firma ad hoc lo ata al hash y lo vuelve a pedir cada vez.
set -euo pipefail
aqui=${0:A:h}
script=${aqui:h}/grabar-pantalla
bundle=~/"Applications/Grabar pantalla.app"
mkdir -p "$bundle/Contents/MacOS"
/usr/bin/swiftc -O "$aqui/main.swift" -o "$bundle/Contents/MacOS/grabar-pantalla"
# Icono: se dibuja con código (icono.swift) en cada instalación; no hay PNG en el repo.
tmp=$(mktemp -d)
/usr/bin/swiftc -O "$aqui/icono.swift" -o "$tmp/icono"
"$tmp/icono" "$tmp/AppIcon.iconset"
mkdir -p "$bundle/Contents/Resources"
/usr/bin/iconutil -c icns "$tmp/AppIcon.iconset" -o "$bundle/Contents/Resources/AppIcon.icns"
rm -rf "$tmp"
cat > "$bundle/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>grabar-pantalla</string>
  <key>CFBundleIdentifier</key><string>net.fodaveg.grabar-pantalla</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleName</key><string>Grabar pantalla</string>
  <key>CFBundleDisplayName</key><string>Grabar pantalla</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSScreenCaptureUsageDescription</key><string>Grabar la pantalla con ffmpeg.</string>
  <key>GrabarPantallaScript</key><string>$script</string>
</dict></plist>
EOF
identidad=$(security find-identity -v -p codesigning | grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"' || true)
/usr/bin/codesign -s "${identidad:--}" --force "$bundle"
# Refrescar la caché de iconos de Finder/Spotlight/Dock.
touch "$bundle"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$bundle" 2>/dev/null || true
/usr/bin/mdimport "$bundle" 2>/dev/null || true
echo "Instalada: $bundle (script: $script)"
