#!/usr/bin/env bash
set -euo pipefail
SRV="${SERVICE:-cekrsltele}"

backup() { cp -f "$1" "$1.bak_fix_$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true; }

echo "==> 1) Backup bot.js"
[ -f bot.js ] || { echo "❌ bot.js tidak ditemukan"; exit 1; }
backup bot.js

echo "==> 2) Bersihkan baris sampah yang bikin SyntaxError"
# Hapus potongan instruksi yang pernah nyangkut ke file JS
# - baris yang memuat ', lalu'
# - baris shell/komentar raw yang ikut kepaste
sed -i '/, lalu/d' bot.js
sed -i '/^# Kalau perlu rollback cepat:/d' bot.js
sed -i '/journalctl -u cekrsltele/d' bot.js
sed -i '/ls -1 bot\.js\.bak_safesender_/d' bot.js
sed -i '/cp -f "\$(ls -1 bot\.js\.bak_safesender_/d' bot.js
sed -i '/systemctl restart cekrsltele/d' bot.js

echo "==> 3) Pasang/overwrite modul sendSafe.js (pemecah pesan panjang)"
cat > sendSafe.js <<'JS'
/**
 * Patch pengirim Telegram agar aman dari "message is too long" & caption kepanjangan.
 * Pakai: const applySendSafe=require('./sendSafe'); applySendSafe(bot);
 */
module.exports = function applySendSafe(bot){
  if (!bot || typeof bot.sendMessage !== 'function') return;
  const orig = {
    sendMessage: bot.sendMessage.bind(bot),
    sendPhoto: bot.sendPhoto ? bot.sendPhoto.bind(bot) : null,
    sendDocument: bot.sendDocument ? bot.sendDocument.bind(bot) : null
  };
  const MSG_LIMIT = 4096;
  const SAFE_BODY = 3900;
  const CAPTION_LIMIT = 1024;

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
      const ex={...(extra||{})}; let cap = ex.caption?String(ex.caption):'';
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
      const ex={...(extra||{})}; let cap = ex.caption?String(ex.caption):'';
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

echo "==> 4) Pastikan applySendSafe(bot) ter‑inject setelah konstruktor TelegramBot"
node - <<'JS'
const fs=require('fs');
let s=fs.readFileSync('bot.js','utf8');
const ctor=/const\s+bot\s*=\s*new\s+TelegramBot\([^;]*\);\s*/;
if(!ctor.test(s)){ console.error('❌ Konstruktor TelegramBot tidak ditemukan di bot.js'); process.exit(1); }
if(!/applySendSafe\s*\(\s*bot\s*\)/.test(s)){
  const inj="\nconst applySendSafe=require('./sendSafe');\ntry{applySendSafe(bot);}catch(e){console.error('WARN sendSafe:',e?.message||e)}\n";
  const m=s.match(ctor); const idx=s.indexOf(m[0])+m[0].length;
  s=s.slice(0,idx)+inj+s.slice(idx);
  fs.writeFileSync('bot.js',s);
  console.log('✅ applySendSafe(bot) ditambahkan');
} else {
  console.log('ℹ️ applySendSafe(bot) sudah ada — dilewati.');
}
JS

echo "==> 5) Restart service & tampilkan log singkat"
systemctl restart "$SRV" || true
sleep 1
systemctl status "$SRV" -n 10 --no-pager || true
