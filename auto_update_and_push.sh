#!/usr/bin/env bash
set -euo pipefail

# ===================== KONFIGURASI =====================
REPO_DIR="${HOME}/cekrsltele"          # folder repo di VPS
BRANCH="main"                          # nama branch
REMOTE_SSH="git@github.com:nicolepell6969/cekrsltele.git"  # remote SSH
SYSTEMD_SERVICE=""                     # contoh: "cekrsltele" (kosongkan jika tidak pakai)
PM2_NAME=""                            # contoh: "cekrsltele" (kosongkan jika tidak pakai)
GIT_NAME="nicolepell6969"
GIT_EMAIL="ferenrezareynaldo5@gmail.com"
# =======================================================

echo "==> Masuk ke repo: $REPO_DIR"
cd "$REPO_DIR"

# Pastikan remote SSH benar
if git remote -v | grep -q 'origin'; then
  git remote set-url origin "$REMOTE_SSH"
else
  git remote add origin "$REMOTE_SSH"
fi

# Pindah/cekout branch target
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
for f in bot.js checkMetroStatus.js; do
  [ -f "$f" ] && cp -f "$f" "$BKDIR/$f" || true
done
echo "==> Backup lama disimpan di $BKDIR"

# .gitignore aman
grep -qxF "node_modules" .gitignore || echo "node_modules" >> .gitignore
grep -qxF ".env" .gitignore || echo ".env" >> .gitignore
grep -qxF "history.json" .gitignore || echo "history.json" >> .gitignore
grep -qxF "npm-debug.log*" .gitignore || echo "npm-debug.log*" >> .gitignore

# ==================== Tulis checkMetroStatus.js ====================
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

/** Filter berdasarkan base label (SBY-XXX) */
function filterByBase(rows, base) {
  const b = String(base).toLowerCase();
  return (rows || []).filter((it) => {
    const ne   = String(it['NE Name']    || '').toLowerCase();
    const desc = String(it['Description']|| '').toLowerCase();
    const iface= String(it['Interface']  || '').toLowerCase();
    return ne.includes(b) || desc.includes(b) || iface.includes(b);
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

    const baseA = baseLabel(ne1);
    const baseB = baseLabel(ne2);

    // Ambil dari perspektif masing-masing sisi untuk akurasi
    const rowsA = await fetchRxTable(page, ne1);
    const rowsB = await fetchRxTable(page, ne2);

    const sideA = filterByBase(rowsA, baseA);  // hanya baris yang mengandung "SBY-GDK"
    const sideB = filterByBase(rowsB, baseB);  // hanya baris yang mengandung "SBY-BDKL"

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
EOF

# ========================= Tulis bot.js ============================
cat > bot.js <<'EOF'
require('dotenv').config();
const TelegramBot = require('node-telegram-bot-api');
const fs = require('fs');
const checkMetroStatus = require('./checkMetroStatus');
const { launchBrowser, _formatSideHTML } = require('./checkMetroStatus');

const token = process.env.TELEGRAM_BOT_TOKEN;
if (!token) { console.error('ENV TELEGRAM_BOT_TOKEN belum diset.'); process.exit(1); }

const bot = new TelegramBot(token, { polling: true });
const historyFilePath = './history.json';
const MAX_HISTORY = 50;

const previewCache = new Map(); // token -> {sideA, sideB, labelA, labelB, chatId, ts}
const CACHE_TTL_MS = 10 * 60 * 1000; // 10 menit

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

function makePreviewHTML(sideRows, labelA, labelB, limit = 5) {
  const rows = (sideRows || []).slice(0, limit);
  if (!rows.length) return `<b>▶️ ${labelA} → ${labelB}</b>\n(i) tidak ada data relevan`;
  const head = `<b>▶️ ${labelA} → ${labelB}</b>`;
  const body = rows.map(r => {
    const iface = r['Interface'] || 'N/A';
    const rx = r['RX Level'] || 'N/A';
    const thr = r['RX Threshold'] || 'N/A';
    const oper = r['Oper Status'] || 'N/A';
    const ip = r['NE IP'] || '';
    const link = ip ? `<a href="http://${ip}">${ip}</a>` : 'N/A';
    const rxNum = Number(rx), thrNum = Number(thr);
    const higherIsBetter = process.env.RX_HIGHER_IS_BETTER !== 'false';
    const emoji = (r['RX Level'] === '-40.00') ? '❌'
      : (Number.isNaN(rxNum) || Number.isNaN(thrNum)) ? '❓'
      : (higherIsBetter ? (rxNum > thrNum) : (rxNum < thrNum)) ? '✅' : '⚠️';
    return `• <b>${iface}</b> | RX <code>${rx}</code> | Thr <code>${thr}</code> | <i>${oper}</i> | ${link} ${emoji}`;
  }).join('\n');
  return `${head}\n${body}`;
}

function buildMoreButtons(tokenKey, labelA, labelB) {
  return {
    reply_markup: {
      inline_keyboard: [
        [{ text: `Tampilkan semua ${labelA}→${labelB}`, callback_data: `more_${tokenKey}_A` }],
        [{ text: `Tampilkan semua ${labelB}→${labelA}`, callback_data: `more_${tokenKey}_B` }]
      ]
    },
    parse_mode: 'HTML',
    disable_web_page_preview: true
  };
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
    await bot.sendMessage(msg.chat.id, '🔄 Mengecek, mohon tunggu…');

    const start = Date.now();
    const browser = await launchBrowser();
    try {
      const { sideA, sideB, labelA, labelB } = await checkMetroStatus(ne1, ne2, { browser, returnStructured: true });
      const end = Date.now();

      const tokenKey = `${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
      previewCache.set(tokenKey, { sideA, sideB, labelA, labelB, chatId: msg.chat.id, ts: Date.now() });

      // bersihkan cache lama
      for (const [k, v] of previewCache.entries()) {
        if (Date.now() - (v.ts || 0) > CACHE_TTL_MS) previewCache.delete(k);
      }

      const previewA = makePreviewHTML(sideA, labelA, labelB, 5);
      const previewB = makePreviewHTML(sideB, labelB, labelA, 5);
      const combinedPreview = `🕛 Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${previewA}\n────────────\n${previewB}`;

      addHistory(ne1, ne2, combinedPreview, name, start, end);
      await bot.sendMessage(msg.chat.id, combinedPreview, buildMoreButtons(tokenKey, labelA, labelB));
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
    return bot.sendMessage(msg.chat.id, '👉 Pilih aksi untuk setiap riwayat:', {
      reply_markup: {
        inline_keyboard: history.map((e, i) => ([
          { text: `Ulangi ${e.shortNe1} ↔ ${e.shortNe2}`, callback_data: `retry_${i}` },
          { text: `Hapus ${e.shortNe1} ↔ ${e.shortNe2}`, callback_data: `delete_${i}` }
        ]))
      }
    });
  }

  if (lower === '/start' || lower === '/help') {
    return bot.sendMessage(msg.chat.id, [
      'Hai! 👋',
      'Perintah:',
      '• /cek NE1 NE2  → cek dua arah (preview 5 baris/sisi + tombol tampilkan semua)',
      '• /history      → lihat & kelola riwayat'
    ].join('\n'));
  }

  return bot.sendMessage(msg.chat.id, '👍');
});

bot.on('callback_query', async (q) => {
  const { data, message } = q;
  await bot.answerCallbackQuery(q.id, { show_alert: false }).catch(() => {});
  try {
    if (data.startsWith('more_')) {
      const [, tokenKey, sideFlag] = data.split('_'); // more_<token>_A|B
      const entry = previewCache.get(tokenKey);
      if (!entry) return bot.sendMessage(message.chat.id, '⚠️ Data sudah kadaluarsa. Jalankan /cek lagi.');

      const { sideA, sideB, labelA, labelB } = entry;
      const html = sideFlag === 'A'
        ? _formatSideHTML(sideA, labelA, labelB)
        : _formatSideHTML(sideB, labelB, labelA);

      return bot.sendMessage(message.chat.id, html, { parse_mode: 'HTML', disable_web_page_preview: true });
    }
  } catch (e) {
    await bot.answerCallbackQuery(q.id, { text: '❌ Terjadi kesalahan. Coba lagi.', show_alert: true });
  }
});
EOF

echo "==> Install dependencies…"
npm install

# Set identitas git (lokal repo) jika belum
git config user.name >/dev/null 2>&1 || git config user.name "$GIT_NAME"
git config user.email >/dev/null 2>&1 || git config user.email "$GIT_EMAIL"

# Pastikan node_modules tidak ikut tracking
git rm -r --cached node_modules >/dev/null 2>&1 || true

echo "==> Commit & push…"
git add -A
git commit -m "feat: filter per base label + preview & tombol 'Tampilkan semua' (dua sisi)" || true
git branch -M "$BRANCH"
git push -u origin "$BRANCH"

# Restart service jika diset
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

echo "✅ Selesai. Kode diperbarui & dipush. Cek di GitHub dan coba /cek di bot."
