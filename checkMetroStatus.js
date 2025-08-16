/**
 * checkMetroStatus.js — versi cepat & stabil
 * - Reuse 1 browser (singleton) + 2 fetcher tab
 * - Block resource tidak perlu (image/css/font/media)
 * - Cek 2 sisi paralel
 * - Batasi kandidat via ENV MAX_CANDIDATES (default 4)
 * - Timeout tiap langkah via ENV PAGE_TIMEOUT_MS (default 15000)
 * - Limit baris output via ENV MAX_LINES_PER_SIDE (default 40)
 */
const puppeteer = require('puppeteer');

const PUPPETEER_EXECUTABLE_PATH = process.env.PUPPETEER_EXECUTABLE_PATH || null;
const PAGE_TIMEOUT = Number(process.env.PAGE_TIMEOUT_MS || 15000);
const HEADLESS = process.env.HEADLESS !== 'false';
const MAX_CANDIDATES = Number(process.env.MAX_CANDIDATES || 4);
const HIGHER_IS_BETTER = process.env.RX_HIGHER_IS_BETTER !== 'false';

/* ---------- util ---------- */
const U = {
  up: s => String(s||'').toUpperCase().trim(),
  uniq: a => Array.from(new Set((a||[]).filter(Boolean))),
  citySite: ne => {
    const p = U.up(ne).split('-');
    return p.length>=2 ? `${p[0]}-${p[1]}` : U.up(ne);
  },
  emoji(rx, thr){
    if (String(rx).trim() === '-40.00') return '❌';
    const r = Number(rx), t = Number(thr);
    if (Number.isNaN(r) || Number.isNaN(t)) return '❓';
    return (HIGHER_IS_BETTER ? r>t : r<t) ? '✅' : '⚠️';
  },
  norm: s => String(s||'').toUpperCase().replace(/[^A-Z0-9]+/g,' ').trim(),
  contains(hay, needle){ const H=U.norm(hay), N=U.norm(needle); return N && H.includes(N); },
};

/* ---------- kandidat NE (diurutkan paling prospektif) ---------- */
function genCandidates(ne){
  const NE = U.up(ne);
  const parts = NE.split('-');
  const citySite = U.citySite(NE);
  const third = parts[2] || '';
  const swapMode = s => s.replace(/-EN1-/g,'-OPT-').replace(/-OPT-/g,'-EN1-');
  const swapH = s => s.replace(/H910D/g,'910D').replace(/-910D\b/g,'-H910D');

  const arr = [
    NE,
    `${citySite}-EN1-H910D`,
    `${citySite}-OPT-H910D`,
    `${citySite}`,
    swapMode(NE), swapH(NE), swapH(swapMode(NE)),
    `${citySite}-${third||'EN1'}`,
    `${citySite}-${third||'OPT'}`,
    `${citySite}-EN1-910D`,
    `${citySite}-OPT-910D`,
  ];
  return U.uniq(arr).slice(0, MAX_CANDIDATES);
}

/* ---------- launch & singleton ---------- */
async function launchBrowser(){
  return puppeteer.launch({
    headless: HEADLESS,
    args: [
      '--single-process',
      '--no-zygote',
      '--disable-dev-shm-usage',
      '--no-sandbox',
      '--disable-setuid-sandbox'
    ],
    executablePath: PUPPETEER_EXECUTABLE_PATH || undefined
  });
}
let _sharedBrowser = null;
async function getBrowser(){
  try {
    if (_sharedBrowser && _sharedBrowser.process() && !_sharedBrowser.process().killed) {
      return _sharedBrowser;
    }
  } catch {}
  _sharedBrowser = await launchBrowser();
  return _sharedBrowser;
}
function notifyProgress(options, text){
  try { if (options && typeof options.progress === 'function') options.progress(text); } catch {}
}

/* ---------- fetcher cepat (reuse tab) ---------- */
async function createFetcher(browser){
  const page = await browser.newPage();
  await page.setViewport({ width: 1024, height: 800, deviceScaleFactor: 1 });
  await page.setRequestInterception(true);
  page.on('request', req => {
    const type = req.resourceType();
    if (['image','stylesheet','font','media'].includes(type)) return req.abort();
    const url = req.url();
    if (/google-analytics|doubleclick|facebook|hotjar/i.test(url)) return req.abort();
    return req.continue();
  });

  const resPage = await browser.newPage();
  await resPage.setRequestInterception(true);
  resPage.on('request', req => {
    const type = req.resourceType();
    if (['image','stylesheet','font','media'].includes(type)) return req.abort();
    return req.continue();
  });

  async function gotoForm(){
    await page.goto('http://124.195.52.213:9487/snmp/metro_manual.php', {
      waitUntil: 'domcontentloaded', timeout: PAGE_TIMEOUT
    });
  }

  async function submit(neName, serviceLabel){
    await page.waitForSelector('input[name="nename"]', { timeout: PAGE_TIMEOUT });
    await page.$eval('input[name="nename"]', el => el.value = '');
    await page.type('input[name="nename"]', neName);

    // pilih service by label/text
    const ok = await page.evaluate((label)=>{
      const sel = document.querySelector('select[name="service"]');
      if(!sel) return false;
      const t = String(label).toLowerCase();
      const i = Array.from(sel.options).findIndex(o =>
        (o.value||'').toLowerCase().includes(t) || (o.textContent||'').toLowerCase().includes(t)
      );
      if (i>=0){ sel.selectedIndex=i; return true; }
      return false;
    }, serviceLabel);
    if (!ok) await page.select('select[name="service"]', serviceLabel);

    await page.click('input[name="submit"]');
    await page.waitForSelector('iframe#myIframe', { timeout: PAGE_TIMEOUT });

    const frameUrl = await page.evaluate(()=>{
      const i = document.querySelector('iframe#myIframe');
      return i && i.src ? i.src : null;
    });
    if (!frameUrl) throw new Error('Frame URL tidak ditemukan');

    await resPage.goto(frameUrl, { waitUntil: 'domcontentloaded', timeout: PAGE_TIMEOUT });
    return parseTable(resPage);
  }

  return {
    async run(neName, service){ await gotoForm(); return submit(neName, service); },
    close: async ()=> { try{ await page.close(); }catch{} try{ await resPage.close(); }catch{} }
  };
}

/* ---------- parser tabel ---------- */
async function parseTable(resPage){
  return resPage.evaluate(()=>{
    const wanted = ['NE Name','Description','RX Level','RX Threshold','Oper Status','Interface','IF Speed','NE IP'];
    const tables = Array.from(document.querySelectorAll('table'));

    function buildRow(tds, colIndex){
      const raw = tds.map(td => (td.textContent||'').trim()).join(' | ');
      const row = { __RAW: raw };
      for (const [k,i] of Object.entries(colIndex)) if (i < tds.length) row[k] = tds[i].textContent.trim();
      if (!row['Description']) {
        const cand = tds.find(td => /to[_\-]|10g|ge\d/i.test((td.textContent||'')));
        if (cand) row['Description'] = cand.textContent.trim();
      }
      if (!row['NE Name'] && tds[1]) row['NE Name'] = tds[1].textContent.trim();
      return row;
    }

    if (tables.length){
      // pilih tabel paling kaya kolom
      let best = { score:-1, t:null };
      for(const t of tables){
        const headers = Array.from(t.querySelectorAll('th,td')).map(c=>(c.textContent||'').trim().toLowerCase());
        const score = wanted.reduce((s,w)=> s + (headers.some(h=>h.includes(w.toLowerCase()))?1:0), 0);
        if (score>best.score) best = { score, t };
      }
      const table = best.t;
      if (table){
        const rows = Array.from(table.querySelectorAll('tr'));
        const head = rows.shift();
        const idx = {};
        if (head){
          Array.from(head.children).forEach((c,i)=>{
            const txt=(c.textContent||'').trim().toLowerCase();
            wanted.forEach(w=>{ if (txt.includes(w.toLowerCase())) idx[w]=i; });
          });
        }
        const out=[];
        for(const tr of rows){
          const tds = Array.from(tr.querySelectorAll('td'));
          if (!tds.length) continue;
          out.push(buildRow(tds, idx));
        }
        if (out.length) return out;
      }
    }

    // fallback: scan semua tr
    const out=[];
    const trs = Array.from(document.querySelectorAll('tr'));
    for(const tr of trs){
      const tds = Array.from(tr.querySelectorAll('td'));
      if (!tds.length) continue;
      const raw = tds.map(td => (td.textContent||'').trim()).join(' | ');
      out.push({ __RAW: raw, 'Description': raw });
    }
    return out;
  });
}

/* ---------- filter lawan ---------- */
function matchOpponent(text, oppBase, oppFull){
  const H = String(text||'');
  const baseN = U.norm(oppBase);
  const fullN = U.norm(oppFull);
  if (!baseN) return false;
  if (U.contains(H, baseN) || (fullN && U.contains(H, fullN))) return true;
  const re = new RegExp(`TO[_\\-\\s]*${baseN.replace(/\s+/g,'[_\\-\\s]*')}`, 'i');
  return re.test(H);
}
function filterRows(rows, oppBase, oppFull){
  return (rows||[]).filter(r =>
    matchOpponent(r['Description'], oppBase, oppFull) ||
    matchOpponent(r['NE Name'],    oppBase, oppFull) ||
    matchOpponent(r['__RAW'],      oppBase, oppFull)
  );
}

/* ---------- format ---------- */
function fmtLine(r){
  const ip=r['NE IP']||'N/A', name=r['NE Name']||'N/A', ifc=r['Interface']||'N/A', sp=r['IF Speed']||'N/A';
  const desc=r['Description']||r['__RAW']||'N/A';
  const rx=r['RX Level']||'N/A', th=r['RX Threshold']||'N/A', op=r['Oper Status']||'N/A';
  return `▶️ ${ip} | ${name} | ${ifc} | ${sp} | ${desc} | ${rx} | ${th} | ${op} ${U.emoji(rx,th)}`;
}
function fmtSide(rows, a, b){
  const limit = Number(process.env.MAX_LINES_PER_SIDE || 40);
  if (!rows || !rows.length) return `▶️ ${a} → ${b}\n(i) tidak ada data relevan`;
  const lines = rows.map(fmtLine);
  const out = lines.slice(0, limit).join('\n');
  const more = lines.length>limit ? `\n… (${lines.length-limit} baris disembunyikan)` : '';
  return `▶️ ${a} → ${b}\n${out}${more}`;
}
function fmtAll(rows, a){
  if (!rows || !rows.length) return `📋 Semua data: ${a}\n(i) tidak ada data`;
  return `📋 Semua data: ${a}\n` + rows.map(fmtLine).join('\n');
}

/* ---------- mesin cek sisi ---------- */
async function trySide(fetcher, neOriginal, oppBase, oppFull, logs){
  const cands = genCandidates(neOriginal);
  for (const cand of cands){
    const rows = await fetcher.run(cand, 'rx-level');
    const ok = filterRows(rows, oppBase, oppFull);
    if (ok.length) return { rows: ok, used: cand, svc: 'rx' };
    logs.push(`ℹ️ RX: tidak ketemu dengan "${cand}", lanjut…`);
  }
  for (const cand of cands){
    const rows = await fetcher.run(cand, 'port status');
    const ok = filterRows(rows, oppBase, oppFull);
    if (ok.length) return { rows: ok, used: cand, svc: 'port' };
    logs.push(`ℹ️ Port: tidak ketemu dengan "${cand}", lanjut…`);
  }
  return { rows: [], used: cands[0]||neOriginal, svc: 'none' };
}

/* ---------- 1 NE: gabung RX + Port tanpa filter lawan ---------- */
function dedupe(rows){
  const seen = new Set(); const out=[];
  for(const r of rows||[]){ const k=r.__RAW || JSON.stringify(r); if(!seen.has(k)){ seen.add(k); out.push(r); } }
  return out;
}
async function trySingle(fetcher, neOriginal, logs){
  const cands = genCandidates(neOriginal);
  for (const cand of cands){
    const rx = await fetcher.run(cand, 'rx-level');
    const ps = await fetcher.run(cand, 'port status');
    const merged = dedupe([...(rx||[]), ...(ps||[])]);
    if (merged.length) return { rows: merged, used: cand };
    logs.push(`ℹ️ Tidak ketemu data dengan "${cand}" (RX+Port), lanjut…`);
  }
  return { rows: [], used: cands[0]||neOriginal };
}

/* ---------- API publik (pakai singleton + progress) ---------- */
async function checkMetroStatus(ne1, ne2, options={}){
  const browser = options.browser || await getBrowser();
  const fA = await createFetcher(browser);
  const fB = await createFetcher(browser);
  const logs = [];
  try{
    const A = U.up(ne1), B = U.up(ne2);
    const baseA = U.citySite(A), baseB = U.citySite(B);
    notifyProgress(options, `🔎 Mencoba varian NE: ${A} vs ${B}…`);

    const [resA, resB] = await Promise.all([
      trySide(fA, A, baseB, B, logs),
      trySide(fB, B, baseA, A, logs),
    ]);

    const text = [
      ...logs,
      fmtSide(resA.rows, U.citySite(resA.used), baseB),
      "------------",
      fmtSide(resB.rows, U.citySite(resB.used), baseA)
    ].join('\n');

    if (options.returnStructured){
      return {
        logs,
        sideA: resA.rows, usedA: resA.used, svcA: resA.svc,
        sideB: resB.rows, usedB: resB.used, svcB: resB.svc,
      };
    }
    return text;
  } catch(e){
    return `❌ Gagal memeriksa\nError: ${e.message}`;
  } finally {
    try{ await fA.close(); }catch{}
    try{ await fB.close(); }catch{}
  }
}

async function checkSingleNE(ne, options={}){
  const browser = options.browser || await getBrowser();
  const f = await createFetcher(browser);
  const logs=[];
  try{
    const A = U.up(ne);
    const single = await trySingle(f, A, logs);
    return [...logs, fmtAll(single.rows, U.citySite(single.used))].join('\n');
  } catch(e){
    return `❌ Gagal memeriksa NE\nError: ${e.message}`;
  } finally {
    try{ await f.close(); }catch{}
  }
}

module.exports = checkMetroStatus;
module.exports.checkSingleNE = checkSingleNE;
module.exports.launchBrowser = launchBrowser;
