# Ferramentas

Scripts de apoio para quem dá manutenção. **Nada aqui vai para o ar** — o app
publicado continua sendo só arquivo estático, sem build e sem dependência.

## Instalação (uma vez só)

Precisa do [Node.js](https://nodejs.org). Depois, dentro desta pasta:

```bash
npm install
```

Isso cria `node_modules/`, que **não deve ser enviado ao GitHub** (já está no
`.gitignore` daqui).

---

## Antes de publicar: `npm run verificar`

```bash
npm run verificar
```

Roda em segundos e faz quatro checagens:

1. **O JSX compila?** Como o Babel roda no navegador, um erro de sintaxe só
   aparece quando o operador abre o app — em campo. Aqui aparece antes.
2. **Sobrou função removida sendo chamada?** Depois de refatorar, uma chamada
   antiga não quebra a compilação, só o runtime. Este passo acha.
3. **O `sw.js` bate com o `index.html`?** As URLs de CDN precisam ser as mesmas
   nos dois. Se divergirem, o pré-cache guarda um arquivo que o app não usa e o
   app passa a depender de estar online. Confere também se `APP_VERSION` e
   `CACHE` subiram juntos — esquecer isso deixa aparelho em campo com código
   velho, sem sintoma nenhum.
4. **As bibliotecas têm SRI?** Sem `integrity=`, um CDN comprometido executa o
   que quiser dentro do app.

5. **Os modelos de PDF continuam os mesmos?** As coordenadas de escrita foram
   calibradas à mão contra cada `modelo_*.pdf`. Se a Iguá revisar um formulário e
   alguém trocar o arquivo, o texto passa a sair fora do lugar — e isso só aparece
   no PDF impresso, já em campo.

Se sair `NÃO publique`, corrija antes. O script devolve código de saída 1, então
dá para ligar em CI depois.

### Quando um modelo de PDF mudar de propósito

Trocou um `modelo_*.pdf`? O verificar vai acusar. Isso é o esperado: **recalibre as
coordenadas, confira o PDF gerado** e só então registre a nova versão:

```bash
npm run modelos:gravar
```

Nunca rode `modelos:gravar` só para calar o aviso sem conferir o PDF impresso.

---

## Testar de verdade: `npm run servidor`

```bash
npm run servidor
```

Abre em `http://localhost:8000/` (DTS/PT) e `http://localhost:8000/frota/`.
Service worker não funciona em `file://`, por isso precisa deste servidor.

**Para testar offline** — que é o cenário real de uso, não caso de borda:
carregue uma vez online, depois DevTools → Network → **Offline**.

O roteiro mínimo:

| | O que fazer | O que tem que acontecer |
|---|---|---|
| 1 | Offline, preencher uma PT | avisa que será enviada ao reconectar |
| 2 | Voltar ao início | aviso amarelo com o número de pendentes |
| 3 | Fechar o app, religar a rede, reabrir | sobe sozinho, sem abrir formulário |
| 4 | Offline, frota → Validador → validar | **recusa** com aviso; nunca diz "validado" |
| 5 | Preencher meia DTS, fechar, reabrir | oferece restaurar o rascunho |

---

## Ao trocar a versão de uma biblioteca: `npm run sri`

```bash
npm run sri
```

Lê as URLs dos dois `index.html`, baixa cada uma e compara com o `integrity=`
que está no arquivo.

- `ok` — o hash confere
- `MUDOU` — o CDN entregou conteúdo diferente do hash gravado
- `novo` — a tag ainda não tem `integrity=`

Se você **acabou de trocar a versão**, `MUDOU` é esperado: cole o hash novo.
Se você **não mexeu em nada** e apareceu `MUDOU`, investigue antes de atualizar —
pode ser o CDN servindo outra coisa.

> Hash errado faz o navegador recusar o script e o app abre **em branco**. É a
> única mudança deste projeto que falha de forma total, então teste no servidor
> local antes de publicar.
