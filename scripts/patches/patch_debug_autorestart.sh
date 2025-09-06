#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(pwd)"
SERVICE="${SERVICE:-cekrsltele}"

echo "==> 1) Backup bot.js"
cp -f bot.js bot.js.bak_debug_$(date +%Y%m%d-%H%M%S) || true

echo "==> 2) Pastikan .env punya ADMIN_IDS (tidak menimpa nilai jika sudah ada)"
touch .env
if ! grep -q '^ADMIN_IDS=' .env; then
  echo 'ADMIN_IDS=' >> .env
fi

echo "==> 3) Patch bot.js: tambah helper sendToAdmins + global error handlers"
node - <<'JS'
const fs = require('fs');
let s = fs.readFileSync('bot.js','utf8');

// Cari inisialisasi bot Telegram
const needleBotInit = /const bot\s*=\s*new\s+TelegramBot\([^)]*\);\s*/;
if (!needleBotInit.test(s)) {
  console.error('❌ Tidak menemukan inisialisasi Telegram bot di bot.js');
  process.exit(1);
}

// Tambah helper sendToAdmins setelah bot dibuat (jika belum ada)
if (!/async function sendToAdmins\(/.test(s)) {
  s = s.replace(needleBotInit, (m) => m + `

// === Helper: kirim pesan ke semua admin dari ENV ADMIN_IDS atau adminStore ===
async function sendToAdmins(text, opts = {}) {
  try {
    let ids = [];
    try {
      if (adminStore?.listAdmins) ids = adminStore.listAdmins().map(String);
    } catch {}
    if (!ids.length) {
      ids = String(process.env.ADMIN_IDS || '')
        .split(',')
        .map(v => v.trim())
        .filter(Boolean);
    }
    // fallback: kirim ke chat terakhir yang memulai bot (jika ada) — abaikan jika tidak ada.
    if (!ids.length && typeof lastChatId !== 'undefined' && lastChatId) {
      ids = [String(lastChatId)];
    }
    for (const id of ids) {
      try { await bot.sendMessage(id, text, opts); } catch {}
    }
  } catch {}
}
`);
}

// Simpan chatId terakhir untuk fallback notifikasi (opsional, ringan)
if (!/let lastChatId/.test(s)) {
  s = s.replace(/bot\.on\('message',\s*\(msg\)\s*=>\s*\{/, `bot.on('message', (msg) => { try { lastChatId = msg.chat?.id || lastChatId;`);
  // tutup try di akhir handler message jika belum ada
  s = s.replace(/bot\.on\('message',[\s\S]*?\}\);\s*$/m, (m) => {
    if (m.includes('} catch')) return m; // sudah di-wrap try/catch sebelumnya
    return m.replace(/\}\);\s*$/, `} catch (e) { try { sendToAdmins('⚠️ Error di handler /message: ' + (e?.message||e)); } catch {} } });\n`);
  });
}

// Tambahkan global error handlers (jika belum ada)
const guardText = '// === global error handlers: kirim error ke admin & exit agar systemd restart ===';
if (!s.includes(guardText)) {
  s += `

${guardText}
process.on('unhandledRejection', async (err) => {
  try { await sendToAdmins('❗ *UnhandledRejection*\\n' + (err?.stack || err)); } catch {}
  // tidak exit, biar lanjut jalan
});
process.on('uncaughtException', async (err) => {
  try { await sendToAdmins('❗ *UncaughtException*\\n' + (err?.stack || err)); } catch {}
  // exit biar systemd auto-restart
  setTimeout(() => process.exit(1), 500);
});
`;
}

fs.writeFileSync('bot.js', s);
console.log('✔️ bot.js patched.');
JS

echo "==> 4) Perbaiki unit systemd agar auto-restart (tanpa key invalid)"
sudo mkdir -p /etc/systemd/system/${SERVICE}.service.d
cat | sudo tee /etc/systemd/system/${SERVICE}.service.d/override-restart.conf >/dev/null <<'UNIT'
[Service]
Restart=always
RestartSec=5
# Hapus kunci yang tidak valid dari override sebelumnya
StartLimitIntervalSec=
StartLimitBurst=
UNIT

echo "==> 5) Reload daemon & restart service"
sudo systemctl daemon-reload
sudo systemctl restart ${SERVICE}
sleep 1
echo "==> 6) Tampilkan log terakhir"
journalctl -u ${SERVICE} -n 30 --no-pager || true

echo "✅ Selesai. Error runtime akan dikirim ke DM admin (ADMIN_IDS / admins.json)."
