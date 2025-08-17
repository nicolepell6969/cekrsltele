#!/usr/bin/env bash
set -euo pipefail
SRV="${SERVICE:-cekrsltele}"

backup() { cp -f "$1" "$1.bak_doctor_$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true; }

echo "==> 1) Backup bot.js"
[ -f bot.js ] || { echo "❌ bot.js tidak ditemukan"; exit 1; }
backup bot.js

echo "==> 2) Bersihkan potongan teks non-JS yang bikin SyntaxError"
# buang sisa instruksi yang pernah kepaste ke dalam bot.js
sed -i '/, lalu/d' bot.js
sed -i '/^# /d' bot.js
sed -i '/journalctl -u/d' bot.js
sed -i '/ls -1 bot\.js\.bak_safesender_/d' bot.js
sed -i '/cp -f "\$(ls -1 bot\.js\.bak_safesender_/d' bot.js
sed -i '/systemctl restart cekrsltele/d' bot.js
# rapikan dobel tanda ; pada require qrcode
sed -i "s/\\(require('qrcode')\\);\\{2,\\}/\\1;/" bot.js

echo "==> 3) Pasang/overwrite sendSafe.js (pecah pesan panjang & caption aman)"
cat > sendSafe.js <<'JS'
module.exports = function applySendSafe(bot){
  if (!bot || typeof bot.sendMessage !== 'function') return;
  const orig = {
    sendMessage: bot.sendMessage.bind(bot),
    sendPhoto: bot.sendPhoto ? bot.sendPhoto.bind(bot) : null,
    sendDocument: bot.sendDocument ? bot.sendDocument.bind(bot) : null
  };
  const SAFE_BODY = 3900;      // < 4096 agar aman untuk parse_mode
  const CAPTION_LIMIT = 1024;  // batas caption

  function splitSmart(text, max=SAFE_BODY){
    const t = String(text ?? '');
    if (t.length <= max) return [t];
    const out=[]; let rest=t;
    const cutBy=(s,limit)=>{
      if (s.length<=limit) return [s,''];
      const seg=s.slice(0,limit);
      const a=seg.lastIndexOf('\n\n'); if(a>0) return [seg.slice(0,a), s.slice(a)];
      const b=seg.lastIndexOf('\n');  if(b>0) return [seg.slice(0,b), s.slice(b)];
      const c=seg.lastIndexOf(' ');   if(c>0) return [seg.slice(0,c), s.slice(c)];
      return [seg, s.slice(seg.length)];
    };
    while(rest.length){ const [h,t2]=cutBy(rest,max); if(h) out.push(h); rest=t2; }
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

echo "==> 4) Inject applySendSafe(bot) setelah konstruktor TelegramBot"
node - <<'JS'
const fs=require('fs');
let s=fs.readFileSync('bot.js','utf8');
const ctor=/const\s+bot\s*=\s*new\s+TelegramBot\([^;]*\);\s*/;
if(!ctor.test(s)){ console.error('❌ Konstruktor TelegramBot tidak ditemukan'); process.exit(1); }
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

echo "==> 5) Reset handler QR WhatsApp ke versi bersih (hapus duplikat/kurung nyasar)"
node - <<'JS'
const fs=require('fs');
let s=fs.readFileSync('bot.js','utf8');

const qrBlock=/sock\.ev\.on\('connection\.update'[\s\S]*?\n\s*\);\s*\n/g; // blok event lama yg berantakan
if(qrBlock.test(s)){
  s=s.replace(qrBlock,''); // buang semua yang kacau
}

// sisipkan blok yang benar setelah deklarasi 'const sock = makeWASocket({...});'
const anchor=/const\s+sock\s*=\s*makeWASocket\([\s\S]*?\);\s*/m;
if(!anchor.test(s)){ console.error('❌ Anchor makeWASocket tidak ditemukan'); process.exit(0); }

const cleanBlock = `
  // === WA connection.update (QR sebagai foto dengan fallback ASCII) ===
  sock.ev.on('connection.update', (u) => {
    const { connection, lastDisconnect, qr } = u;

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
console.log('✅ QR handler dibersihkan & ditulis ulang');
JS

echo "==> 6) Tes sintaks cepat via node"
node -e "require('./bot.js')" >/dev/null 2>&1 || true

echo "==> 7) Restart service & tampilkan log ringkas"
systemctl restart "$SRV" || true
sleep 1
systemctl status "$SRV" -n 15 -l --no-pager || true
