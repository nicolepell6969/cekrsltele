#!/usr/bin/env bash
set -euo pipefail

SERVICE="${SERVICE:-cekrsltele}"

echo "==> Backup bot.js"
cp -f bot.js bot.js.bak_qrimg_$(date +%Y%m%d-%H%M%S) || true

echo "==> Tambah require('qrcode') jika belum ada"
if ! grep -q "require('qrcode')" bot.js; then
  # sisipkan setelah baris require lainnya
  awk '
    NR==1 { print; next }
    FNR==1 && NR==1 { print }
    { print }
  ' bot.js > bot.tmp
  mv bot.tmp bot.js
  # tambahkan import di dekat impor TelegramBot
  sed -i "0,/node-telegram-bot-api/s//node-telegram-bot-api');\nconst QR = require('qrcode');/" bot.js
  echo "   • Tambah const QR = require('qrcode');"
fi

echo "==> Patch handler QR: kirim sebagai image PNG"
node - <<'JS'
const fs = require('fs');
let s = fs.readFileSync('bot.js','utf8');

// Ganti blok ASCII QR menjadi kirim PNG
const re = /if\s*\(\s*qr\s*&&\s*notifyChatId\s*\)\s*\{[\s\S]*?\}/m;
const newBlock = `
if (qr && notifyChatId) {
  (async () => {
    try {
      const buf = await QR.toBuffer(qr, { type: 'png', scale: 8, margin: 1 });
      await bot.sendPhoto(notifyChatId, buf, { caption: '📲 Scan QR WhatsApp berikut (berlaku ~60 detik). Jika kadaluarsa, kirim /wa_pair lagi.' });
    } catch (e) {
      // Fallback ke ASCII jika pembuatan PNG gagal
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

// Jika pola lama ketemu → replace. Kalau tidak, coba selipkan kirim PNG di dalam update handler.
if (re.test(s)) {
  s = s.replace(re, newBlock);
} else {
  // Selipkan di dalam connection.update handler setelah deklarasi const { connection, lastDisconnect, qr }
  s = s.replace(
    /(sock\.ev\.on\('connection\.update',\s*\(u\)\s*=>\s*\{\s*const\s*\{\s*connection,\s*lastDisconnect,\s*qr\s*\}\s*=\s*u;\s*)/m,
    `$1\n${newBlock}\n`
  );
}

fs.writeFileSync('bot.js', s);
console.log('Patch QR image OK');
JS

echo "==> Install dependency qrcode (generator PNG)"
npm i qrcode --no-audit --no-fund

echo "==> Commit & push"
git add bot.js package.json package-lock.json 2>/dev/null || true
git commit -m "feat(wa): kirim QR WhatsApp sebagai gambar PNG ke Telegram (fallback ASCII)" || true
git pull --rebase origin main || true
git push origin main || true

echo "==> Restart service"
systemctl daemon-reload || true
systemctl restart "$SERVICE" || true
sleep 2
journalctl -u "$SERVICE" -n 40 --no-pager || true

echo "✅ Selesai. Coba dari Telegram:"
echo "   /wa_enable  (jika belum aktif)  → lalu  /wa_pair"
echo "   Kamu akan menerima QR dalam bentuk gambar PNG."
