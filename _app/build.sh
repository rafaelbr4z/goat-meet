#!/bin/bash
# Monta o Goat Meet.app. Sem argumentos: monta e instala em ~/Applications.
# Com --verificar: só monta (não mexe no app instalado).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$DIR/build"
APP="$BUILD/Goat Meet.app"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

ARCH="$(uname -m)"
swiftc -O -swift-version 5 -target "$ARCH-apple-macos13.0" \
  "$DIR"/Sources/*.swift \
  -o "$APP/Contents/MacOS/GoatMeet"

cp "$DIR/Info.plist" "$APP/Contents/Info.plist"

# Ícone
if [ -f "$DIR/icone.png" ]; then
  (
    ICONSET="$BUILD/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
      sips -z "$s" "$s" "$DIR/icone.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
      d=$((s * 2))
      sips -z "$d" "$d" "$DIR/icone.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
  ) || echo "Aviso: não consegui gerar o ícone (o app funciona sem ele)."
fi

# Assinatura: com GOAT_ASSINATURA definida usa essa identidade (fixa); sem ela, assinatura local.
codesign --force --sign "${GOAT_ASSINATURA:--}" --identifier com.braz.goatmeet "$APP"
echo "MONTAGEM_OK"

if [ "${1:-}" = "--verificar" ]; then exit 0; fi

# Nunca troca o app no meio de uma gravação.
if [ -n "$(find "$DIR/tmp" -name '*.caf' -mmin -2 2>/dev/null | head -1)" ]; then
  echo "GRAVACAO_EM_ANDAMENTO: app montado, mas NAO instalado. Rode de novo depois da reuniao."
  exit 3
fi

pkill -x GoatMeet 2>/dev/null || true
sleep 1
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Goat Meet.app"
cp -R "$APP" "$HOME/Applications/"

# O app novo tem outra assinatura, e o macOS guarda as permissões pela assinatura.
# Zera só as permissões do próprio Goat Meet para o macOS perguntar de novo, sem ficar um botão "ligado" que não vale.
tccutil reset ScreenCapture com.braz.goatmeet >/dev/null 2>&1 || true
tccutil reset Microphone com.braz.goatmeet >/dev/null 2>&1 || true
tccutil reset Calendar com.braz.goatmeet >/dev/null 2>&1 || true
tccutil reset SystemPolicyRemovableVolumes com.braz.goatmeet >/dev/null 2>&1 || true

echo "App instalado em ~/Applications/Goat Meet.app"
