#!/bin/bash
# Diagnóstico: testa a transcrição com uma fala gerada pelo próprio Mac. Não grava nada do usuário.
cd "$(dirname "$0")" || exit 1
exec > diag.log 2>&1
echo "== sistema"; sw_vers; uname -m; swiftc --version
echo "== whisper"; ls -la /opt/homebrew/bin | grep -i -E "whisper|llama"
W=/opt/homebrew/bin/whisper-cli
"$W" --help
rm -rf diag; mkdir -p diag; cd diag || exit 1
echo "== vozes pt"; say -v '?' | grep -i -E "pt_BR|pt-BR"
VOZ="$(say -v '?' | grep -i 'pt_BR' | head -1 | awk '{print $1}')"
echo "voz: $VOZ"
say -v "${VOZ:-Luciana}" -o a.aiff "Bom dia pessoal. Vamos começar a reunião sobre o filme do Petra Residence. O prazo de entrega é sexta-feira. [[slnc 25000]] Depois do silêncio, a segunda parte: o cliente pediu para trocar a trilha e ajustar a cor da fachada."
echo "== afconvert"; which afconvert
afconvert -f WAVE -d LEI16@16000 -c 1 a.aiff a.wav; ls -la
echo "== transcrevendo"
time "$W" -m ../models/ggml-large-v3-turbo.bin -f a.wav -l pt -t 8 -oj -of a
echo "== json"; cat a.json
echo "== m4a"; afconvert -f m4af -d aac -b 32000 a.wav a.m4a; ls -la
echo "== assinatura"; security find-identity -p codesigning
echo "== fontes"; ls ~/Library/Fonts 2>/dev/null | grep -i -E "nohemi" ; fc-list 2>/dev/null | grep -i nohemi | head -3
echo "== fim"
