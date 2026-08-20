#!/usr/bin/env node
// Compila o JSX de src/index.html e escreve o index.html publicável na raiz.
//
//   npm run construir
//
// POR QUE ISSO EXISTE
// Antes, o app publicado era o próprio código-fonte: o navegador baixava o Babel
// (2,8 MB) e compilava o JSX a cada abertura fria. Em celular de obra isso é
// espera pura, toda vez. Compilando aqui, o aparelho recebe JavaScript pronto.
//
// De quebra some uma dependência de CDN e o CSP pode dispensar 'unsafe-eval',
// que só existia porque o Babel precisa dele para compilar em runtime.
//
// O QUE VOCÊ EDITA
//   src/index.html   <- aqui, com JSX
//   index.html       <- gerado; qualquer alteração some no próximo build

const fs = require('fs');
const path = require('path');
const babel = require('@babel/core');

const RAIZ = path.resolve(__dirname, '..');
const FONTE = path.join(RAIZ, 'src', 'index.html');
const SAIDA = path.join(RAIZ, 'index.html');

if (!fs.existsSync(FONTE)) {
  console.error('ERRO: não achei src/index.html — é ele que deve ser editado.');
  process.exit(1);
}

const html = fs.readFileSync(FONTE, 'utf8');

// 1. extrai o bloco JSX
const abre = /<script\s+type="text\/babel"[^>]*>/i.exec(html);
if (!abre) { console.error('ERRO: src/index.html não tem bloco <script type="text/babel">.'); process.exit(1); }
const ini = abre.index + abre[0].length;
const fim = html.indexOf('</script>', ini);
const jsx = html.slice(ini, fim);

// 2. compila
let compilado;
try {
  compilado = babel.transformSync(jsx, {
    filename: 'app.jsx',
    presets: [[require.resolve('@babel/preset-react'), { runtime: 'classic' }]],
    babelrc: false, configFile: false, compact: false, comments: true,
  }).code;
} catch (e) {
  console.error('ERRO ao compilar o JSX:\n' + e.message);
  process.exit(1);
}

// 3. monta o HTML de saída
let saida = html.slice(0, abre.index) + '<script>\n' + compilado + '\n  </script>' + html.slice(fim + '</script>'.length);

// remove a tag do Babel — não é mais necessária no app publicado
const antesBabel = saida;
saida = saida.replace(/\n\s*<script[^>]*standalone[^>]*><\/script>/i, '');
if (saida === antesBabel) console.warn('  aviso: não achei a tag do Babel para remover');

// o CSP pode ficar mais apertado sem o compilador em runtime
saida = saida.replace(/ 'unsafe-eval'/g, '');

// aviso no topo, para ninguém editar o arquivo errado
saida = saida.replace(/^<!DOCTYPE html>/i,
`<!DOCTYPE html>
<!-- ==========================================================================
     ARQUIVO GERADO — NÃO EDITE.
     Edite src/index.html e rode:  cd ferramentas && npm run construir
     Qualquer alteração feita aqui some no próximo build.
     ========================================================================== -->`);

fs.writeFileSync(SAIDA, saida);

const kb = (n) => (n / 1024).toFixed(0) + ' KB';
console.log('  fonte    src/index.html   ' + kb(Buffer.byteLength(html)));
console.log('  gerado   index.html       ' + kb(Buffer.byteLength(saida)));
console.log('  JSX compilado: ' + jsx.split('\n').length + ' linhas');
console.log('  Babel removido do app publicado; CSP sem unsafe-eval');
