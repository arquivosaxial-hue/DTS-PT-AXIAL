#!/usr/bin/env node
// Verificação antes de publicar. Roda em segundos e pega os erros que o app
// só revelaria em campo, com a equipe na rua.
//
//   cd ferramentas && npm install     (uma vez só)
//   npm run construir                 (compila src/index.html -> index.html)
//   npm run verificar
//
// Sai com código 1 se achar problema — dá para usar em CI depois.

const fs = require('fs');
const path = require('path');

const RAIZ = path.resolve(__dirname, '..');
const FONTE = path.join(RAIZ, 'src', 'index.html');   // com JSX, é o que se edita
const PUBLI = path.join(RAIZ, 'index.html');          // gerado, é o que se sobe
const SW = path.join(RAIZ, 'sw.js');

let erros = 0;
const falhar = (msg) => { erros++; console.log('  ERRO  ' + msg); };
const ok = (msg) => console.log('  ok    ' + msg);

function extrairJSX(caminho) {
  const html = fs.readFileSync(caminho, 'utf8');
  const abre = /<script\s+type="text\/babel"[^>]*>/i.exec(html);
  if (!abre) return null;
  const ini = abre.index + abre[0].length;
  const fim = html.indexOf('</script>', ini);
  const offset = html.slice(0, ini).split('\n').length - 1;
  return { html, codigo: '\n'.repeat(offset) + html.slice(ini, fim) };
}

// ---------------------------------------------------------------- 1. sintaxe
console.log('\n1. O JSX do fonte compila?');
const babel = require('@babel/core');
const presetReact = require.resolve('@babel/preset-react');
const fonte = extrairJSX(FONTE);
if (!fonte) {
  falhar('src/index.html não tem bloco <script type="text/babel">');
} else {
  try {
    babel.transformSync(fonte.codigo, {
      filename: FONTE, presets: [[presetReact, { runtime: 'classic' }]],
      babelrc: false, configFile: false,
    });
    ok('src/index.html: compila');
  } catch (e) {
    falhar('src/index.html: ' + String(e.message).split('\n')[0]);
  }
}

// ------------------------------------------- 2. identificadores nunca definidos
// Rede de segurança para refactor: função removida ou renomeada com chamada
// antiga sobrando. O Babel não pega — sintaticamente está certo, só quebra em runtime.
console.log('\n2. Sobrou alguma função removida sendo chamada?');
const parser = require('@babel/parser');
const traverse = require('@babel/traverse').default;
const GLOBAIS = new Set([
  'window','document','navigator','location','history','console','indexedDB','caches','fetch',
  'setTimeout','clearTimeout','setInterval','clearInterval','requestAnimationFrame','alert','confirm','prompt',
  'Promise','Blob','File','FileReader','URL','URLSearchParams','FormData','CustomEvent','Event','Image','Audio',
  'Object','Array','String','Number','Boolean','Math','JSON','Date','RegExp','Error','Map','Set','WeakMap','WeakSet',
  'Intl','isNaN','parseInt','parseFloat','encodeURIComponent','decodeURIComponent','structuredClone','btoa','atob',
  'Uint8Array','ArrayBuffer','TextEncoder','TextDecoder','AbortController','crypto','self','globalThis','performance',
  'localStorage','sessionStorage','screen','matchMedia','getComputedStyle','DOMParser','Node','HTMLElement','Symbol',
  'React','ReactDOM','supabase','PDFLib','QRCode','jspdf','jsPDF','process','require','module','exports',
  'undefined','Infinity','NaN','isFinite','escape','unescape',
]);
if (fonte) {
  const ast = parser.parse(fonte.codigo, {
    sourceType: 'script',
    plugins: ['jsx','optionalChaining','nullishCoalescingOperator','objectRestSpread'],
  });
  const achados = new Map();
  traverse(ast, {
    ReferencedIdentifier(p) {
      const n = p.node.name;
      if (GLOBAIS.has(n) || p.scope.hasBinding(n, true)) return;
      if (p.parent.type === 'JSXOpeningElement' && /^[a-z]/.test(n)) return;
      if (!achados.has(n)) achados.set(n, p.node.loc.start.line);
    },
  });
  if (achados.size === 0) ok('nenhum identificador solto');
  else for (const [id, linha] of achados) falhar(`'${id}' usado na linha ${linha} e nunca definido`);
}

// ----------------------------------------------- 3. o build está em dia?
// O arquivo publicado é GERADO. Se alguém editou o fonte e esqueceu de construir,
// o que vai para o ar é a versão anterior — e nada avisa.
console.log('\n3. O index.html publicado está em dia com o fonte?');
if (!fs.existsSync(PUBLI)) {
  falhar('index.html não existe — rode: npm run construir');
} else {
  const tFonte = fs.statSync(FONTE).mtimeMs;
  const tPubli = fs.statSync(PUBLI).mtimeMs;
  const htmlPubli = fs.readFileSync(PUBLI, 'utf8');

  if (tFonte > tPubli + 1000) {
    falhar('src/index.html é mais novo que index.html — rode: npm run construir');
  } else if (/<script\s+type="text\/babel"/i.test(htmlPubli)) {
    falhar('index.html ainda tem JSX cru — o fonte foi copiado no lugar do gerado');
  } else if (/standalone/i.test(htmlPubli)) {
    falhar('index.html ainda carrega o Babel — rode: npm run construir');
  } else {
    ok('build em dia, sem JSX cru e sem Babel');
  }
}

// ------------------------------------------------ 4. casco offline e versão
// O sw.js e o index.html precisam falar das MESMAS URLs de CDN. E APP_VERSION
// tem que subir junto com o CACHE, senão o aparelho em campo continua servindo
// código antigo sem sintoma nenhum.
console.log('\n4. Service worker bate com o index.html?');
if (fs.existsSync(PUBLI)) {
  const html = fs.readFileSync(PUBLI, 'utf8');
  const sw = fs.readFileSync(SW, 'utf8');

  const noHtml = new Set([...html.replace(/<!--[\s\S]*?-->/g, '')
    .matchAll(/<script[^>]+src="(https:\/\/[^"]+)"/g)].map(m => m[1]));
  const noSw = new Set([...sw.replace(/^\s*\/\/.*$/gm, '')
    .matchAll(/'(https:\/\/[^']+)'/g)].map(m => m[1]));

  [...noSw].filter(u => !noHtml.has(u))
    .forEach(u => falhar(`sw.js pré-cacheia URL que o index.html não usa — ${u}`));
  if (noSw.size) {
    [...noHtml].filter(u => !noSw.has(u))
      .forEach(u => falhar(`index.html usa URL fora do APP_SHELL — ${u}`));
  }

  const v = (html.match(/APP_VERSION\s*=\s*['"]V(\d+)['"]/) || [])[1];
  const c = (sw.match(/(?:CACHE|VERSION)\s*=\s*['"][a-z-]*v(\d+)['"]/) || [])[1];
  const vFonte = (fs.readFileSync(FONTE, 'utf8').match(/APP_VERSION\s*=\s*['"]V(\d+)['"]/) || [])[1];
  if (!v || !c) falhar(`não consegui ler APP_VERSION (${v}) ou CACHE (${c})`);
  else if (v !== c) falhar(`APP_VERSION=V${v} mas CACHE=v${c} — precisam subir juntos`);
  else if (vFonte && vFonte !== v) falhar(`o fonte está em V${vFonte} e o publicado em V${v} — reconstrua`);
  else ok(`V${v}, ${noSw.size || 'CDN em runtime'} URLs conferidas`);
}

// ---------------------------------------------------------- 5. SRI presente
console.log('\n5. As bibliotecas têm verificação de integridade (SRI)?');
if (fs.existsSync(PUBLI)) {
  const html = fs.readFileSync(PUBLI, 'utf8').replace(/<!--[\s\S]*?-->/g, '');
  const tags = [...html.matchAll(/<script[^>]+src="https:\/\/[^"]+"[^>]*>/g)].map(m => m[0]);
  const semSRI = tags.filter(t => !/integrity=/.test(t));
  if (semSRI.length) falhar(`${semSRI.length} de ${tags.length} script(s) de CDN sem integrity=`);
  else ok(`${tags.length}/${tags.length} com SRI`);
}

// ------------------------------------------- 6. modelos oficiais de PDF
console.log('\n6. Os modelos de PDF continuam os mesmos da calibração?');
const { execFileSync } = require('child_process');
try {
  process.stdout.write(execFileSync(process.execPath, [path.join(__dirname, 'modelos.js')], { encoding: 'utf8' }));
} catch (e) {
  erros++;
  process.stdout.write((e.stdout || '') + (e.stderr || ''));
}

console.log(erros ? `\n${erros} problema(s). NÃO publique.\n` : '\nTudo certo. Pode publicar.\n');
process.exit(erros ? 1 : 0);
