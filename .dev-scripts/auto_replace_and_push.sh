#!/usr/bin/env bash
set -euo pipefail

# ====== KONFIGURASI ======
REPO_DIR="${HOME}/cekrsltele"
BRANCH="main"
REMOTE_SSH="git@github.com:nicolepell6969/cekrsltele.git"
GIT_NAME="nicolepell6969"
GIT_EMAIL="ferenrezareynaldo5@gmail.com"
SYSTEMD_SERVICE=""   # isi "cekrsltele" jika pakai systemd; kosongkan jika tidak
PM2_NAME=""          # isi "cekrsltele" jika pakai PM2; kosongkan jika tidak
# =========================

echo "==> Masuk repo: $REPO_DIR"
cd "$REPO_DIR"

# Pastikan remote SSH benar
if git remote -v | grep -q '^origin'; then
  git remote set-url origin "$REMOTE_SSH"
else
  git remote add origin "$REMOTE_SSH"
fi

# Checkout branch
git fetch origin || true
if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
  git checkout "$BRANCH"
else
  git checkout -b "$BRANCH"
fi
git pull --rebase origin "$BRANCH" || true

# Backup file lama
TS="$(date +%Y%m%d-%H%M%S)"
BKDIR=".backup-$TS"
mkdir -p "$BKDIR"
[ -f checkMetroStatus.js ] && cp -f checkMetroStatus.js "$BKDIR/checkMetroStatus.js" || true
echo "==> Backup di $BKDIR"

# .gitignore aman
grep -qxF "node_modules" .gitignore || echo "node_modules" >> .gitignore
grep -qxF ".env" .gitignore || echo ".env" >> .gitignore
grep -qxF "history.json" .gitignore || echo "history.json" >> .gitignore
grep -qxF "npm-debug.log*" .gitignore || echo "npm-debug.log*" >> .gitignore

# ============ TULIS checkMetroStatus.js (VERSI TERBARU) ============
cat > checkMetroStatus.js <<'EOF'
const puppeteer = require('puppeteer');

const PUPPETEER_EXECUTABLE_PATH = process.env.PUPPETEER_EXECUTABLE_PATH || null;
const PAGE_TIMEOUT = Number(process.env.PAGE_TIMEOUT_MS || 60000);
const HEADLESS = process.env.HEADLESS !== 'false';
const HIGHER_IS_BETTER = process.env.RX_HIGHER_IS_BETTER !== 'false';

function toUpperCaseNEName(neName) {
  return String(neName || '').toUpperCase();
}

// Ambil base label seperti "SBY-GDK" dari "SBY-GDK-EN1-H8M14"
function baseLabel(ne) {
  const p = String(ne).split('-');
  return p.length >= 2 ? `${p[0]}-${p[1]}` : String(ne);
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
    waitUntil: 'domcontentloaded',
    timeout: PAGE_TIMEOUT
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

/**
 * Filter satu sisi berdasarkan "base lawan" yang MUNCUL di kolom Description.
 * Contoh:
 *   - sisi A (SBY-GDK) -> target lawan "SBY-BDKL" → pilih rows yang Description mengandung "SBY-BDKL"
 */
function filterByOpponentDescription(rows, opponentBase) {
  const target = String(opponentBase).toLowerCase();
  return (rows || []).filter((it) => {
    const desc = String(it['Description'] || '').toLowerCase();
    return desc.includes(target);
  });
}

function formatLineHTML(it) {
  const iface = it['Interface'] || 'N/A';
  const rx = it['RX Level'] || 'N/A';
  const thr = it['RX Threshold'] || 'N/A';
  const oper = it['Oper Status'] || 'N/A';
  const ip = it['NE IP'] || '';
  const ipLink = ip ? `<a href="http://${ip}">${ip}</a>` : 'N/A';
  const emoji = getRxLevelStatusEmoji(rx, thr);
  return `• <b>${iface}</b> | RX <code>${rx}</code> | Thr <code>${thr}</code> | <i>${oper}</i> | ${ipLink} ${emoji}`;
}

function formatSideHTML(rows, labelA, labelB) {
  if (!rows || !rows.length) return `<b>▶️ ${labelA} → ${labelB}</b>\n(i) tidak ada data relevan`;
  return `<b>▶️ ${labelA} → ${labelB}</b>\n` + rows.map(formatLineHTML).join('\n');
}

async function checkMetroStatus(neName1, neName2, options = {}) {
  const browser = options.browser || await launchBrowser();
  const ownBrowser = !options.browser;
  const page = await browser.newPage();

  try {
    const ne1 = toUpperCaseNEName(neName1);
    const ne2 = toUpperCaseNEName(neName2);

    const baseA = baseLabel(ne1); // contoh: SBY-GDK
    const baseB = baseLabel(ne2); // contoh: SBY-BDKL

    // Ambil hasil dari sudut pandang masing-masing NE
    const rowsA = await fetchRxTable(page, ne1);
    const rowsB = await fetchRxTable(page, ne2);

    // Sisi A: pilih baris yang Description-nya menyebut base B
    const sideA = filterByOpponentDescription(rowsA, baseB);
    // Sisi B: pilih baris yang Description-nya menyebut base A
    const sideB = filterByOpponentDescription(rowsB, baseA);

    if (options.returnStructured) {
      return { sideA, sideB, labelA: baseA, labelB: baseB };
    }

    return [
      formatSideHTML(sideA, baseA, baseB),
      '────────────',
      formatSideHTML(sideB, baseB, baseA)
    ].join('\n');

  } catch (err) {
    return `❌ Gagal memeriksa RX Level\nError: ${err.message}`;
  } finally {
    await page.close().catch(() => {});
    if (ownBrowser) await browser.close().catch(() => {});
  }
}

module.exports = checkMetroStatus;
module.exports.launchBrowser = launchBrowser;
module.exports._formatSideHTML = formatSideHTML;
module.exports._baseLabel = baseLabel;
module.exports._filterByOpponentDescription = filterByOpponentDescription;
EOF
# ================================================================

echo "==> npm install (sync lockfile)…"
npm install

# Set identitas git lokal bila belum
git config user.name >/dev/null 2>&1 || git config user.name "$GIT_NAME"
git config user.email >/dev/null 2>&1 || git config user.email "$GIT_EMAIL"

# Pastikan node_modules tidak ikut
git rm -r --cached node_modules >/dev/null 2>&1 || true

echo "==> Commit & push…"
git add -A
git commit -m "feat: checkMetroStatus filter by opponent in Description (dua sisi)" || true
git branch -M "$BRANCH"
git push -u origin "$BRANCH"

# Restart service jika diisi
if [[ -n "${SYSTEMD_SERVICE}" ]]; then
  echo "==> Restart systemd service: ${SYSTEMD_SERVICE}"
  sudo systemctl daemon-reload || true
  sudo systemctl restart "${SYSTEMD_SERVICE}" || true
fi
if [[ -n "${PM2_NAME}" ]]; then
  echo "==> Restart PM2 app: ${PM2_NAME}"
  if command -v pm2 >/dev/null 2>&1; then
    pm2 restart "${PM2_NAME}" || true
  fi
fi

echo "✅ Selesai. File checkMetroStatus.js diperbarui & dipush ke GitHub."
