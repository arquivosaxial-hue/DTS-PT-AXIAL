#!/usr/bin/env node
// Verificação antes de publicar. Roda em segundos e pega os erros que o app
// só revelaria em campo, com a equipe na rua.
//
//   cd ferramentas && npm install     (uma vez só)
//   node verificar.js
//
// Sai com código 1 se achar problema — dá para usar em CI depois.

const fs = require('fs');
const path = require('path');

const RAIZ = path.resolve(__dirname, '..');
const APPS = [
  { nome: 'documentos', html: 'index.html', sw: 'sw.js' },
];

let erros = 0;
const falhar = (msg) => { erros++; console.log('  ERRO  ' + msg); };
const ok = (msg) => console.log('  ok    ' + msg);

// Extrai o bloco <script type="text/babel">, preservando o número de linha do HTML
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
console.log('\n1. O JSX compila?');
const babel = require('@babel/core');
const presetReact = require.resolve('@babel/preset-react');
for (const app of APPS) {
  const alvo = path.join(RAIZ, app.html);
  try {
    const { codigo } = extrairJSX(alvo);
    babel.transformSync(codigo, {
      filename: alvo, presets: [[presetReact, { runtime: 'classic' }]],
      babelrc: false, configFile: false,
    });
    ok(`${app.nome}: compila`);
  } catch (e) {
    falhar(`${app.nome}: ${String(e.message).split('\n')[0]}`);
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
for (const app of APPS) {
  const { codigo } = extrairJSX(path.join(RAIZ, app.html));
  const ast = parser.parse(codigo, {
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
  if (achados.size === 0) ok(`${app.nome}: nenhum identificador solto`);
  else for (const [id, linha] of achados) falhar(`${app.nome}: '${id}' usado na linha ${linha} e nunca definido`);
}

// ------------------------------------------------ 3. casco offline e versão
// O sw.js e o index.html precisam falar das MESMAS URLs de CDN. Se divergirem,
// o pré-cache guarda um arquivo que o app não usa e o app passa a depender de
// uma carga online. E APP_VERSION tem que subir junto com o CACHE, senão o
// aparelho em campo continua servindo código antigo sem sintoma nenhum.
console.log('\n3. Service worker bate com o index.html?');
for (const app of APPS) {
  const html = fs.readFileSync(path.join(RAIZ, app.html), 'utf8');
  const sw = fs.readFileSync(path.join(RAIZ, app.sw), 'utf8');

  const noHtml = new Set([...html.replace(/<!--[\s\S]*?-->/g, '')
    .matchAll(/<script[^>]+src="(https:\/\/[^"]+)"/g)].map(m => m[1]));
  const noSw = new Set([...sw.replace(/^\s*\/\/.*$/gm, '')
    .matchAll(/'(https:\/\/[^']+)'/g)].map(m => m[1]));

  [...noSw].filter(u => !noHtml.has(u))
    .forEach(u => falhar(`${app.nome}: sw.js pré-cacheia URL que o index.html não usa — ${u}`));
  if (noSw.size) {
    [...noHtml].filter(u => !noSw.has(u))
      .forEach(u => falhar(`${app.nome}: index.html usa URL fora do APP_SHELL — ${u}`));
  }

  const v = (html.match(/APP_VERSION\s*=\s*['"]V(\d+)['"]/) || [])[1];
  const c = (sw.match(/(?:CACHE|VERSION)\s*=\s*['"][a-z-]*v(\d+)['"]/) || [])[1];
  if (!v || !c) falhar(`${app.nome}: não consegui ler APP_VERSION (${v}) ou CACHE (${c})`);
  else if (v !== c) falhar(`${app.nome}: APP_VERSION=V${v} mas CACHE=v${c} — precisam subir juntos`);
  else ok(`${app.nome}: V${v}, ${noSw.size || 'CDN em runtime'} URLs conferidas`);
}

// ---------------------------------------------------------- 4. SRI presente
console.log('\n4. As bibliotecas têm verificação de integridade (SRI)?');
for (const app of APPS) {
  const html = fs.readFileSync(path.join(RAIZ, app.html), 'utf8')
    .replace(/<!--[\s\S]*?-->/g, '');
  const tags = [...html.matchAll(/<script[^>]+src="https:\/\/[^"]+"[^>]*>/g)].map(m => m[0]);
  const semSRI = tags.filter(t => !/integrity=/.test(t));
  if (semSRI.length) falhar(`${app.nome}: ${semSRI.length} de ${tags.length} script(s) de CDN sem integrity=`);
  else ok(`${app.nome}: ${tags.length}/${tags.length} com SRI`);
}

// ------------------------------------------- 5. modelos oficiais de PDF
// As coordenadas de escrita foram calibradas à mão contra cada modelo. Se o arquivo
// mudar, o texto sai fora do lugar — e isso só aparece no PDF impresso, em campo.
console.log('\n5. Os modelos de PDF continuam os mesmos da calibração?');
const { execFileSync } = require('child_process');
try {
  const saida = execFileSync(process.execPath, [path.join(__dirname, 'modelos.js')], { encoding: 'utf8' });
  process.stdout.write(saida);
} catch (e) {
  erros++;
  process.stdout.write(e.stdout || '');
  process.stdout.write(e.stderr || '');
}

console.log(erros ? `\n${erros} problema(s). NÃO publique.\n` : '\nTudo certo. Pode publicar.\n');
process.exit(erros ? 1 : 0);
