#!/bin/bash
# Só confere se o código monta. Não instala nada.
cd "$(dirname "$0")" || exit 1
bash build.sh --verificar > verificar.log 2>&1
echo "codigo: $?" >> verificar.log
