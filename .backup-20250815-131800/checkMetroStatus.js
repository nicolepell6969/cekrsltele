const puppeteer = require('puppeteer');

const PUPPETEER_EXECUTABLE_PATH = process.env.PUPPETEER_EXECUTABLE_PATH || null;
const PAGE_TIMEOUT = Number(process.env.PAGE_TIMEOUT_MS || 60000);
const HEADLESS = process.env.HEADLESS !== 'false';
const HIGHER_IS_BETTER = process.env.RX_HIGHER_IS_BETTER !== 'false';

function toUpperCaseNEName(neName) {
  return String(neName || '').toUpperCase();
}

function getRxLevelStatusEmoji(rxLevel, rxThreshold) {
  if (rxLevel === '-40.00') return '❌';
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

async function fetchRxTable(page, neName) {
  await page.goto('http://124.195.52.213:9487/snmp/metro_manual.php', {
    waitUntil: 'domcontentloaded', timeout: PAGE_TIMEOUT
  });

  await page.type('input[name="nename"]', neName);
  await page.select('select[name="service"]', 'rx-level');
  await page.click('input[name="submit"]');

  await page.waitForSelector('iframe#myIframe', { timeout: 10000 });
  const frameUrl = await page.evaluate(() => {
    const i = document.querySelector('iframe#myIframe');
    return i && i.src ? i.src : null;
  });
  if (!frameUrl) throw new Error('Frame URL tidak ditemukan');

  const resPage = await page.browser().newPage();
  try {
    await resPage.goto(frameUrl, { waitUntil: 'networkidle2', timeout: PAGE_TIMEOUT });

    const rows = await resPage.evaluate(() => {
      const wanted = ['NE Name', 'Description', 'RX Level', 'RX Threshold', 'Oper Status', 'Interface', 'IF Speed', 'NE IP'];
      const tables = Array.from(document.querySelectorAll('table'));
      if (!tables.length) return [];

      let best = { score: -1, table: null };
      for (const t of tables) {
        const headers = Array.from(t.querySelectorAll('th,td')).map(c => c.textContent.trim().toLowerCase());
        const score = wanted.reduce((s, w) => s + (headers.some(h => h.includes(w.toLowerCase())) ? 1 : 0), 0);
        if (score > best.score) best = { score, table: t };
      }
      if (!best.table) return [];

      const headerRow = best.table.querySelector('tr');
      const headerCells = headerRow ? Array.from(headerRow.children) : [];
      const colIndex = {};
      headerCells.forEach((cell, i) => {
        const txt = cell.textContent.trim().toLowerCase();
        wanted.forEach((w) => { if (txt.includes(w.toLowerCase())) colIndex[w] = i; });
      });

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

function formatResults(results) {
  if (!results || !results.length) return '❌ Tidak ada data yang relevan';
  return results.map((it) => {
    const ip = it['NE IP'] || 'N/A';
    const ne = it['NE Name'] || 'N/A';
    const iface = it['Interface'] || 'N/A';
    const spd = it['IF Speed'] || 'N/A';
    const desc = it['Description'] || 'N/A';
    const rx = it['RX Level'] || 'N/A';
    const thr = it['RX Threshold'] || 'N/A';
    const oper = it['Oper Status'] || 'N/A';
    const emoji = getRxLevelStatusEmoji(rx, thr);
    return `▶️ ${ip} | ${ne} | ${iface} | ${spd} | ${desc} | ${rx} | ${thr} | ${oper} ${emoji}`;
  }).join('\n');
}

async function checkMetroStatus(neName1, neName2, options = {}) {
  const browser = options.browser || await launchBrowser();
  const page = await browser.newPage();
  const ownBrowser = !options.browser;

  try {
    const ne1 = toUpperCaseNEName(neName1);
    const ne2 = toUpperCaseNEName(neName2);
    const rows = await fetchRxTable(page, ne1);

    const filtered = rows.filter((it) => {
      const d = String(it['Description'] || '').toLowerCase();
      const n = String(it['NE Name'] || '').toLowerCase();
      return d.includes(ne1.toLowerCase()) || d.includes(ne2.toLowerCase()) ||
             n.includes(ne1.toLowerCase()) || n.includes(ne2.toLowerCase());
    });

    return formatResults(filtered);
  } catch (err) {
    return `❌ Gagal memeriksa RX Level\nError: ${err.message}`;
  } finally {
    await page.close().catch(() => {});
    if (ownBrowser) await browser.close().catch(() => {});
  }
}

module.exports = checkMetroStatus;
module.exports.launchBrowser = launchBrowser;
