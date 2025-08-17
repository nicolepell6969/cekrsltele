#!/usr/bin/env bash
set -euo pipefail
SERVICE="${SERVICE:-cekrsltele}"

backup_file() {
  local f="$1"
  cp -f "$f" "$f.bak_safesender_$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
}

echo "==> 1) Backup bot.js"
backup_file bot.js

echo "==> 2) Tambah modul sendSafe.js"
cat > sendSafe.js <<'JS'
/**
 * Patch pengirim Telegram agar aman dari "message is too long" dan caption kepanjangan.
 * Cara pakai (di bot.js): const applySendSafe=require('./sendSafe'); applySendSafe(bot);
 */
module.exports = function applySendSafe(bot){
  if (!bot || typeof bot.sendMessage !== 'function') return;

  const orig = {
    sendMessage: bot.sendMessage.bind(bot),
    sendPhoto: bot.sendPhoto ? bot.sendPhoto.bind(bot) : null,
    sendDocument: bot.sendDocument ? bot.sendDocument.bind(bot) : null
  };

  const MSG_LIMIT = 4096;     // hard limit dari Telegram
  const SAFE_BODY = 3900;     // sedikit di bawah limit
  const CAPTION_LIMIT = 1024; // caption aman untuk photo/doc (Telegram max 1024)

  function splitSmart(text, max=SAFE_BODY){
    const t = String(text ?? '');
    if (t.length <= max) return [t];

    const out = [];
    let rest = t;

    const cutBy = (s, limit) => {
      if (s.length <= limit) return [s, ''];
      // prioritas: \n\n -> \n -> spasi -> hard cut
      const seg = s.slice(0, limit);
      const c1 = seg.lastIndexOf('\n\n');
      if (c1 > 0) return [seg.slice(0, c1), s.slice(c1)];
      const c2 = seg.lastIndexOf('\n');
      if (c2 > 0) return [seg.slice(0, c2), s.slice(c2)];
      const c3 = seg.lastIndexOf(' ');
      if (c3 > 0) return [seg.slice(0, c3), s.slice(c3)];
      return [seg, s.slice(seg.length)];
    };

    while (rest.length){
      const [head, tail] = cutBy(rest, max);
      if (head) out.push(head);
      rest = tail;
    }
    return out;
  }

  // Helper publik bila ingin dipanggil manual
  bot.sendLong = async (chatId, text, extra={}) => {
    const parts = splitSmart(text, SAFE_BODY);
    let last;
    for (const p of parts){
      const ex = { ...extra };
      if (ex.parse_mode) delete ex.parse_mode; // hindari error potongan Markdown
      last = await orig.sendMessage(chatId, p, ex);
    }
    return last;
  };

  // Monkey patch sendMessage
  bot.sendMessage = async (chatId, text, extra={}) => {
    const s = String(text ?? '');
    if (s.length <= SAFE_BODY) {
      // jika mendekati batas, buang parse_mode
      const ex = { ...extra };
      if (s.length > SAFE_BODY - 50 && ex.parse_mode) delete ex.parse_mode;
      return orig.sendMessage(chatId, s, ex);
    }
    return bot.sendLong(chatId, s, extra);
  };

  // Patch sendPhoto: jaga caption
  if (orig.sendPhoto) {
    bot.sendPhoto = async (chatId, photo, extra={}) => {
      const ex = { ...(extra||{}) };
      let caption = ex.caption ? String(ex.caption) : '';
      if (caption.length > CAPTION_LIMIT) {
        const parts = splitSmart(caption, SAFE_BODY);
        // kirim foto tanpa caption dulu
        delete ex.caption;
        if (ex.parse_mode) delete ex.parse_mode;
        const res = await orig.sendPhoto(chatId, photo, ex);
        // kirim caption panjang sebagai teks pecahan
        await bot.sendLong(chatId, parts.join(''), {});
        return res;
      } else {
        if (caption.length > CAPTION_LIMIT - 20 && ex.parse_mode) delete ex.parse_mode;
        if (caption.length > CAPTION_LIMIT) ex.caption = caption.slice(0, CAPTION_LIMIT);
        return orig.sendPhoto(chatId, photo, ex);
      }
    };
  }

  // Patch sendDocument: jaga caption
  if (orig.sendDocument) {
    bot.sendDocument = async (chatId, doc, extra={}) => {
      const ex = { ...(extra||{}) };
      let caption = ex.caption ? String(ex.caption) : '';
      if (caption.length > CAPTION_LIMIT) {
        delete ex.caption;
        if (ex.parse_mode) delete ex.parse_mode;
        const res = await orig.sendDocument(chatId, doc, ex);
        await bot.sendLong(chatId, caption, {});
        return res;
      } else {
        if (caption.length > CAPTION_LIMIT - 20 && ex.parse_mode) delete ex.parse_mode;
        return orig.sendDocument(chatId, doc, ex);
      }
    };
  }
};
JS

echo "==> 3) Sisipkan applySendSafe(bot) setelah konstruktor TelegramBot"
node - <<'JS'
const fs = require('fs');
let s = fs.readFileSync('bot.js','utf8');

const reCtor = /const\s+bot\s*=\s*new\s+TelegramBot\([^;]*\);\s*/;
const m = s.match(reCtor);
if(!m){ console.error('❌ Tidak menemukan konstruktor TelegramBot di bot.js'); process.exit(1); }

const inject = `
const applySendSafe = require('./sendSafe');
try { applySendSafe(bot); } catch(e){ console.error('WARN sendSafe:', e?.message||e); }
`;

const idx = s.indexOf(m[0]) + m[0].length;
s = s.slice(0, idx) + '\n' + inject + s.slice(idx);

fs.writeFileSync('bot.js', s);
console.log('✅ Injected applySendSafe(bot)');
JS

echo "==> 4) Restart service"
systemctl restart "$SERVICE" || true
sleep 1
systemctl status "$SERVICE" -n 10 --no-pager || true

echo "==> 5) Saran uji cepat"
echo "Kirim /cek satu NE lagi. Bila masih panjang, bot akan memecah otomatis."
