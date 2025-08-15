#!/usr/bin/env bash
set -euo pipefail

# ====== KONFIG ======
REPO_DIR="${HOME}/cekrsltele"
BRANCH="main"
REMOTE_SSH="git@github.com:nicolepell6969/cekrsltele.git"

# pakai identitas yang kamu minta simpan
GIT_NAME="nicolepell6969"
GIT_EMAIL="ferenrezareynaldo5@gmail.com"

SYSTEMD_SERVICE=""   # isi "cekrsltele" jika pakai systemd; kosongkan jika tidak
PM2_NAME=""          # isi "cekrsltele" jika pakai PM2; kosongkan jika tidak
# ====================

echo "==> cd $REPO_DIR"
cd "$REPO_DIR"

# pastikan remote SSH
if git remote -v | grep -q '^origin'; then
  git remote set-url origin "$REMOTE_SSH"
else
  git remote add origin "$REMOTE_SSH"
fi

# checkout/pull
git fetch origin || true
if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
  git checkout "$BRANCH"
else
  git checkout -b "$BRANCH"
fi
git pull --rebase origin "$BRANCH" || true

# backup
TS="$(date +%Y%m%d-%H%M%S)"
BKDIR=".backup-$TS"
mkdir -p "$BKDIR"
for f in bot.js checkMetroStatus.js; do
  [ -f "$f" ] && cp -f "$f" "$BKDIR/$f" || true
done
echo "==> Backup ke $BKDIR"

# .gitignore aman
grep -qxF "node_modules" .gitignore || echo "node_modules" >> .gitignore
grep -qxF ".env" .gitignore || echo ".env" >> .gitignore
grep -qxF "history.json" .gitignore || echo "history.json" >> .gitignore
grep -qxF "npm-debug.log*" .gitignore || echo "npm-debug.log*" >> .gitignore

# =================== tulis checkMetroStatus.js (plain text format) ===================
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

// ---- formatter PLAIN TEXT (tanpa HTML) ----
function formatLinePlain(it) {
  const ip = it['NE IP'] || 'N/A';
  const neName = it['NE Name'] || 'N/A';
  const iface = it['Interface'] || 'N/A';
  const ifSpeed = it['IF Speed'] || 'N/A';
  const desc = it['Description'] || 'N/A';
  const rx = it['RX Level'] || 'N/A';
  const thr = it['RX Threshold'] || 'N/A';
  const oper = it['Oper Status'] || 'N/A';
  const emoji = getRxLevelStatusEmoji(rx, thr);
  return `▶️ ${ip} | ${neName} | ${iface} | ${ifSpeed} | ${desc} | ${rx} | ${thr} | ${oper} ${emoji}`;
}

function formatSidePlain(rows, labelA, labelB) {
  if (!rows || !rows.length) return `▶️ ${labelA} → ${labelB}\n(i) tidak ada data relevan`;
  return `▶️ ${labelA} → ${labelB}\n` + rows.map(formatLinePlain).join('\n');
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
      formatSidePlain(sideA, baseA, baseB),
      '────────────',
      formatSidePlain(sideB, baseB, baseA)
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
module.exports._formatSidePlain = formatSidePlain;
module.exports._baseLabel = baseLabel;
module.exports._filterByOpponentDescription = filterByOpponentDescription;
EOF

# ===================== tulis bot.js (tanpa HTML, tombol cek ulang) =====================
cat > bot.js <<'EOF'
require('dotenv').config();
const TelegramBot = require('node-telegram-bot-api');
const fs = require('fs');
const checkMetroStatus = require('./checkMetroStatus');
const { launchBrowser } = require('./checkMetroStatus');

const token = process.env.TELEGRAM_BOT_TOKEN;
if (!token) { console.error('ENV TELEGRAM_BOT_TOKEN belum diset.'); process.exit(1); }

const bot = new TelegramBot(token, { polling: true });
const historyFilePath = './history.json';
const MAX_HISTORY = 50;

let history = [];
try {
  if (fs.existsSync(historyFilePath)) {
    const buf = fs.readFileSync(historyFilePath, 'utf8');
    history = JSON.parse(buf || '[]');
    if (!Array.isArray(history)) history = [];
  }
} catch { history = []; }

function writeHistory() {
  try { fs.writeFileSync(historyFilePath, JSON.stringify(history, null, 2), 'utf8'); }
  catch (e) { console.error('Gagal simpan history:', e.message); }
}

function safeShort(ne) {
  const parts = String(ne).split('-'); const mid = parts.length > 1 ? parts[1] : parts[0];
  return (mid || '').slice(0, 4) || ne.slice(0, 4);
}

function isDuplicate(ne1, ne2) {
  return history.some(h => (h.ne1 === ne1 && h.ne2 === ne2) || (h.ne1 === ne2 && h.ne2 === ne1));
}

function addHistory(ne1, ne2, result, name, startTime, endTime) {
  if (isDuplicate(ne1, ne2)) return;
  const duration = ((endTime || Date.now()) - startTime) / 1000;
  const timestamp = new Date(endTime || Date.now()).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' });
  history.push({ name, ne1, ne2, shortNe1: safeShort(ne1), shortNe2: safeShort(ne2), result, timestamp, duration });
  if (history.length > MAX_HISTORY) history = history.slice(-MAX_HISTORY);
  writeHistory();
}

function buildHistoryKeyboard() {
  return history.map((e, i) => ([
    { text: `🔄 Cek ulang ${e.shortNe1} ↔ ${e.shortNe2}`, callback_data: `retry_${i}` },
    { text: `🗑️ Hapus ${e.shortNe1} ↔ ${e.shortNe2}`, callback_data: `delete_${i}` }
  ]));
}

bot.on('message', async (msg) => {
  if (!msg.text) return;
  const text = msg.text.trim();
  const lower = text.toLowerCase();

  if (lower.startsWith('/cek ')) {
    const args = text.split(' ').slice(1).map(s => s.trim()).filter(Boolean);
    if (args.length !== 2) {
      return bot.sendMessage(msg.chat.id, '❗ Format salah.\nContoh: /cek SBY-GDK-EN1-H8M14 SBY-BDKL-OPT-H910C');
    }
    const [ne1, ne2] = args;
    const name = `${ne1} ${ne2}`;
    await bot.sendMessage(msg.chat.id, '🔄 Mengecek dua sisi, mohon tunggu…');

    const start = Date.now();
    const browser = await launchBrowser();
    try {
      const textOut = await checkMetroStatus(ne1, ne2, { browser, returnStructured: false });
      const end = Date.now();

      addHistory(ne1, ne2, textOut, name, start, end);

      await bot.sendMessage(
        msg.chat.id,
        `🕛 Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${textOut}`
      );
    } catch (e) {
      console.error(e);
      await bot.sendMessage(msg.chat.id, `❌ Gagal melakukan pengecekan: ${e.message || e}`);
    } finally {
      await browser.close().catch(() => {});
    }
    return;
  }

  if (lower === '/history') {
    if (!history.length) return bot.sendMessage(msg.chat.id, '❌ Belum ada riwayat pengecekan.');
    return bot.sendMessage(msg.chat.id, '👉 Pilih aksi untuk riwayat:', {
      reply_markup: { inline_keyboard: buildHistoryKeyboard() }
    });
  }

  if (lower === '/start' || lower === '/help') {
    return bot.sendMessage(msg.chat.id, [
      'Hai! 👋',
      'Perintah:',
      '• /cek NE1 NE2  → cek dua arah (filter Description = base lawan)',
      '• /history      → cek ulang / hapus riwayat'
    ].join('\n'));
  }

  return bot.sendMessage(msg.chat.id, '👍');
});

bot.on('callback_query', async (q) => {
  const { data, message } = q;
  await bot.answerCallbackQuery(q.id, { show_alert: false }).catch(() => {});
  try {
    if (data.startsWith('retry_')) {
      const i = Number(data.split('_')[1]);
      const e = history[i];
      if (!e) return;
      await bot.sendMessage(message.chat.id, `🔄 Cek ulang: ${e.ne1} ↔ ${e.ne2}…`);
      const browser = await launchBrowser();
      try {
        const textOut = await checkMetroStatus(e.ne1, e.ne2, { browser, returnStructured: false });
        const end = Date.now();
        await bot.sendMessage(
          message.chat.id,
          `🕛 Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${textOut}`
        );
      } finally {
        await browser.close().catch(() => {});
      }
      return;
    }
    if (data.startsWith('delete_')) {
      const i = Number(data.split('_')[1]);
      const e = history[i];
      if (!e) return;
      history.splice(i, 1);
      writeHistory();
      await bot.sendMessage(message.chat.id, `✅ Riwayat ${e.shortNe1} ↔ ${e.shortNe2} dihapus.`);
      return;
    }
  } catch (e) {
    await bot.answerCallbackQuery(q.id, { text: '❌ Terjadi kesalahan. Coba lagi.', show_alert: true });
  }
});
EOF

echo "==> npm install (sinkron lockfile)…"
npm install

# set identitas git
git config user.name >/dev/null 2>&1 || git config user.name "$GIT_NAME"
git config user.email >/dev/null 2>&1 || git config user.email "$GIT_EMAIL"

# pastikan node_modules tidak ikut
git rm -r --cached node_modules >/dev/null 2>&1 || true

echo '==> Commit & push…'
git add -A
git commit -m "feat: output plain text format; keep 2-side check + retry buttons; filter Description by opponent base" || true
git branch -M "$BRANCH"
git push -u origin "$BRANCH"

# restart service jika diisi
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

echo "✅ Selesai. Format output kini plain text persis contohmu & sudah ter-push."	
