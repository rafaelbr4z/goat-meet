#!/bin/bash
# Teste automático: cria uma gravação de mentira (duas vozes do próprio Mac) e deixa o app processar.
cd "$(dirname "$0")" || exit 1
exec > teste.log 2>&1
if [ -n "$(find tmp -name '*.caf' -mmin -2 2>/dev/null | head -1)" ]; then echo "GRAVACAO_EM_ANDAMENTO"; exit 3; fi
D="tmp/TESTE-$(date +%s)"; mkdir -p "$D"
say -v Luciana -o "$D/a.aiff" "[[slnc 11000]] Perfeito. A cor eu ajusto no grade até amanhã. A trilha nova muda o corte dos primeiros vinte segundos, então entrego a versão completa na quinta-feira. [[slnc 9000]] Combinado."
say -v "Reed (Portuguese (Brazil))" -o "$D/b.aiff" "Bom dia, vamos começar. O cliente achou a cor da fachada muito fria e pediu para trocar a trilha do começo do filme. [[slnc 13000]] Fechado. A gente manda duas opções de trilha até terça de manhã." \
  || say -v Luciana -r 150 -o "$D/b.aiff" "Bom dia, vamos começar. O cliente achou a cor da fachada muito fria e pediu para trocar a trilha do começo do filme. [[slnc 13000]] Fechado. A gente manda duas opções de trilha até terça de manhã."
afconvert -f caff -d LEF32@48000 -c 1 "$D/a.aiff" "$D/microfone.caf"
afconvert -f caff -d LEF32@48000 -c 1 "$D/b.aiff" "$D/sistema.caf"
rm -f "$D"/*.aiff
printf '%s' "$(date '+%Y-%m-%d %Hh%M') - Teste do Goat Meet (pode apagar)" > "$D/nome.txt"
ls -la "$D"
pkill -x GoatMeet; sleep 1
open "$HOME/Applications/Goat Meet.app"
echo "TESTE_CRIADO"
