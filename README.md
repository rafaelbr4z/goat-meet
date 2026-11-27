# Goat Meet

Gravador de reuniões para macOS, feito para uso próprio. Grava o som do computador e o microfone, transcreve tudo no próprio Mac e guarda cada reunião em uma pasta. Os resumos são escritos pelo Claude a partir da transcrição. Sem assinatura e sem robô entrando na chamada.

## O que tem aqui

- `Instalar Goat Meet.command`: instalador. Confere o macOS, instala as ferramentas da Apple, o Homebrew, o whisper.cpp, baixa o modelo de transcrição e monta o app.
- `_app/Sources/`: o app (Swift, AppKit). Gravação com ScreenCaptureKit e AVAudioEngine, agenda com EventKit, avisos de reunião e a ponte com a tela.
- `_app/ui/`: a tela do app (HTML, CSS e JavaScript em uma página), com os tokens do design system em `tokens.css`.
- `_app/build.sh`: monta o app e instala em `~/Applications`.
- `_app/atualizar.command`: monta, instala e abre o app.
- `_app/verificar.command`: só confere se o código monta.
- `_app/diag.command` e `_app/teste.command`: diagnóstico e gravação de teste com vozes do próprio Mac.
- `_app/COMO O CLAUDE FAZ O RESUMO.md`: o guia que o Claude segue para escrever o resumo.
- `_app/config.exemplo.json`: modelo do arquivo de ajustes. O app cria o `config.json` sozinho.

## O que não entra no repositório

Gravações, transcrições, resumos, o `config.json`, a lista de nomes aprendidos, os registros e o modelo de transcrição (1,6 GB, baixado pelo instalador). Veja o `.gitignore`.

## Instalar em um Mac

1. macOS 13 ou mais novo.
2. Coloque esta pasta em `~/Goat Meet` (o app procura o código em `~/Goat Meet/_app`).
3. Clique duas vezes em `Instalar Goat Meet.command`.
4. Na primeira gravação, libere o microfone e a gravação de tela e áudio do sistema nos Ajustes do macOS.

## Limites conhecidos

- O app é assinado só para o Mac onde foi montado. A cada nova montagem o macOS pede as permissões de novo.
- Ainda não existe um instalador pronto para distribuir a outras pessoas.
- A fonte dos títulos é a Nohemi. Sem ela instalada, o app usa a fonte do sistema.
