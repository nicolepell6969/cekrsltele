#!/usr/bin/env bash
set -euo pipefail

SERVICE="${SERVICE:-cekrsltele}"

echo "==> Backup bot.js"
cp -f bot.js bot.js.bak_chunk_$(date +%Y%m%d-%H%M%S) 2>/dev/null || true

echo "==> Sisipkan monkey-patch bot.sendMessage agar auto chunk"
node - <<'JS'
const fs = require('fs');
let s = fs.readFileSync('bot.js', 'utf8');

// cari baris pembuatan bot
const reMakeBot = /(const\s+bot\s*=\s*new\s+TelegramBot\([^;]*\);\s*)/;
const m = s.match(reMakeBot);
if (!m) {
  console.error('❌ Tidak ketemu konstruktor TelegramBot di bot.js');
  process.exit(1);
}
const insertAt = s.indexOf(m[0]) + m[0].length;

// patch code: override sendMessage untuk pecah otomatis
const patch = `

// === Force-safe long message sender ===
(function attachSafeSender(){
  try{
    const origSend = bot.sendMessage.bind(bot);

    function splitSmart(text, max=3900){
      const t = String(text ?? '');
      if (t.length <= max) return [t];

      // coba pecah di \n\n
      const chunks = [];
      let rest = t;
      const push = (str)=>{ if (str && str.length) chunks.push(str); };

      function takeUntil(boundaryRegex){
        let out = '';
        while (rest.length){
          if (out.length + rest.length <= max){ out += rest; rest = ''; break; }
          // cari boundary terdekat sebelum max
          const slice = rest.slice(0, max - out.length);
          let cut = slice.search(boundaryRegex);
          if (cut === -1){ // tidak ketemu boundary; coba cari last newline/space
            const lastNl = slice.lastIndexOf('\\n');
            const lastSp = slice.lastIndexOf(' ');
            cut = Math.max(lastNl, lastSp);
            if (cut <= 0) cut = slice.length; // terpaksa hard-cut
          }
          out += slice.slice(0, cut);
          rest = rest.slice(cut);
          break;
        }
        return out;
      }

      // strategi: ambil blok demi blok dengan preferensi \n\n, lalu \n, lalu spasi
      while (rest.length){
        let part = '';
        // 1) coba \n\n
        part = takeUntil(/\n\n(?![\s\S])/); // dummy regex untuk masuk ke fallback
        if (part.length === 0) part = rest.slice(0, Math.min(max, rest.length)), rest = rest.slice(part.length);

        // kalau masih terlalu panjang, pecah lagi di \n atau spasi
        if (part.length > max){
          let p = part.slice(0, max);
          const lastNl = p.lastIndexOf('\\n');
          const lastSp = p.lastIndexOf(' ');
          const cut = Math.max(lastNl, lastSp, 0) || p.length;
          push(p.slice(0, cut));
          rest = part.slice(cut) + rest;
        } else {
          push(part);
        }
      }
      // bersihkan potongan kosong
      return chunks.map(c => c).filter(Boolean);
    }

    // expose helper opsional
    bot.sendLong = async (chatId, text, extra={}) => {
      const parts = splitSmart(text, 3900);
      let last;
      for (const p of parts){
        // hindari error parse_mode karena potongan tidak sinkron
        const safeExtra = { ...extra };
        if (safeExtra.parse_mode) delete safeExtra.parse_mode;
        last = await origSend(chatId, p, safeExtra);
      }
      return last;
    };

    // Monkey-patch: semua pemanggilan sendMessage lewat pemecah
    bot.sendMessage = async (chatId, text, extra={}) => {
      if (typeof text !== 'string') return origSend(chatId, text, extra);
      const parts = splitSmart(text, 3900);
      if (parts.length === 1){
        // kirim biasa (hapus parse_mode bila mendekati limit)
        const safeExtra = { ...extra };
        if (text.length > 3800 && safeExtra.parse_mode) delete safeExtra.parse_mode;
        return origSend(chatId, text, safeExtra);
      }
      let last;
      for (const p of parts){
        const safeExtra = { ...extra };
        if (safeExtra.parse_mode) delete safeExtra.parse_mode;
        last = await origSend(chatId, p, safeExtra);
      }
      return last;
    };
  }catch(e){
    console.error('WARN attachSafeSender:', e && e.message ? e.message : e);
  }
})();
`;

const out = s.slice(0, insertAt) + patch + s.slice(insertAt);
fs.writeFileSync('bot.js', out);
console.log('✅ Monkey-patch sendMessage terpasang.');
JS

echo "==> Restart service"
systemctl restart "$SERVICE" || true
sleep 1
systemctl status "$SERVICE" -n 5 --no-pager || true
