#!/usr/bin/env node
// Recalcula os hashes SRI das bibliotecas de CDN.
// Use SEMPRE que trocar a versão de uma biblioteca — hash errado deixa o app em branco.
//
//   node sri.js
//
// Ele lê as URLs direto dos dois index.html, baixa cada uma e imprime a tag pronta
// para colar. Não altera nada: só imprime.

const fs = require('fs');
const path = require('path');
const https = require('https');
const crypto = require('crypto');

const RAIZ = path.resolve(__dirname, '..');
const ARQUIVOS = ['index.html', 'frota/index.html'];

function baixar(url, redirects = 0) {
  return new Promise((resolve, reject) => {
    if (redirects > 5) return reject(new Error('redirecionamentos demais'));
    https.get(url, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        const proximo = new URL(res.headers.location, url).href;
        res.resume();
        return resolve(baixar(proximo, redirects + 1));
      }
      if (res.statusCode !== 200) { res.resume(); return reject(new Error('HTTP ' + res.statusCode)); }
      const partes = [];
      res.on('data', (d) => partes.push(d));
      res.on('end', () => resolve(Buffer.concat(partes)));
    }).on('error', reject);
  });
}

(async () => {
  for (const arq of ARQUIVOS) {
    const html = fs.readFileSync(path.join(RAIZ, arq), 'utf8').replace(/<!--[\s\S]*?-->/g, '');
    const urls = [...html.matchAll(/<script[^>]+src="(https:\/\/[^"]+)"/g)].map((m) => m[1]);
    console.log(`\n=== ${arq} ===`);
    for (const url of urls) {
      try {
        const buf = await baixar(url);
        const hash = 'sha384-' + crypto.createHash('sha384').update(buf).digest('base64');
        const atual = new RegExp(`integrity="([^"]+)"[^>]*src="${url.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"`).exec(html)
          || new RegExp(`src="${url.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"[^>]*integrity="([^"]+)"`).exec(html);
        const bate = atual && atual[1] === hash;
        console.log(`${bate ? 'ok   ' : atual ? 'MUDOU' : 'novo '}  ${url}`);
        if (!bate) console.log(`         ${hash}`);
      } catch (e) {
        console.log(`ERRO   ${url} — ${e.message}`);
      }
    }
  }
  console.log('\n"MUDOU" significa que o CDN entregou conteúdo diferente do hash no arquivo.');
  console.log('Se você acabou de trocar a versão, é esperado: cole o hash novo.');
  console.log('Se você NÃO mexeu em nada, investigue antes de atualizar o hash.\n');
})();
