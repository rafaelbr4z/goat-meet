# Goat Meet: como o Claude escreve o resumo

O Goat Meet grava e transcreve as reuniões do Braz no Mac dele. O app não escreve o resumo: quem escreve é o Claude, gravando um arquivo na pasta da reunião. O app mostra esse arquivo sozinho na aba Resumo.

Este guia fica em dois lugares, com o mesmo texto: `~/Goat Meet/_app/COMO O CLAUDE FAZ O RESUMO.md` e, dentro da pasta das gravações, `_claude/COMO FAZER O RESUMO.md`.

## Onde ficam as reuniões

A pasta das gravações é escolhida pelo Braz nos ajustes do app. O caminho atual está em `~/Goat Meet/_app/config.json`, no campo `pasta`. Se o pedido já trouxer o caminho da reunião, use esse.

Cada reunião é uma subpasta com o nome da data e hora, por exemplo `2026-11-27 10h54`:

- `reuniao.json`: titulo, inicio, duracaoSeg, status (`pronta`, `transcrevendo`, `erro`), participantes, tituloAutomatico. Pode ter também `agenda` e `ondas`: não mexa neles.
- `transcricao.md`: transcrição com horário e quem falou. "Você" é o microfone do Braz. "Outros" é o som da chamada, com todas as outras pessoas juntas.
- `minuta.md`: o resumo (pode não existir ainda). O nome do arquivo é esse por motivo histórico; na conversa e no texto, diga sempre "resumo".

"A última reunião" é a pasta mais recente com status `pronta`. Se o status for `transcrevendo`, avise que ainda não terminou e não escreva nada.

## Como escrever `minuta.md`

Leia `reuniao.json` e `transcricao.md` inteiros. Grave `minuta.md` na pasta da reunião neste formato:

```
# Título curto da reunião

> Resumo em 2 a 3 frases: o que foi a reunião e o que saiu dela.

## Temas

### Nome do tema
- Ponto discutido [12:34]

## Decisões
- O que ficou decidido

## Pendências
- [ ] **Responsável** — o que fazer (prazo: dd/mm)

## Em aberto
- Dúvidas ou pontos sem definição
```

Regras:

- O bloco `>` depois do título é o resumo que aparece no cartão da reunião. Sempre inclua.
- `[mm:ss]` vira um botão que toca o áudio naquele ponto. Use os horários da transcrição nos pontos importantes.
- Organize por tema, não em ordem cronológica.
- Escreva só o que está na transcrição. Se um valor ou prazo foi deduzido pelo contexto, diga que é dedução.
- Em Pendências, cada item começa com `- [ ]`. O app deixa o Braz marcar como feito, e aí vira `- [x]`. Prazo, só quando foi dito, no fim da linha e exatamente assim: `(prazo: dd/mm)`. Sem prazo, não escreva nada.
- Em Pendências, use "Braz" para o que ele assumiu. Para os outros, use o nome se ele aparece na conversa; se não, "Cliente", "Agência" ou "Outros".
- Português do Brasil, texto direto.

## Nomes em dúvida

A transcrição erra nomes próprios (clientes, empreendimentos, pessoas).

- Se você tem certeza da grafia certa (pelo contexto, pelo título da reunião na agenda, por outras reuniões), escreva o nome certo no resumo e acrescente esse nome em `_claude/nomes.txt`, dentro da pasta das gravações, um por linha. O app usa essa lista nas próximas transcrições.
- Se você não tem certeza, escreva o nome como ouviu, entre `{?` e `}`: por exemplo `{?Kaza Arquitetura}`. O app mostra esse nome marcado com um "?" e o Braz corrige com um clique. Não use `{?...}` dentro do bloco `>`.
- Não coloque em `nomes.txt` um nome que você marcou como dúvida.

## Ajustar `reuniao.json`

- Se `tituloAutomatico` for `true`, troque `titulo` por um título curto que descreva a reunião e ponha `tituloAutomatico` em `false`. Se for `false`, não mexa no título.
- Se der para saber quem participou, preencha `participantes` (lista de nomes, começando por "Braz").
- Não altere os outros campos nem os outros arquivos da pasta. O app cuida sozinho de atualizar o evento da agenda com o título e o resumo.

## Responder no chat

Resposta curta: o resumo em 2 ou 3 frases, as pendências do Braz e a frase "O resumo completo está no Goat Meet". Não cole o resumo inteiro no chat, a não ser que ele peça.

## Outros pedidos sobre reuniões

E-mail ou mensagem de follow-up, lista de ajustes pedidos pelo cliente, comparação entre reuniões: leia os resumos e as transcrições necessárias e responda no chat.
