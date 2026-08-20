#!/usr/bin/env node
// Impressão digital dos modelos oficiais de PDF.
//
// As coordenadas de escrita no PDF (LIMITES_CAB, LIMITES_DTS e os offsets espalhados
// pelas funções de geração) foram calibradas À MÃO contra CADA modelo. Se a Iguá revisar
// um formulário e alguém trocar o arquivo, o texto passa a sair fora do lugar — e isso só
// aparece no PDF impresso, já em campo.
//
// Este script guarda o hash de cada modelo. O verificar.js compara e acusa a troca,
// obrigando uma recalibração consciente em vez de uma surpresa na obra.
//
//   node modelos.js            → confere contra o registro
//   node modelos.js --gravar   → grava o registro atual (use ao trocar um modelo DE PROPÓSITO)

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const RAIZ = path.resolve(__dirname, '..');
const REGISTRO = path.join(__dirname, 'modelos.json');

function hashDe(arquivo) {
  return crypto.createHash('sha256').update(fs.readFileSync(arquivo)).digest('hex').slice(0, 16);
}

function modelosNoDisco() {
  return fs.readdirSync(RAIZ)
    .filter((f) => /^modelo_.*\.pdf$/i.test(f))
    .sort()
    .map((f) => ({ arquivo: f, hash: hashDe(path.join(RAIZ, f)), bytes: fs.statSync(path.join(RAIZ, f)).size }));
}

// Modelos citados no código — pega o que o app realmente tenta carregar
function modelosCitados() {
  const html = fs.readFileSync(path.join(RAIZ, 'index.html'), 'utf8');
  return [...new Set([...html.matchAll(/["'](modelo_[a-z_]+\.pdf)["']/g)].map((m) => m[1]))].sort();
}

const atual = modelosNoDisco();

if (process.argv.includes('--gravar')) {
  fs.writeFileSync(REGISTRO, JSON.stringify(atual, null, 2) + '\n');
  console.log(`registro gravado com ${atual.length} modelo(s) em modelos.json`);
  process.exit(0);
}

let erros = 0;

// 1. todo modelo citado no código existe no disco?
const noDisco = new Set(atual.map((m) => m.arquivo));
for (const citado of modelosCitados()) {
  if (!noDisco.has(citado)) { erros++; console.log(`  ERRO  ${citado} é carregado pelo código e não existe na pasta`); }
}

// 2. algum modelo mudou desde a última calibração?
if (!fs.existsSync(REGISTRO)) {
  console.log('  aviso registro ainda não existe — rode: node modelos.js --gravar');
} else {
  const antes = JSON.parse(fs.readFileSync(REGISTRO, 'utf8'));
  const mapaAntes = new Map(antes.map((m) => [m.arquivo, m]));
  for (const m of atual) {
    const a = mapaAntes.get(m.arquivo);
    if (!a) { console.log(`  aviso ${m.arquivo} é novo (ainda não registrado)`); continue; }
    if (a.hash !== m.hash) {
      erros++;
      console.log(`  ERRO  ${m.arquivo} MUDOU (${a.bytes} → ${m.bytes} bytes)`);
      console.log('        As coordenadas de escrita foram calibradas contra o arquivo antigo.');
      console.log('        Confira o PDF gerado antes de publicar e depois rode: node modelos.js --gravar');
    }
  }
  for (const a of antes) {
    if (!noDisco.has(a.arquivo)) { erros++; console.log(`  ERRO  ${a.arquivo} sumiu da pasta`); }
  }
}

if (!erros) console.log(`  ok    ${atual.length} modelo(s) conferem com a calibração`);
process.exit(erros ? 1 : 0);
