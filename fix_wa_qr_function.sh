#!/usr/bin/env bash
set -euo pipefail
SERVICE="${SERVICE:-cekrsltele}"

echo "==> Backup bot.js"
cp -f bot.js bot.js.bak_fixwa_$(date +%Y%m%d-%H%M%S) || true

# 1) Pastikan crypto shim ada (biarin kalau sudah ada)
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
  echo "   • Web Crypto shim sudah ada."
fi

# 2) Bersihkan & normalkan import qrcode (hapus duplikat/typo, pasang sekali saja)
sed -i "/require('qrcode')/d" bot.js || true
sed -i '/require("qrcode")/d' bot.js || true
# hapus typo lama jika ada
sed -i "s/qrcode');');/qrcode');/g" bot.js
# tambah import qrcode tepat setelah import Telegram
if grep -q "require('node-telegram-bot-api')" bot.js; then
  sed -i "0,/require('node-telegram-bot-api')/s//require('node-telegram-bot-api');\nconst QR = require('qrcode');/" bot.js
elif grep -q "require(\"node-telegram-bot-api\")" bot.js; then
  sed -i "0,/require(\"node-telegram-bot-api\")/s//require(\"node-telegram-bot-api\");\nconst QR = require('qrcode');/" bot.js
else
  sed -i "1a const QR = require('qrcode');" bot.js
fi
# ganti ';;' jadi ';'
sed -i 's/;\\s*;$/;/' bot.js

# 3) Ganti SELURUH fungsi waStart dengan versi bersih
node - <<'JS'
const fs = require('fs');
let s = fs.readFileSync('bot.js','utf8');

const re = /async\s+function\s+waStart\s*\([^)]*\)\s*\{[\s\S]*?\n\}/m;
const clean = `
async function waStart(notifyChatId){
  if (waClient || !makeWASocket) return;
  const { state, saveCreds } = await useMultiFileAuthState(__dirname + '/wa_auth');
  let version = [2,3000,0];
  try { ({ version } = await fetchLatestBaileysVersion()); } catch {}

  const sock = makeWASocket({
    version,
    auth: state,
    printQRInTerminal: false,
    syncFullHistory: false,
    browser: ['cekrsltele','Chrome','1.0']
  });

  waClient = sock;
  sock.ev.on('creds.update', saveCreds);

  sock.ev.on('connection.update', (u) => {
    const { connection, lastDisconnect, qr } = u;

    // Kirim QR sebagai gambar (fallback ASCII)
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
            let ascii = ''; qrt.generate(qr, { small: true }, c => ascii = c);
            await bot.sendMessage(notifyChatId, 'QR WhatsApp (fallback ASCII):\\n\\n' + ascii);
          } catch (e2) {
            await bot.sendMessage(notifyChatId, 'Gagal membuat QR image: ' + (e && e.message ? e.message : e));
          }
        }
      })();
    }

    if (connection === 'open') {
      if (notifyChatId) bot.sendMessage(notifyChatId, '✅ WhatsApp tersambung.');
    } else if (connection === 'close') {
      const reason = (lastDisconnect && lastDisconnect.error && lastDisconnect.error.message) || 'Terputus';
      if (notifyChatId) bot.sendMessage(notifyChatId, '⚠️ WhatsApp terputus: ' + reason);
      waClient = null;
    }
  });
}
`.trim();

if (re.test(s)) {
  s = s.replace(re, clean);
} else {
  // kalau tidak ketemu (struktur berbeda), coba sisipkan menggantikan definisi lama dengan cara kasar:
  const anchor = s.indexOf('async function waStart(');
  if (anchor >= 0) {
    // cari braket penutup kasar
    const tail = s.slice(anchor);
    const closeIdx = tail.indexOf('\n}');
    if (closeIdx > -1) {
      s = s.slice(0, anchor) + clean + s.slice(anchor + closeIdx + 2);
    } else {
      // append saja
      s += '\n\n' + clean + '\n';
    }
  } else {
    s += '\n\n' + clean + '\n';
  }
}

fs.writeFileSync('bot.js', s);
console.log('waStart() replaced with clean version.');
JS

# 4) Hapus baris ‘);’ nyasar di 200 baris pertama (jika masih ada)
awk 'NR<=200 && $0 ~ /^[[:space:]]*\);\s*$/ {next} {print}' bot.js > bot.js.tmp && mv bot.js.tmp bot.js

# 5) Install dep qrcode (kalau belum)
npm i qrcode --no-audit --no-fund

# 6) Commit & push
git add bot.js package.json package-lock.json 2>/dev/null || true
git commit -m "fix(wa): replace waStart with clean QR-PNG handler; normalize qrcode import; keep crypto shim" || true
git pull --rebase origin main || true
git push origin main || true

# 7) Restart service dan tampilkan log
systemctl daemon-reload || true
systemctl restart "$SERVICE" || true
sleep 2
journalctl -u "$SERVICE" -n 80 --no-pager || true

echo "✅ Selesai. Di Telegram jalankan: /wa_enable lalu /wa_pair (QR akan dikirim sebagai gambar)."
