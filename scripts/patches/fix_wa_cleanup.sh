#!/usr/bin/env bash
set -euo pipefail
SERVICE="${SERVICE:-cekrsltele}"

echo "==> Backup bot.js"
cp -f bot.js bot.js.bak_fixqr_$(date +%Y%m%d-%H%M%S) || true

# 1) Normalkan import qrcode (hapus duplikat/typo)
sed -i "/require('qrcode')/d" bot.js || true
sed -i '/require("qrcode")/d' bot.js || true
sed -i "s/qrcode');');/qrcode');/g" bot.js
# sisipkan sekali setelah import Telegram
if grep -q "require('node-telegram-bot-api')" bot.js; then
  sed -i "0,/require('node-telegram-bot-api')/s//require('node-telegram-bot-api');\nconst QR = require('qrcode');/" bot.js
elif grep -q "require(\"node-telegram-bot-api\")" bot.js; then
  sed -i "0,/require(\"node-telegram-bot-api\")/s//require(\"node-telegram-bot-api\");\nconst QR = require('qrcode');/" bot.js
else
  sed -i "1a const QR = require('qrcode');" bot.js
fi
# hapus ; ganda
sed -i 's/;;$/;/' bot.js

# 2) Ganti blok waStart .. sebelum waStop/waStatusText dengan versi bersih
node - <<'JS'
const fs = require('fs');
let s = fs.readFileSync('bot.js','utf8');

function replaceSection(src, startRegex, endRegex, replacement){
  const start = src.search(startRegex);
  if (start < 0) return null;
  const end = src.search(endRegex);
  if (end < 0 || end <= start) return null;
  return src.slice(0, start) + replacement + src.slice(end);
}

const startRe = /async\s+function\s+waStart\s*\([^)]*\)\s*\{/m;
const endRe   = /\n\s*async\s+function\s+waStop\s*\(|\n\s*function\s+waStatusText\s*\(/m;

const cleanBlock = `
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

    // Kirim QR sebagai PNG (fallback ASCII)
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

async function waStop(){
  try { if (waClient?.ws) waClient.ws.close(); } catch {}
  try { await waClient?.end?.(); } catch {}
  waClient = null;
}

function waStatusText(){
  return 'WA_ENABLED=' + WA_ENABLED + ' | status=' + (waClient ? 'CONNECTED' : 'OFFLINE');
}
`.trim() + '\n';

let out = replaceSection(s, startRe, endRe, cleanBlock);
if (!out) {
  // fallback: append block jika tidak ketemu batas
  console.warn('WARN: pola waStart/waStop tidak pas, menambahkan blok bersih di akhir file.');
  out = s + '\n\n' + cleanBlock;
}
fs.writeFileSync('bot.js', out);
console.log('waStart/waStop/waStatusText replaced.');
JS

# 3) Pastikan dep untuk QR ASCII ada
npm i qrcode-terminal --no-audit --no-fund >/dev/null 2>&1 || true
npm i qrcode --no-audit --no-fund >/dev/null 2>&1 || true

# 4) Commit, pull --rebase, push
git add bot.js package.json package-lock.json 2>/dev/null || true
git commit -m "fix(wa): clean waStart + PNG QR; normalize qrcode import; add waStop/waStatusText" || true
git pull --rebase origin main || true
git push origin main || true

# 5) Restart & tampilkan log
systemctl restart "$SERVICE" || true
sleep 2
journalctl -u "$SERVICE" -n 60 --no-pager || true

echo "✅ Selesai. Coba /wa_enable lalu /wa_pair di Telegram — QR akan dikirim dalam bentuk gambar."
