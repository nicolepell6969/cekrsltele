const fs = require('fs');
const file = 'checkMetroStatus.js';
let src = fs.readFileSync(file, 'utf8');

const START_RE = /async\s+function\s+fetchTable\s*\([^)]*\)\s*{/m;

// cari awal fungsi
const m = START_RE.exec(src);
if (!m) {
  console.error('❌ Tidak menemukan deklarasi async function fetchTable(...) {');
  process.exit(1);
}
const startIdx = m.index;
const bodyStart = m.index + m[0].length - 1; // posisi '{' pembuka

// scan untuk menemukan '}' penutup yang seimbang
let i = bodyStart;
let depth = 0;
let inS = false, inD = false, inBq = false, inLine = false, inBlock = false;
for (; i < src.length; i++) {
  const c = src[i], n = src[i+1];

  // komentar
  if (!inS && !inD && !inBq) {
    if (!inBlock && !inLine && c === '/' && n === '*') { inBlock = true; i++; continue; }
    if (inBlock && c === '*' && n === '/') { inBlock = false; i++; continue; }
    if (!inBlock && !inLine && c === '/' && n === '/') { inLine = true; i++; continue; }
    if (inLine && (c === '\n' || c === '\r')) { inLine = false; }
    if (inBlock || inLine) continue;
  }
  // string literal
  if (!inBlock && !inLine) {
    if (!inD && !inBq && c === '\'' && src[i-1] !== '\\') { inS = !inS; continue; }
    if (!inS && !inBq && c === '"'  && src[i-1] !== '\\') { inD = !inD; continue; }
    if (!inS && !inD && c === '`'   && src[i-1] !== '\\') { inBq = !inBq; continue; }
  }
  if (inS || inD || inBq || inBlock || inLine) continue;

  if (c === '{') depth++;
  if (c === '}') {
    if (depth === 0) { // menutup '{' pembuka fungsi
      i++; break;
    }
    depth--;
  }
}
if (i >= src.length) {
  console.error('❌ Gagal menemukan akhir fungsi fetchTable (brace tidak seimbang).');
  process.exit(1);
}

// potong bagian fungsi lama
const before = src.slice(0, startIdx);
const after  = src.slice(i);

// fungsi baru
const replacement = `
async function fetchTable(page, neName, serviceType) {
  await page.goto(BASE_URL, { waitUntil: 'domcontentloaded', timeout: 60_000 });
  await page.waitForSelector('#neName', { timeout: 30_000 });
  await page.$eval('#neName', (el, v) => { el.value = v; }, neName);
  await page.$eval('#service', (el, v) => { el.value = v; }, serviceType);
  await page.click('#btnCheck');
  await page.waitForTimeout(800);

  // Ambil hanya tabel "Metro‑e Status Check" (header lengkap)
  const rows = await page.evaluate(() => {
    const MUST = ['NE IP','NE Name','Interface','IF Speed','Description','RX Level','RX Threshold','Oper Status']
      .map(s => s.toLowerCase());

    const headersOf = (table) =>
      Array.from(table.querySelectorAll('tr:first-child th, tr:first-child td'))
        .map(h => (h.textContent || '').trim().toLowerCase());

    const hasAll = (hs) => {
      const set = new Set(hs);
      return MUST.every(m => Array.from(set).some(x => x.includes(m)));
    };

    const allTables = Array.from(document.querySelectorAll('table'));
    const strict = allTables.filter(t => hasAll(headersOf(t)));

    let table = strict[0] || null;
    if (!table) {
      // fallback: pilih tabel dengan skor header terbanyak
      let best = { score: -1, table: null };
      for (const t of allTables) {
        const hs = headersOf(t);
        const score = MUST.reduce((acc, w) => acc + (hs.some(h => h.includes(w)) ? 1 : 0), 0);
        if (score > best.score) best = { score, table: t };
      }
      table = best.table;
    }
    if (!table) return [];

    // Pemetaan kolom
    const headerCells = Array.from(table.querySelectorAll('tr:first-child th, tr:first-child td'));
    const colIndex = {};
    headerCells.forEach((cell, i) => {
      const txt = (cell.textContent || '').trim().toLowerCase();
      if (txt.includes('ne ip'))        colIndex['NE IP']        = i;
      if (txt.includes('ne name'))      colIndex['NE Name']      = i;
      if (txt.includes('interface'))    colIndex['Interface']    = i;
      if (txt.includes('if speed'))     colIndex['IF Speed']     = i;
      if (txt.includes('description'))  colIndex['Description']  = i;
      if (txt.includes('rx level'))     colIndex['RX Level']     = i;
      if (txt.includes('rx threshold')) colIndex['RX Threshold'] = i;
      if (txt.includes('oper status'))  colIndex['Oper Status']  = i;
    });

    // Ambil baris data (skip header)
    const trs = Array.from(table.querySelectorAll('tr')).slice(1);
    const out = [];
    for (const tr of trs) {
      const tds = Array.from(tr.querySelectorAll('td'));
      if (!tds.length) continue;
      const row = {};
      Object.entries(colIndex).forEach(([name, idx]) => {
        if (idx != null && idx < tds.length) {
          row[name] = (tds[idx].textContent || '').trim();
        }
      });
      // Hanya terima baris yang relevan (minimal IP/Name dan Interface/Description)
      const ok = row['NE IP'] && row['NE Name'] && (row['Interface'] || row['Description']);
      if (ok) out.push(row);
    }
    return out;
  });

  return rows;
}
`.trim() + '\n';

fs.writeFileSync(file, before + replacement + after);
console.log('✅ fetchTable() berhasil diganti.');
