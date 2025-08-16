// checkMetroStatus.js — final: robust RAW parse + regex match + smart service + clear input + RX->PortStatus fallback
const puppeteer = require('puppeteer');

const PUPPETEER_EXECUTABLE_PATH = process.env.PUPPETEER_EXECUTABLE_PATH || null;
const PAGE_TIMEOUT = Number(process.env.PAGE_TIMEOUT_MS || 60000);
const HEADLESS = process.env.HEADLESS !== 'false';
const HIGHER_IS_BETTER = process.env.RX_HIGHER_IS_BETTER !== 'false';

/* ---------- helpers ---------- */
function toUpperCaseNEName(neName){ return String(neName||'').toUpperCase(); }
function baseLabel(ne){ const p = String(ne).split('-'); return p.length>=2 ? `${p[0]}-${p[1]}` : String(ne); }
function getRxLevelStatusEmoji(rx, thr){
  if (rx === '-40.00') return '❌';
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

/* ---------- pilih service yang aman ---------- */
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

/* ---------- scraping ---------- */
async function fetchTable(page, neName, serviceLabel){
  await page.goto('http://124.195.52.213:9487/snmp/metro_manual.php', {
    waitUntil:'domcontentloaded', timeout: PAGE_TIMEOUT
  });

  // Clear input lalu isi ulang
  await page.waitForSelector('input[name="nename"]', { timeout: 10000 });
  await page.focus('input[name="nename"]');
  await page.keyboard.down('Control'); await page.keyboard.press('KeyA'); await page.keyboard.up('Control');
  await page.keyboard.press('Backspace');
  await page.$eval('input[name="nename"]', el => el.value = '');
  await page.type('input[name="nename"]', neName);

  // Pilih service lewat value/label apa pun
  const ok = serviceLabel.toLowerCase().includes('rx')
    ? await selectService(page, ['rx-level','rx level','rx'])
    : await selectService(page, ['port-status','port status','port']);
  if (!ok) { await page.select('select[name="service"]', serviceLabel); } // fallback

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
      if(!tables.length) return [];

      // pilih tabel paling relevan (paling banyak header cocok)
      let best = { score:-1, table:null };
      for(const t of tables){
        const headers = Array.from(t.querySelectorAll('th,td')).map(c=>c.textContent.trim().toLowerCase());
        const score = wanted.reduce((s,w)=> s + (headers.some(h=>h.includes(w.toLowerCase()))?1:0), 0);
        if (score > best.score) best = { score, table:t };
      }
      if(!best.table) return [];

      // mapping kolom
      const headerRow = best.table.querySelector('tr');
      const headerCells = headerRow ? Array.from(headerRow.children) : [];
      const colIndex = {};
      headerCells.forEach((cell,i)=>{
        const txt = cell.textContent.trim().toLowerCase();
        wanted.forEach(w=>{ if(txt.includes(w.toLowerCase())) colIndex[w]=i; });
      });

      // ekstrak baris + RAW gabungan
      const data = [];
      const trs = Array.from(best.table.querySelectorAll('tr')).slice(1);
      for(const tr of trs){
        const tds = Array.from(tr.querySelectorAll('td')); if(!tds.length) continue;

        const raw = tds.map(td => (td.textContent||'').trim()).join(' | ');
        const row = { __RAW: raw };

        Object.entries(colIndex).forEach(([name,idx])=>{
          if (idx < tds.length) row[name] = tds[idx].textContent.trim();
        });

        // heuristic kalau Description kosong: cari sel yg mengandung "to_" / "to-" / "10g"
        if (!row['Description']) {
          const cand = tds.find(td => /to[_\-]|10g/i.test(td.textContent||''));
          if (cand) row['Description'] = cand.textContent.trim();
        }
        // heuristic minimal NE Name
        if (!row['NE Name'] && tds[1]) row['NE Name'] = tds[1].textContent.trim();

        data.push(row);
      }
      return data;
    });
    return rows;
  } finally { await resPage.close().catch(()=>{}); }
}

/* ---------- matcher robust ---------- */
function norm(s){ return String(s||'').toUpperCase().replace(/[^A-Z0-9]+/g,' ').trim(); }
function contains(hay, needle){
  const H = norm(hay), N = norm(needle);
  if(!N) return false;
  return H.includes(N);
}
function matchesOpponent(text, opponentBase, opponentFull){
  const H = String(text || '');
  const baseN = norm(opponentBase);
  const fullN = norm(opponentFull);
  if (!baseN) return false;

  // match base/full setelah normalisasi
  if (contains(H, baseN) || (fullN && contains(H, fullN))) return true;

  // regex: "to[_- ]*<opponentBase>" toleran underscore/strip/spasi
  const b = baseN.replace(/\s+/g, '[_\\-\\s]*'); // SBY GGKJ -> SBY[_-\s]*GGKJ
  const re = new RegExp(`TO[_\\-\\s]*${b}`, 'i');
  if (re.test(H)) return true;

  return false;
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
  const desc=it['Description']||'N/A', rx=it['RX Level']||'N/A', thr=it['RX Threshold']||'N/A', oper=it['Oper Status']||'N/A';
  return `▶️ ${ip} | ${name} | ${iface} | ${spd} | ${desc} | ${rx} | ${thr} | ${oper} ${getRxLevelStatusEmoji(rx,thr)}`;
}
function formatSidePlain(rows, labelA, labelB){
  if(!rows || !rows.length) return `▶️ ${labelA} → ${labelB}\n(i) tidak ada data relevan`;
  return `▶️ ${labelA} → ${labelB}\n` + rows.map(formatLinePlain).join('\n');
}

/* ---------- main ---------- */
async function checkMetroStatus(neName1, neName2, options = {}){
  const browser = options.browser || await launchBrowser();
  const ownBrowser = !options.browser;
  const page = await browser.newPage();

  try{
    const ne1 = toUpperCaseNEName(neName1);
    const ne2 = toUpperCaseNEName(neName2);
    const baseA = baseLabel(ne1); // contoh: SBY-GGKJ
    const baseB = baseLabel(ne2); // contoh: SBY-PRMJ

    // 1) RX Level
    let rowsA_rx = await fetchTable(page, ne1, 'rx-level');
    let rowsB_rx = await fetchTable(page, ne2, 'rx-level');
    let sideA = filterByOpponent(rowsA_rx, baseB, ne2);
    let sideB = filterByOpponent(rowsB_rx, baseA, ne1);

    // 2) Fallback -> Port Status bila kosong
    if(!sideA.length){
      const rowsA_ps = await fetchTable(page, ne1, 'port status');
      const pickA = filterByOpponent(rowsA_ps, baseB, ne2);
      if(pickA.length) sideA = pickA;
    }
    if(!sideB.length){
      const rowsB_ps = await fetchTable(page, ne2, 'port status');
      const pickB = filterByOpponent(rowsB_ps, baseA, ne1);
      if(pickB.length) sideB = pickB;
    }

    const text = [
      formatSidePlain(sideA, baseA, baseB),
      '────────────',
      formatSidePlain(sideB, baseB, baseA)
    ].join('\n');

    if (options.returnStructured) return { sideA, sideB, labelA: baseA, labelB: baseB };
    return text;
  } catch(err){
    return `❌ Gagal memeriksa RX Level\nError: ${err.message}`;
  } finally {
    await page.close().catch(()=>{});
    if (ownBrowser) await browser.close().catch(()=>{});
  }
}

module.exports = checkMetroStatus;
module.exports.launchBrowser = launchBrowser;
module.exports._formatSidePlain = formatSidePlain;
module.exports._baseLabel = baseLabel;
module.exports._filterByOpponent = filterByOpponent;
module.exports._matchesOpponent = matchesOpponent;
module.exports._norm = norm;
