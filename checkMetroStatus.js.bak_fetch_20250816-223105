// checkMetroStatus.js — FULL: 2 sisi + Fallback alias + user logs + RAW parse + RX->PortStatus + MODE 1 NE
const puppeteer = require('puppeteer');

const PUPPETEER_EXECUTABLE_PATH = process.env.PUPPETEER_EXECUTABLE_PATH || null;
const PAGE_TIMEOUT = Number(process.env.PAGE_TIMEOUT_MS || 60000);
const HEADLESS = process.env.HEADLESS !== 'false';
const HIGHER_IS_BETTER = process.env.RX_HIGHER_IS_BETTER !== 'false';

/* ---------- helpers ---------- */
function toUpperCaseNEName(neName){ return String(neName||'').toUpperCase().trim(); }
function uniq(arr){ return Array.from(new Set(arr.filter(Boolean))); }
function baseCitySite(ne){ const p = String(ne).toUpperCase().split('-'); return p.length>=2 ? `${p[0]}-${p[1]}` : String(ne).toUpperCase(); }
function getRxLevelStatusEmoji(rx, thr){
  if (String(rx).trim() === '-40.00') return '❌';
  const r = Number(rx), t = Number(thr);
  if (Number.isNaN(r) || Number.isNaN(t)) return '❓';
  return (HIGHER_IS_BETTER ? r>t : r<t) ? '✅' : '⚠️';
}
async function launchBrowser(){
  return puppeteer.launch({
    headless: HEADLESS,
    args: ['--no-sandbox','--disable-setuid-sandbox'],
    executablePath: PUPPETEER_EXECUTABLE_PATH || undefined
  });
}

/* ---------- generator alias NE ---------- */
function generateCandidates(ne){
  const NE = toUpperCaseNEName(ne);
  const parts = NE.split('-');
  const citySite = baseCitySite(NE);
  const third = parts[2] || '';

  const swapMode = (s)=> s.replace(/-EN1-/g,'-OPT-').replace(/-OPT-/g,'-EN1-');
  const swapH = (s)=> s.replace(/H910D/g,'910D').replace(/-910D\\b/g,'-H910D');

  const common = [
    NE,
    swapMode(NE),
    swapH(NE),
    swapH(swapMode(NE)),
    parts.slice(0,3).join('-'),
    parts.slice(0,3).join('-').replace(/EN1|OPT/g,m=>m==='EN1'?'OPT':'EN1'),
    citySite,
    `${citySite}-${third||'EN1'}`,
    `${citySite}-${third||'OPT'}`.replace(/EN1|OPT/g,'OPT'),
    `${citySite}-EN1-H910D`,
    `${citySite}-OPT-H910D`,
    `${citySite}-EN1-910D`,
    `${citySite}-OPT-910D`,
  ];

  const manual = [
    `${citySite}-OPT-H910D`,
    `${citySite}-EN1-H910D`,
    citySite,
    `${citySite}-OPT-910D`,
    `${citySite}-EN1-910D`,
  ];

  return uniq([...common, ...manual]);
}

/* ---------- pilih service ---------- */
async function selectService(page, targets){
  const value = await page.evaluate((ts)=>{
    const sel = document.querySelector('select[name="service"]');
    if(!sel) return null;
    const opts = Array.from(sel.options).map(o=>({
      value:(o.value||'').toLowerCase(),
      text:(o.textContent||'').toLowerCase()
    }));
    for(const raw of ts){
      const q = String(raw).toLowerCase();
      const idx = opts.findIndex(o => o.value.includes(q) || o.text.includes(q));
      if (idx>=0){ sel.selectedIndex = idx; return sel.options[idx].value; }
    }
    return null;
  }, targets);
  if (value) { await page.select('select[name="service"]', value); return true; }
  return false;
}

/* ---------- scraping satu query ---------- */
async function fetchTable(page, neName, serviceLabel){
  await page.goto('http://124.195.52.213:9487/snmp/metro_manual.php', {
    waitUntil:'domcontentloaded', timeout: PAGE_TIMEOUT
  });

  // Clear input
  await page.waitForSelector('input[name="nename"]', { timeout: 10000 });
  await page.focus('input[name="nename"]');
  await page.keyboard.down('Control'); await page.keyboard.press('KeyA'); await page.keyboard.up('Control');
  await page.keyboard.press('Backspace');
  await page.$eval('input[name="nename"]', el => el.value = '');
  await page.type('input[name="nename"]', neName);

  // Pilih service
  const ok = serviceLabel.toLowerCase().includes('rx')
    ? await selectService(page, ['rx-level','rx level','rx'])
    : await selectService(page, ['port-status','port status','port']);
  if (!ok) { await page.select('select[name="service"]', serviceLabel); }

  await page.click('input[name="submit"]');
  await page.waitForSelector('iframe#myIframe', { timeout: 10000 });

  const frameUrl = await page.evaluate(()=>{
    const i = document.querySelector('iframe#myIframe');
    return i && i.src ? i.src : null;
  });
  if(!frameUrl) throw new Error('Frame URL tidak ditemukan');

  const resPage = await page.browser().newPage();
  try{
    await resPage.goto(frameUrl, { waitUntil:'networkidle2', timeout: PAGE_TIMEOUT });

    const rows = await resPage.evaluate(()=>{
      const wanted = ['NE Name','Description','RX Level','RX Threshold','Oper Status','Interface','IF Speed','NE IP'];
      const tables = Array.from(document.querySelectorAll('table'));
      const data = [];

      const pushRow = (tds, colIndex)=>{
        const raw = tds.map(td => (td.textContent||'').trim()).join(' | ');
        const row = { __RAW: raw };
        Object.entries(colIndex).forEach(([name,idx])=>{
          if (idx < tds.length) row[name] = tds[idx].textContent.trim();
        });
        if (!row['Description']) {
          const cand = tds.find(td => /to[_\-]|10g/i.test(td.textContent||''));
          if (cand) row['Description'] = cand.textContent.trim();
        }
        if (!row['NE Name'] && tds[1]) row['NE Name'] = tds[1].textContent.trim();
        data.push(row);
      };

      if (tables.length){
        // pilih tabel paling relevan
        let best = { score:-1, table:null };
        for(const t of tables){
          const headers = Array.from(t.querySelectorAll('th,td')).map(c=>c.textContent.trim().toLowerCase());
          const score = wanted.reduce((s,w)=> s + (headers.some(h=>h.includes(w.toLowerCase()))?1:0), 0);
          if (score > best.score) best = { score, table:t };
        }
        const table = best.table;
        if (table){
          const headerRow = table.querySelector('tr');
          const headerCells = headerRow ? Array.from(headerRow.children) : [];
          const colIndex = {};
          headerCells.forEach((cell,i)=>{
            const txt = cell.textContent.trim().toLowerCase();
            wanted.forEach(w=>{ if(txt.includes(w.toLowerCase())) colIndex[w]=i; });
          });

          const trs = Array.from(table.querySelectorAll('tr')).slice(1);
          for(const tr of trs){
            const tds = Array.from(tr.querySelectorAll('td'));
            if(!tds.length) continue;
            pushRow(tds, colIndex);
          }
          if (data.length) return data;
        }
      }

      // Fallback super: scan semua <tr> mentah
      const rawRows = [];
      const trs = Array.from(document.querySelectorAll('tr'));
      for (const tr of trs) {
        const tds = Array.from(tr.querySelectorAll('td'));
        if (!tds.length) continue;
        const raw = tds.map(td => (td.textContent||'').trim()).join(' | ');
        rawRows.push({ __RAW: raw });
      }
      return rawRows;
    });

    return rows;
  } finally { await resPage.close().catch(()=>{}); }
}

/* ---------- matcher dua sisi ---------- */
function norm(s){ return String(s||'').toUpperCase().replace(/[^A-Z0-9]+/g,' ').trim(); }
function contains(hay, needle){ const H = norm(hay), N = norm(needle); return N ? H.includes(N) : false; }
function matchesOpponent(text, opponentBase, opponentFull){
  const H = String(text || '');
  const baseN = norm(opponentBase);
  const fullN = norm(opponentFull);
  if (!baseN) return false;

  if (contains(H, baseN) || (fullN && contains(H, fullN))) return true;

  const b = baseN.replace(/\s+/g, '[_\\-\\s]*');
  const re = new RegExp(`TO[_\\-\\s]*${b}`, 'i');
  return re.test(H);
}
function filterByOpponent(rows, opponentBase, opponentFull){
  return (rows||[]).filter((it)=>{
    return matchesOpponent(it['Description'], opponentBase, opponentFull) ||
           matchesOpponent(it['NE Name'],    opponentBase, opponentFull) ||
           matchesOpponent(it['__RAW'],      opponentBase, opponentFull);
  });
}

/* ---------- formatter ---------- */
function formatLinePlain(it){
  const ip=it['NE IP']||'N/A', name=it['NE Name']||'N/A', iface=it['Interface']||'N/A', spd=it['IF Speed']||'N/A';
  const desc=it['Description']||it['__RAW']||'N/A';
  const rx=it['RX Level']||'N/A', thr=it['RX Threshold']||'N/A', oper=it['Oper Status']||'N/A';
  return `▶️ ${ip} | ${name} | ${iface} | ${spd} | ${desc} | ${rx} | ${thr} | ${oper} ${getRxLevelStatusEmoji(rx,thr)}`;
}
function formatSidePlain(rows, labelA, labelB){
  if(!rows || !rows.length) return `▶️ ${labelA} → ${labelB}\n(i) tidak ada data relevan`;
  return `▶️ ${labelA} → ${labelB}\n` + rows.map(formatLinePlain).join('\n');
}
function formatAllPlain(rows, label){
  if(!rows || !rows.length) return `📋 Semua data: ${label}\n(i) tidak ada data`;
  return `📋 Semua data: ${label}\n` + rows.map(formatLinePlain).join('\n');
}

/* ---------- pencarian 2 sisi ---------- */
async function tryFetchForOneSide(page, neOriginal, opponentBase, opponentFull, logs){
  const candidates = generateCandidates(neOriginal);

  for (const cand of candidates){
    const rows = await fetchTable(page, cand, 'rx-level');
    const filtered = filterByOpponent(rows, opponentBase, opponentFull);
    if (filtered.length) return { rows: filtered, used: cand, service: 'rx-level' };
    logs.push(`ℹ️ Tidak ketemu data dengan "${cand}" di RX Level, mencoba kandidat lain…`);
  }

  for (const cand of candidates){
    const rows = await fetchTable(page, cand, 'port status');
    const filtered = filterByOpponent(rows, opponentBase, opponentFull);
    if (filtered.length) return { rows: filtered, used: cand, service: 'port-status' };
    logs.push(`ℹ️ Tidak ketemu data dengan "${cand}" di Port Status, mencoba kandidat lain…`);
  }

  return { rows: [], used: generateCandidates(neOriginal)[0]||neOriginal, service: 'none' };
}

/* ---------- MODE 1 NE: ambil semua data tanpa filter lawan ---------- */
function dedupeByRaw(rows){
  const seen = new Set(); const out = [];
  for (const r of rows||[]) {
    const key = r.__RAW || JSON.stringify(r);
    if (!seen.has(key)) { seen.add(key); out.push(r); }
  }
  return out;
}
async function tryFetchAllForSingle(page, neOriginal, logs){
  const candidates = generateCandidates(neOriginal);
  // kumpulkan kombinasi RX + Port untuk kandidat pertama yang menghasilkan data apa pun
  for (const cand of candidates){
    const rx = await fetchTable(page, cand, 'rx-level');
    const ps = await fetchTable(page, cand, 'port status');
    const merged = dedupeByRaw([...(rx||[]), ...(ps||[])]);
    if (merged.length) return { rows: merged, used: cand };
    logs.push(`ℹ️ Tidak ketemu data dengan "${cand}" (RX & Port), mencoba kandidat lain…`);
  }
  return { rows: [], used: candidates[0]||neOriginal };
}

/* ---------- public API ---------- */
async function checkMetroStatus(neName1, neName2, options = {}){
  const browser = options.browser || await launchBrowser();
  const ownBrowser = !options.browser;
  const page = await browser.newPage();

  try{
    const ne1 = toUpperCaseNEName(neName1);
    const ne2 = toUpperCaseNEName(neName2);
    const baseA = baseCitySite(ne1);
    const baseB = baseCitySite(ne2);

    const logs = [];
    const sideA = await tryFetchForOneSide(page, ne1, baseB, ne2, logs);
    const sideB = await tryFetchForOneSide(page, ne2, baseA, ne1, logs);

    const text = [
      ...logs,
      formatSidePlain(sideA.rows, baseCitySite(sideA.used), baseB),
      '────────────',
      formatSidePlain(sideB.rows, baseCitySite(sideB.used), baseA)
    ].join('\n');

    if (options.returnStructured) {
      return {
        logs,
        sideA: sideA.rows, usedA: sideA.used, svcA: sideA.service,
        sideB: sideB.rows, usedB: sideB.used, svcB: sideB.service,
        labelA: baseCitySite(sideA.used), labelB: baseCitySite(sideB.used)
      };
    }
    return text;

  } catch(err){
    return `❌ Gagal memeriksa RX Level\nError: ${err.message}`;
  } finally {
    await page.close().catch(()=>{});
    if (ownBrowser) await browser.close().catch(()=>{});
  }
}

/* ---- MODE 1 NE: publik ---- */
async function checkSingleNE(neName, options = {}){
  const browser = options.browser || await launchBrowser();
  const ownBrowser = !options.browser;
  const page = await browser.newPage();
  try{
    const ne = toUpperCaseNEName(neName);
    const logs = [];
    const res = await tryFetchAllForSingle(page, ne, logs);
    const label = baseCitySite(res.used);
    return [...logs, formatAllPlain(res.rows, label)].join('\n');
  } catch(err){
    return `❌ Gagal memeriksa NE\nError: ${err.message}`;
  } finally {
    await page.close().catch(()=>{});
    if (ownBrowser) await browser.close().catch(()=>{});
  }
}

module.exports = checkMetroStatus;
module.exports.checkSingleNE = checkSingleNE;
module.exports.launchBrowser = launchBrowser;
module.exports._generateCandidates = generateCandidates;
module.exports._formatSidePlain = formatSidePlain;
module.exports._filterByOpponent = filterByOpponent;
module.exports._norm = (s)=>String(s||'').toUpperCase().replace(/[^A-Z0-9]+/g,' ').trim();
