#!/usr/bin/env node
// Servidor local para testar os dois PWAs.
// Service worker não funciona em file://, por isso precisa de HTTP.
//
//   node servidor.js            → http://localhost:8000
//   node servidor.js 9000       → outra porta
//
// Depois abra http://localhost:8000/ (DTS/PT) e http://localhost:8000/frota/
// Para testar offline: DevTools → Network → Offline, DEPOIS de carregar uma vez online.

const http = require('http');
const fs = require('fs');
const path = require('path');

// path.resolve deixa na forma nativa do SO: no Windows path.join devolve barra
// invertida, e comparar com uma raiz de barras normais reprovaria tudo
const RAIZ = path.resolve(__dirname, '..');
const PORTA = Number(process.argv[2] || 8000);

const TIPOS = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.pdf': 'application/pdf',
  '.png': 'image/png',
};

http.createServer((req, res) => {
  let rel = decodeURIComponent(req.url.split('?')[0]);
  if (rel.endsWith('/')) rel += 'index.html';
  const arq = path.join(RAIZ, rel);
  if (!arq.startsWith(RAIZ)) { res.writeHead(403).end('proibido'); return; }
  fs.readFile(arq, (err, buf) => {
    if (err) { res.writeHead(404).end('não encontrado'); return; }
    res.writeHead(200, {
      'Content-Type': TIPOS[path.extname(arq).toLowerCase()] || 'application/octet-stream',
      // sem cache do servidor: quem manda no cache aqui é o service worker
      'Cache-Control': 'no-store',
    });
    res.end(buf);
  });
}).listen(PORTA, () => {
  console.log(`servindo ${RAIZ}`);
  console.log(`  DTS/PT   http://localhost:${PORTA}/`);
  console.log(`  frota    http://localhost:${PORTA}/frota/`);
});
