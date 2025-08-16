// checkMetroStatus.js — versi fallback + filter toleran + plain text
const puppeteer = require('puppeteer');

const PUPPETEER_EXECUTABLE_PATH = process.env.PUPPETEER_EXECUTABLE_PATH || null;
const PAGE_TIMEOUT = Number(process.env.PAGE_TIMEOUT_MS || 60000);
const HEADLESS = process.env.HEADLESS !== 'false';
// Jika angka RX > threshold dianggap OK (default: true). Ubah ke false bila kebalikan.
const HIGHER_IS_BETTER = process.env.RX_HIGHER_IS_BETTER !== 'false';

/* ---------- Helpers ---------- */
function toUpperCaseNEName(neName) {
  return String(neName || '').toUpperCase();
}
// Ambil base label: "SBY-GGKJ" dari "SBY-GGKJ-EN1-H910D"
function baseLabel(ne) {
  const p = String(ne).split('-');
  return p.length >= 2 ? `${p[0]}-${p[1]}` : String(ne);
}
function getRxLevelStatusEmoji(rxLevel, rxThreshold) {
  if (rxLevel === '-40.00') return '❌'; // pola error di data
  const rx = Number(rxLevel);
  const thr = Number(rxThreshold);
  if (Number.isNaN(rx) || Number.isNaN(thr)) return '❓';
  const ok = HIGHER_IS_BETTER ? (rx > thr) : (rx < thr);
  return ok ? '✅' : '⚠️';
}
async function launchBrowser() {
  return puppeteer.launch({
    headless: HEADLESS,
    args: ['--no-sandbox', '--disable-setuid-sandbox'],
    executablePath: PUPPETEER_EXECUTABLE_PATH || undefined
  });
}

/* ---------- Scraper ---------- */
async function fetchRxTable(page, neName, service = 'rx-level') {
  await page.goto('http://124.195.52.213:9487/snmp/metro_manual.php', {
    waitUntil: 'domcontentloaded',
    timeout: PAGE_TIMEOUT
  });

  // isi form
  await page.type('input[name="nename"]', neName);
  await page.select('select[name="service"]', service);
  await page.click('input[name="submit"]');

  // tunggu iframe
  await page.waitForSelector('iframe#myIframe', { timeout: 10000 });

  const frameUrl = await page.evaluate(() => {
    const i = document.querySelector('iframe#myIframe');
    return i && i.src ? i.src : null;
  });
  if (!frameUrl) throw new Error('Frame URL tidak ditemukan');

  // buka hasil pada tab baru (lebih stabil)
  const resPage = await page.browser().newPage();
  try {
    await resPage.goto(frameUrl, { waitUntil: 'networkidle2', timeout: PAGE_TIMEOUT });

    const rows = await resPage.evaluate(() => {
      const wanted = [
        'NE Name', 'Description', 'RX Level', 'RX Threshold',
        'Oper Status', 'Interface', 'IF Speed', 'NE IP'
      ];
      const tables = Array.from(document.querySelectorAll('table'));
      if (!tables.length) return [];

      // cari tabel yang paling mirip
      let best = { score: -1, table: null };
      for (const t of tables) {
        const headers = Array.from(t.querySelectorAll('th,td'))
          .map(c => c.textContent.trim().toLowerCase());
        const score = wanted.reduce(
          (s, w) => s + (headers.some(h => h.includes(w.toLowerCase())) ? 1 : 0), 0
        );
        if (score > best.score) best = { score, table: t };
      }
      if (!best.table) return [];

      // indeks kolom
      const headerRow = best.table.querySelector('tr');
      const headerCells = headerRow ? Array.from(headerRow.children) : [];
      const colIndex = {};
      headerCells.forEach((cell, i) => {
        const txt = cell.textContent.trim().toLowerCase();
        wanted.forEach(w => { if (txt.includes(w.toLowerCase())) colIndex[w] = i; });
      });

      // ekstrak baris
      const data = [];
      const trs = Array.from(best.table.querySelectorAll('tr')).slice(1);
      for (const tr of trs) {
        const tds = Array.from(tr.querySelectorAll('td'));
        if (!tds.length) continue;
        const row = {};
        Object.entries(colIndex).forEach(([name, idx]) => {
          if (idx < tds.length) row[name] = tds[idx].textContent.trim();
        });
        if (Object.keys(row).length) data.push(row);
      }
      return data;
    });

    return rows;
  } finally {
    await resPage.close().catch(() => {});
  }
}

/* ---------- Matching lawan (lebih toleran) ---------- */
function matchesOpponent(text, opponentBase) {
  const t = String(text || '').toUpperCase();
  const base = String(opponentBase || '').toUpperCase(); // contoh "SBY-PRMJ"
  if (!t) return false;
  if (t.includes(base)) return true;

  // fallback: token segmen ke-2 (PRMJ), perhatikan pemisah umum
  const token = base.split('-')[1] || base;
  return (
    t.includes(`-${token}-`) ||
    t.includes(`_${token}_`) ||
    t.includes(`${token}-`)  ||
    t.includes(`-${token}`)  ||
    t.includes(` ${token} `) ||
    t.endsWith(` ${token}`)  ||
    t.startsWith(`${token} `)
  );
}

function filterByOpponent(rows, opponentBase) {
  return (rows || []).filter((it) => {
    const desc = it['Description'];
    const name = it['NE Name'];
    return matchesOpponent(desc, opponentBase) || matchesOpponent(name, opponentBase);
  });
}

/* ---------- Formatter (plain text) ---------- */
function formatLinePlain(it) {
  const ip   = it['NE IP'] || 'N/A';
  const name = it['NE Name'] || 'N/A';
  const iface = it['Interface'] || 'N/A';
  const spd  = it['IF Speed'] || 'N/A';
  const desc = it['Description'] || 'N/A';
  const rx   = it['RX Level'] || 'N/A';
  const thr  = it['RX Threshold'] || 'N/A';
  const oper = it['Oper Status'] || 'N/A';
  const emoji = getRxLevelStatusEmoji(rx, thr);
  return `▶️ ${ip} | ${name} | ${iface} | ${spd} | ${desc} | ${rx} | ${thr} | ${oper} ${emoji}`;
}
function formatSidePlain(rows, labelA, labelB) {
  if (!rows || !rows.length) return `▶️ ${labelA} → ${labelB}\n(i) tidak ada data relevan`;
  return `▶️ ${labelA} → ${labelB}\n` + rows.map(formatLinePlain).join('\n');
}

/* ---------- Main ---------- */
async function checkMetroStatus(neName1, neName2, options = {}) {
  const browser = options.browser || await launchBrowser();
  const ownBrowser = !options.browser;
  const page = await browser.newPage();

  try {
    const ne1 = toUpperCaseNEName(neName1);
    const ne2 = toUpperCaseNEName(neName2);
    const baseA = baseLabel(ne1); // contoh: SBY-GGKJ
    const baseB = baseLabel(ne2); // contoh: SBY-PRMJ

    // 1) Tarik RX Level
    let rowsA_rx = await fetchRxTable(page, ne1, 'rx-level');
    let rowsB_rx = await fetchRxTable(page, ne2, 'rx-level');

    let sideA = filterByOpponent(rowsA_rx, baseB);
    let sideB = filterByOpponent(rowsB_rx, baseA);

    // 2) Fallback ke Port Status jika kosong
    if (!sideA.length) {
      const rowsA_ps = await fetchRxTable(page, ne1, 'port-status');
      const sideA_ps = filterByOpponent(rowsA_ps, baseB);
      if (sideA_ps.length) sideA = sideA_ps;
    }
    if (!sideB.length) {
      const rowsB_ps = await fetchRxTable(page, ne2, 'port-status');
      const sideB_ps = filterByOpponent(rowsB_ps, baseA);
      if (sideB_ps.length) sideB = sideB_ps;
    }

    // 3) Format ouput
    const text = [
      formatSidePlain(sideA, baseA, baseB),
      '────────────',
      formatSidePlain(sideB, baseB, baseA)
    ].join('\n');

    if (options.returnStructured) {
      return { sideA, sideB, labelA: baseA, labelB: baseB };
    }
    return text;

  } catch (err) {
    return `❌ Gagal memeriksa RX Level\nError: ${err.message}`;
  } finally {
    await page.close().catch(() => {});
    if (ownBrowser) await browser.close().catch(() => {});
  }
}

module.exports = checkMetroStatus;
module.exports.launchBrowser = launchBrowser;
module.exports._formatSidePlain = formatSidePlain;
module.exports._baseLabel = baseLabel;
module.exports._filterByOpponent = filterByOpponent;
module.exports._matchesOpponent = matchesOpponent;
