#!/usr/bin/env bash
set -euo pipefail

SERVICE="${SERVICE:-cekrsltele}"

echo "==> Backup bot.js"
cp -f bot.js bot.js.bak_fix1ne_$(date +%Y%m%d-%H%M%S) 2>/dev/null || true

echo "==> Patch bot.js (perbaikan /cek 1 NE + guard command + log)"
node - <<'JS' > .apply.js
const fs=require('fs'); let s=fs.readFileSync('bot.js','utf8');

// 1) Guard: terima /cek diikuti spasi/akhir baris (bukan hanya "startsWith('/cek ')")
s = s.replace(/if\s*\(\s*low\.startsWith\('\\/cek '\)\s*\)\s*\{/,
  `if (/^\\/cek(\\s+|$)/.test(low)) {`);

// 2) Di dalam blok /cek → parsing argumen yang lebih robust (multispasi / newline)
s = s.replace(/const parts = text\.split\(' '\)\.slice\(1\)\.map\(s => s\.trim\(\)\)\.filter\(Boolean\);/,
  `const tail = text.slice(4); // hapus '/cek'
   const parts = tail.split(/\\s+/).map(x=>x.trim()).filter(Boolean);`);

// 3) Pastikan 1 NE SELALU membalas (result / error / timeout)
if (!/cek satu NE:/.test(s) || !/runWithTimeout\(checkMetroStatus\.checkSingleNE/.test(s)) {
  // cari blok 1 NE dan ganti total
  s = s.replace(/\/\/ 1 NE[\s\S]*?return bot\.sendMessage\(chatId,[\s\S]*?\);\n\s*\}/m,
`// 1 NE
if (parts.length === 1) {
  const ne = parts[0];
  await bot.sendMessage(chatId, 'Cek satu NE: ' + ne + ' ...');
  try {
    const start = Date.now();
    // timeout 90s supaya tidak gantung
    const result = await runWithTimeout(
      checkMetroStatus && checkMetroStatus.checkSingleNE
        ? checkMetroStatus.checkSingleNE(ne)
        : Promise.reject(new Error('checkMetroStatus.checkSingleNE tidak tersedia')),
      90000,
      'cek-1NE'
    );
    const end = Date.now();
    addHistory(ne, null, result, ne, start, end);
    return bot.sendMessage(chatId,
      'Checked Time: ' + new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' }) + '\\n\\n' + (result || '(tidak ada data diterima)')
    );
  } catch (e) {
    // SELALU BALAS meskipun error
    return bot.sendMessage(chatId, 'Gagal cek 1 NE: ' + (e && e.message ? e.message : String(e)));
  }
}
`);
}

// 4) Tambah logging kecil ketika masuk /cek (sekali saja)
if (!/console\.log\(\s*'\\[LOG\\] cek cmd'/.test(s)) {
  s = s.replace(/if\s*\(\/^\\\/cek\(\S*?\)\.test\(low\)\)\s*\{/,
    `if (/^\\/cek(\\s+|$)/.test(low)) {
  try { console.log('[LOG] cek cmd text="%s"', text); } catch {}
`);
}

// 5) Unknown command warning — biarkan seperti ada, tidak perlu ubah

process.stdout.write(s);
JS
node .apply.js > bot.js.new && mv bot.js.new bot.js && rm -f .apply.js

echo "==> Tambah ADMIN_IDS ke .env bila belum & seed adminStore"
if [ ! -f .env ]; then
  echo -e "TELEGRAM_BOT_TOKEN=\nWA_ENABLED=false\nADMIN_IDS=\n" > .env
else
  grep -q '^ADMIN_IDS=' .env || echo 'ADMIN_IDS=' >> .env
fi

# Seed adminStore lewat node (tidak mengubah bot.js)
node - <<'JS' || true
try {
  require('dotenv').config({ path: __dirname + '/.env' });
  const s = require('./adminStore'); s.seedFromEnv();
  console.log('Seed admin dari .env -> admins.json OK');
} catch (e) { console.log('Seed admin dilewati:', e.message); }
JS

echo "==> Install puppeteer bila belum (untuk 1 NE juga butuh)"
node -e "require('puppeteer')" 2>/dev/null || npm i puppeteer@^22 --no-audit --no-fund

echo "==> Commit & push"
git add bot.js .env package.json package-lock.json admins.json 2>/dev/null || true
git commit -m "fix: robust /cek 1 NE parsing & guaranteed reply; add ADMIN_IDS seed" || true
git pull --rebase origin main || true
git push origin main || true

echo "==> Restart service"
systemctl daemon-reload || true
systemctl restart "$SERVICE" || true
sleep 1
journalctl -u "$SERVICE" -n 20 --no-pager || true

echo "✅ Selesai. Coba kirim: /cek SBY-PRMJ-OPT-H910D"
echo "   Jika masih diam, kirim log terakhir: journalctl -u $SERVICE -n 40 --no-pager"
