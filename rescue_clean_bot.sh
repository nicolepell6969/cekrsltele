#!/usr/bin/env bash
set -euo pipefail
SRV="${SERVICE:-cekrsltele}"

pick_latest_backup() {
  ls -1t bot.js.bak_* 2>/dev/null | head -n1 || true
}

echo "==> 1) Cari backup bot.js yang paling baru"
LATEST="$(pick_latest_backup)"
if [[ -z "${LATEST}" ]]; then
  echo "ℹ️ Tidak ada bot.js.bak_*. Coba dari git origin/main…"
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git fetch --all --quiet || true
    if git cat-file -e origin/main:bot.js 2>/dev/null; then
      cp -f bot.js bot.js.broken_$(date +%Y%m%d-%H%M%S) 2>/dev/null || true
      git show origin/main:bot.js > bot.js
    else
      echo "❌ Tidak ada backup & origin/main:bot.js tidak ditemukan"; exit 1
    fi
  else
    echo "❌ Bukan repo git dan tidak ada backup"; exit 1
  fi
else
  echo "   -> Menggunakan: $LATEST"
  cp -f "$LATEST" bot.js
fi

echo "==> 2) Bersihkan sampah non-JS yang mungkin ikut kepaste"
# buang baris instruksi yang bukan JS
sed -i '/, lalu/d' bot.js
sed -i '/^# /d' bot.js
sed -i '/journalctl -u/d' bot.js
sed -i '/ls -1 bot\.js\.bak_/d' bot.js
sed -i '/systemctl restart/d' bot.js
# rapikan dobel ';' di require qrcode
sed -i "s/\\(require('qrcode')\\);\\{2,\\}/\\1;/" bot.js

echo "==> 3) Tulis/overwrite sendSafe.js (pengiriman aman & auto-split)"
cat > sendSafe.js <<'JS'
module.exports = function applySendSafe(bot){
  if (!bot || typeof bot.sendMessage !== 'function') return;
  const orig = {
    sendMessage: bot.sendMessage.bind(bot),
    sendPhoto: bot.sendPhoto ? bot.sendPhoto.bind(bot) : null,
    sendDocument: bot.sendDocument ? bot.sendDocument.bind(bot) : null
  };
  const SAFE_BODY = 3900;
  const CAPTION_LIMIT = 1024;

  function splitSmart(text, max=SAFE_BODY){
    const t = String(text ?? '');
    if (t.length <= max) return [t];
    const out=[]; let rest=t;
    const cut=(s,limit)=>{
      if (s.length<=limit) return [s,''];
      const seg=s.slice(0,limit);
      const a=seg.lastIndexOf('\n\n'); if(a>0) return [seg.slice(0,a), s.slice(a)];
      const b=seg.lastIndexOf('\n');  if(b>0) return [seg.slice(0,b), s.slice(b)];
      const c=seg.lastIndexOf(' ');   if(c>0) return [seg.slice(0,c), s.slice(c)];
      return [seg, s.slice(seg.length)];
    };
    while(rest.length){ const [h,t2]=cut(rest,max); if(h) out.push(h); rest=t2; }
    return out;
  }

  bot.sendLong = async (chatId, text, extra={}) => {
    const parts = splitSmart(text, SAFE_BODY); let last;
    for (const p of parts){
      const ex={...extra}; if (ex.parse_mode) delete ex.parse_mode;
      last = await orig.sendMessage(chatId, p, ex);
    }
    return last;
  };

  bot.sendMessage = async (chatId, text, extra={}) => {
    const s = String(text ?? '');
    if (s.length <= SAFE_BODY) {
      const ex={...extra}; if (s.length>SAFE_BODY-50 && ex.parse_mode) delete ex.parse_mode;
      return orig.sendMessage(chatId, s, ex);
    }
    return bot.sendLong(chatId, s, extra);
  };

  if (orig.sendPhoto){
    bot.sendPhoto = async (chatId, photo, extra={}) => {
      const ex={...(extra||{})}; const cap = ex.caption?String(ex.caption):'';
      if (cap.length > CAPTION_LIMIT){
        delete ex.caption; if (ex.parse_mode) delete ex.parse_mode;
        const res = await orig.sendPhoto(chatId, photo, ex);
        await bot.sendLong(chatId, cap, {});
        return res;
      } else {
        if (cap.length>CAPTION_LIMIT-20 && ex.parse_mode) delete ex.parse_mode;
        return orig.sendPhoto(chatId, photo, ex);
      }
    };
  }

  if (orig.sendDocument){
    bot.sendDocument = async (chatId, doc, extra={}) => {
      const ex={...(extra||{})}; const cap = ex.caption?String(ex.caption):'';
      if (cap.length > CAPTION_LIMIT){
        delete ex.caption; if (ex.parse_mode) delete ex.parse_mode;
        const res = await orig.sendDocument(chatId, doc, ex);
        await bot.sendLong(chatId, cap, {});
        return res;
      } else {
        if (cap.length>CAPTION_LIMIT-20 && ex.parse_mode) delete ex.parse_mode;
        return orig.sendDocument(chatId, doc, ex);
      }
    };
  }
};
JS

echo "==> 4) Inject applySendSafe(bot) setelah konstruktor TelegramBot (jika belum)"
node - <<'JS'
const fs=require('fs');
let s=fs.readFileSync('bot.js','utf8');
const ctor=/const\s+bot\s*=\s*new\s+TelegramBot\([^;]*\);\s*/;
if(!ctor.test(s)){ console.error('❌ Konstruktor TelegramBot tidak ditemukan'); process.exit(0); }
if(!/applySendSafe\s*\(\s*bot\s*\)/.test(s)){
  const inj="\nconst applySendSafe=require('./sendSafe');\ntry{applySendSafe(bot);}catch(e){console.error('WARN sendSafe:',e?.message||e)}\n";
  const m=s.match(ctor); const idx=s.indexOf(m[0])+m[0].length;
  s=s.slice(0,idx)+inj+s.slice(idx);
  fs.writeFileSync('bot.js',s);
  console.log('✅ applySendSafe(bot) ditambahkan');
} else {
  console.log('ℹ️ applySendSafe(bot) sudah ada');
}
JS

echo "==> 5) Pastikan handler QR WhatsApp bersih (hapus duplikat lama jika ada, lalu tulis yang benar)"
node - <<'JS'
const fs=require('fs');
let s=fs.readFileSync('bot.js','utf8');
// hapus semua blok connection.update yang lama/duplikat kacau
s=s.replace(/sock\.ev\.on\('connection\.update'[\s\S]*?\n\s*\);\s*\n/g,'');
// sisipkan blok yang benar setelah makeWASocket(...);
const anchor=/const\s+sock\s*=\s*makeWASocket\([\s\S]*?\);\s*/m;
if(anchor.test(s) && !/QR WhatsApp \(fallback ASCII\)/.test(s)){
  const cleanBlock = `
  // === WA connection.update (QR sebagai foto dengan fallback ASCII) ===
  sock.ev.on('connection.update', (u) => {
    const { connection, lastDisconnect, qr } = u;
    if (qr && notifyChatId) {
      (async () => {
        try {
          const QR = require('qrcode');
          const buf = await QR.toBuffer(qr, { type: 'png', scale: 8, margin: 1 });
          await bot.sendPhoto(notifyChatId, buf, {
            caption: '📲 Scan QR WhatsApp berikut (±60 detik). Jika kadaluarsa, kirim /wa_pair lagi.'
          });
        } catch (e) {
          try {
            const qrt = require('qrcode-terminal');
            let ascii = '';
            qrt.generate(qr, { small: true }, c => ascii = c);
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
      try { if (globalThis.waClient) globalThis.waClient = null; } catch {}
    }
  });
`;
  s=s.replace(anchor,(m)=> m + cleanBlock + '\n');
  fs.writeFileSync('bot.js',s);
  console.log('✅ QR handler bersih ditulis ulang');
} else {
  console.log('ℹ️ Anchor makeWASocket tidak ditemukan atau handler sudah bersih');
}
JS

echo "==> 6) Cek sintaks cepat"
node -e "require('./bot.js'); console.log('✅ Syntax OK')" || { echo '❌ Masih ada error sintaks'; exit 1; }

echo "==> 7) Restart service"
systemctl restart "$SRV" || true
sleep 1
systemctl status "$SRV" -n 20 -l --no-pager || true
