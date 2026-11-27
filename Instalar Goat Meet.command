#!/bin/bash
# Instalador do Goat Meet. Pode rodar de novo quantas vezes quiser: ele pula o que já estiver pronto.
cd "$(dirname "$0")/_app" || exit 1
exec > >(tee -a install.log) 2>&1
echo ""
echo "===== Goat Meet: instalação ($(date)) ====="

fim() { echo ""; read -r -p "Pode fechar esta janela (aperte Enter)." _; exit "$1"; }

# 1. macOS
v="$(sw_vers -productVersion)"; major="${v%%.*}"
echo "macOS $v ($(uname -m))"
if [ "$major" -lt 13 ]; then echo "O Goat Meet precisa do macOS 13 ou mais novo."; fim 1; fi

# 2. Ferramentas da Apple para montar apps
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swiftc >/dev/null 2>&1; then
  echo ""
  echo ">> Instalando as ferramentas da Apple. Vai abrir uma janela: clique em Instalar."
  echo ">> Quando terminar, clique duas vezes neste instalador de novo."
  xcode-select --install
  fim 0
fi
echo "Ferramentas da Apple: ok"

# 3. Homebrew
BREW=""
for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && BREW="$b"; done
if [ -z "$BREW" ]; then
  echo ""
  echo ">> Instalando o Homebrew (brew.sh). Ele vai pedir a senha do seu Mac."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || fim 1
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && BREW="$b"; done
  [ -z "$BREW" ] && { echo "Homebrew não foi instalado."; fim 1; }
fi
echo "Homebrew: ok"

# 4. whisper.cpp (transcrição local)
WHISPER=""
for w in /opt/homebrew/bin/whisper-cli /usr/local/bin/whisper-cli; do [ -x "$w" ] && WHISPER="$w"; done
if [ -z "$WHISPER" ]; then
  echo ""
  echo ">> Instalando o whisper.cpp..."
  "$BREW" install whisper-cpp || fim 1
fi
echo "whisper.cpp: ok"

# 5. Modelo de transcrição (large-v3-turbo, ~1,6 GB)
mkdir -p models
M="models/ggml-large-v3-turbo.bin"
if [ ! -s "$M" ]; then
  echo ""
  echo ">> Baixando o modelo de transcrição (~1,6 GB, pode levar alguns minutos)..."
  curl -L --fail -C - -o "$M.part" "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin" || fim 1
  mv "$M.part" "$M"
fi
echo "Modelo: ok"

# 6. Montar e instalar o app
echo ""
echo ">> Montando o app..."
bash build.sh || { echo "A montagem falhou."; fim 1; }

# 7. Abrir
open "$HOME/Applications/Goat Meet.app"
echo ""
echo "===== Pronto! O Goat Meet está na barra de menu (ícone de onda sonora). ====="
fim 0
