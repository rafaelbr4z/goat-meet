# Goat Meet

Gravador de reuniões para Mac. Grava o som da chamada e o seu microfone, transcreve tudo no próprio computador e guarda cada reunião em um cartão. O resumo é escrito pelo Claude a partir da transcrição. Sem assinatura e sem robô entrando na chamada.

## Instalar

1. Baixe o **GoatMeet.dmg** da [última versão](../../releases/latest).
2. Abra o arquivo e arraste o Goat Meet para a pasta Aplicativos.
3. Abra o Goat Meet. Na primeira vez o Mac avisa que não conseguiu verificar o app: vá em Ajustes do Sistema > Privacidade e Segurança e clique em "Abrir Mesmo Assim". É uma vez só.
4. Siga a tela de preparação: seu nome, as permissões (microfone e gravação de tela e áudio), a pasta das gravações e o download do modelo de transcrição (1,6 GB).

Precisa de um Mac com chip Apple (M1 ou mais novo) e macOS 13 ou mais novo.

Depois de instalado, o app se atualiza sozinho quando sai versão nova.

## O que ele faz

- Grava a chamada e o microfone em faixas separadas e transcreve no próprio Mac (whisper.cpp). O áudio não sai do computador.
- Registra cada gravação na agenda, com a hora real de início e de fim, e avisa antes das reuniões marcadas.
- Mostra cada reunião em um cartão com um micro resumo. Botão direito, Shift + clique para marcar várias e tecla de apagar.
- Agrupa reuniões em projetos, com uma ficha (cliente, construtora, local, entrega, valor, pagamento, prazo) e as tarefas abertas de todas as reuniões juntas.
- O resumo segue sempre a mesma ordem (tarefas, decisões, conceito, o que foi falado, em aberto) e pode ser editado na tela.

## O resumo e o Claude

O app não escreve o resumo. O botão "Enviar pro Claude" abre o Claude com o pedido pronto, e o Claude grava o resumo na pasta da reunião seguindo o guia em `_app/COMO O CLAUDE FAZ O RESUMO.md`. Para isso, o Claude precisa ter acesso à pasta das gravações no seu Mac.

## O que tem neste repositório

- `_app/Sources/`: o app (Swift, AppKit). Gravação com ScreenCaptureKit e AVAudioEngine, agenda com EventKit, primeira abertura e atualização automática.
- `_app/ui/`: a tela do app (uma página HTML) e os tokens do design system.
- `_app/build.sh`: monta o app.
- `.github/workflows/montar.yml`: a cada mudança, o GitHub monta o app, embute o programa de transcrição, assina, gera o instalador e publica a versão nova.

Gravações, transcrições e resumos nunca entram aqui: ficam só no computador de quem usa.

## Montar no próprio Mac

Para quem quer mexer no código: `bash _app/build.sh` monta e instala em `~/Applications`. Nesse caso o app usa o `whisper-cli` do Homebrew (`brew install whisper-cpp`) e não se atualiza sozinho.
