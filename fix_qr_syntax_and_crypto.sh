#!/usr/bin/env bash
set -euo pipefail

SERVICE="${SERVICE:-cekrsltele}"

echo "==> Backup bot.js"
cp -f bot.js bot.js.bak_qr_syntax_$(date +%Y%m%d-%H%M%S) 2>/dev/null || true

# 1) Sisipkan Web Crypto shim di paling atas (sekali saja)
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
  echo "   • Web Crypto shim ditambahkan."
else
  echo "   • Web Crypto shim sudah ada, lewati."
fi

# 2) Bersihkan import qrcode yang salah & duplikat
#    - hapus semua require('qrcode') yang ada (benar/salah), nanti tambah sekali yang benar.
sed -i "/require('qrcode')/d" bot.js || true
sed -i '/require("qrcode")/d' bot.js || true
#    - bersihkan typo khusus: qrcode');');
sed -i "s/qrcode');');/qrcode');/g" bot.js
#    - tambahkan import qrcode tepat setelah import node-telegram-bot-api
if grep -q "require('node-telegram-bot-api')" bot.js; then
  sed -i "0,/require('node-telegram-bot-api')/s//require('node-telegram-bot-api');\nconst QR = require('qrcode');/" bot.js
elif grep -q "require(\"node-telegram-bot-api\")" bot.js; then
  sed -i "0,/require(\"node-telegram-bot-api\")/s//require(\"node-telegram-bot-api\");\nconst QR = require('qrcode');/" bot.js
else
  sed -i "1a const QR = require('qrcode');" bot.js
fi

# 3) Hapus baris nyasar yang cuma berisi ');' (umum terjadi dari patch sebelumnya)
#    (hanya untuk 200 baris pertama agar aman)
awk 'NR<=200 && $0 ~ /^[[:space:]]*\);\s*$/ {next} {print}' bot.js > bot.js.tmp && mv bot.js.tmp bot.js

# 4) Pastikan handler QR pakai PNG (fallback ASCII)
node - <<'JS'
const fs = require('fs');
let s = fs.readFileSync('bot.js','utf8');

const pngBlock = `
if (qr && notifyChatId) {
  (async () => {
    try {
      const buf = await QR.toBuffer(qr, { type: 'png', scale: 8, margin: 1 });
      await bot.sendPhoto(notifyChatId, buf, {
        caption: '📲 Scan QR WhatsApp berikut (±60 detik). Jika kadaluarsa, kirim /wa_pair lagi.'
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

// Replace blok lama if (qr && notifyChatId) { ... }
const re = /if\s*\(\s*qr\s*&&\s*notifyChatId\s*\)\s*\{[\s\S]*?\}\s*/m;
if (re.test(s)) {
  s = s.replace(re, pngBlock);
} else {
  // selipkan ke dalam connection.update jika belum ada
  const hook = /(sock\.ev\.on\('connection\.update',\s*\(u\)\s*=>\s*\{\s*const\s*\{\s*connection,\s*lastDisconnect,\s*qr\s*\}\s*=\s*u;\s*)/m;
  if (hook.test(s)) s = s.replace(hook, `$1\n${pngBlock}\n`);
}

fs.writeFileSync('bot.js', s);
console.log('QR handler PNG patch: OK');
JS

# 5) Install dep qrcode
npm i qrcode --no-audit --no-fund

# 6) Commit & push
git add bot.js package.json package-lock.json 2>/dev/null || true
git commit -m "fix(wa): perbaiki import qrcode; hapus ');' nyasar; QR PNG + crypto shim" || true
git pull --rebase origin main || true
git push origin main || true

# 7) Restart service
systemctl daemon-reload || true
systemctl restart "$SERVICE" || true
sleep 2
journalctl -u "$SERVICE" -n 60 --no-pager || true

echo "✅ Selesai. Coba dari Telegram: /wa_enable lalu /wa_pair — QR akan terkirim sebagai gambar."
