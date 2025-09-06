#!/usr/bin/env bash
set -euo pipefail

SERVICE="${SERVICE:-cekrsltele}"

echo "==> Backup bot.js"
cp -f bot.js bot.js.bak_qr_fix_$(date +%Y%m%d-%H%M%S) 2>/dev/null || true

echo "==> 1) Sisipkan Web Crypto shim di baris paling atas (sekali saja)"
if ! grep -q "CRYPTO SHIM for Baileys" bot.js; then
  cat > .shim.js <<'JS'
// === CRYPTO SHIM for Baileys (WhatsApp) ===
(() => {
  try {
    const nodeCrypto = require('node:crypto');
    if (!globalThis.crypto) {
      globalThis.crypto = nodeCrypto.webcrypto || nodeCrypto;
    }
  } catch (e) {
    try {
      const c = require('crypto');
      if (!globalThis.crypto) globalThis.crypto = c;
    } catch {}
  }
})();
JS
  cat .shim.js bot.js > bot.js.new && mv bot.js.new bot.js && rm -f .shim.js
  echo "   • Shim ditambahkan."
else
  echo "   • Shim sudah ada, lewati."
fi

echo "==> 2) Perbaiki import qrcode yang salah & pastikan hanya sekali"
# Hapus semua baris import qrcode yang ada (yang benar/salah), nanti kita tambah 1x yang benar.
sed -i "/require('qrcode')/d" bot.js
sed -i '/require("qrcode")/d' bot.js
# Tambahkan import qrcode tepat setelah import node-telegram-bot-api
# Pola yang kita cari: const TelegramBot = require('node-telegram-bot-api');
if grep -q "require('node-telegram-bot-api')" bot.js; then
  sed -i "0,/require('node-telegram-bot-api')/s//require('node-telegram-bot-api');\nconst QR = require('qrcode');/" bot.js
elif grep -q "require(\"node-telegram-bot-api\")" bot.js; then
  sed -i "0,/require(\"node-telegram-bot-api\")/s//require(\"node-telegram-bot-api\");\nconst QR = require('qrcode');/" bot.js
else
  # Kalau tidak ketemu, sisipkan di baris ke-1 setelah shim
  sed -i "1a const QR = require('qrcode');" bot.js
fi
# Jika ada kasus salah ketik sebelumnya "qrcode');');", bersihkan juga (jaga-jaga)
sed -i "s/qrcode');');/qrcode');/g" bot.js

echo "==> 3) Patch handler QR: kirim sebagai PNG, fallback ASCII"
node - <<'JS'
const fs = require('fs');
let s = fs.readFileSync('bot.js','utf8');

// Block yang kirim QR sebagai PNG via Telegram
const newBlock = `
if (qr && notifyChatId) {
  (async () => {
    try {
      const buf = await QR.toBuffer(qr, { type: 'png', scale: 8, margin: 1 });
      await bot.sendPhoto(notifyChatId, buf, {
        caption: '📲 Scan QR WhatsApp berikut (berlaku ~60 detik). Jika kadaluarsa, kirim /wa_pair lagi.'
      });
    } catch (e) {
      try {
        const qrt = require('qrcode-terminal');
        let ascii=''; qrt.generate(qr,{small:true}, c=>ascii=c);
        await bot.sendMessage(notifyChatId, 'QR WhatsApp (fallback ASCII):\\n\\n'+ascii);
      } catch (e2) {
        await bot.sendMessage(notifyChatId, 'Gagal membuat QR image: ' + (e && e.message ? e.message : e));
      }
    }
  })();
}
`;

// Coba replace pola lama "if (qr && notifyChatId) { ... }"
const re = /if\s*\(\s*qr\s*&&\s*notifyChatId\s*\)\s*\{[\s\S]*?\}\s*/m;
if (re.test(s)) {
  s = s.replace(re, newBlock);
} else {
  // Selipkan di dalam connection.update handler setelah deklarasi const { connection, lastDisconnect, qr }
  const hook = /(sock\.ev\.on\('connection\.update',\s*\(u\)\s*=>\s*\{\s*const\s*\{\s*connection,\s*lastDisconnect,\s*qr\s*\}\s*=\s*u;\s*)/m;
  if (hook.test(s)) s = s.replace(hook, `$1\n${newBlock}\n`);
}

fs.writeFileSync('bot.js', s);
console.log('QR patch OK');
JS

echo "==> 4) Install dependency qrcode"
npm i qrcode --no-audit --no-fund

echo "==> 5) Commit & push"
git add bot.js package.json package-lock.json 2>/dev/null || true
git commit -m "fix(wa): QR as PNG + Web Crypto shim; clean qrcode import" || true
git pull --rebase origin main || true
git push origin main || true

echo "==> 6) Restart service"
systemctl daemon-reload || true
systemctl restart "$SERVICE" || true
sleep 2
journalctl -u "$SERVICE" -n 50 --no-pager || true

echo "✅ Selesai. Di Telegram jalankan: /wa_enable → /wa_pair (QR akan dikirim sebagai gambar)."

echo
echo "ℹ️ Opsional: peringatan systemd 'StartLimitIntervalSec' muncul karena opsi itu bukan bagian [Service]."
echo "   Jika mau, pindahkan ke [Unit] atau hapus. Contoh unit yang rapi:"
echo
cat <<'UNIT'
[Unit]
Description=cekrsltele unified bot (Telegram + WhatsApp)
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
WorkingDirectory=/root/cekrsltele
Environment=NODE_ENV=production
ExecStart=/usr/bin/node bot.js
Restart=always
RestartSec=5
# Limits agar Puppeteer/WA punya waktu
TimeoutStartSec=90
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
UNIT
