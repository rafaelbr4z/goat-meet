#!/bin/bash
# Monta o Goat Meet, instala em ~/Applications e abre o app. Só roda uma cópia por vez.
cd "$(dirname "$0")" || exit 1
LOCK="$PWD/.atualizando"
find "$LOCK" -maxdepth 0 -mmin +5 -exec rmdir {} \; 2>/dev/null
if ! mkdir "$LOCK" 2>/dev/null; then exit 0; fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
bash build.sh > install.log 2>&1
codigo=$?
echo "codigo: $codigo" >> install.log
if [ "$codigo" = "0" ]; then open "$HOME/Applications/Goat Meet.app"; fi
