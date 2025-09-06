#!/usr/bin/env bash
set -euo pipefail

echo "==> Backup bot.js"
cp -f bot.js bot.js.bak_no_txt_$(date +%Y%m%d-%H%M%S) 2>/dev/null || true

node - <<'JS'
const fs = require('fs');
let s = fs.readFileSync('bot.js','utf8');

// Jika sendLong belum ada, sisipkan helper (tanpa .txt)
if (!/function\s+sendLong\s*\(/.test(s)) {
  const hook = /const\s+bot\s*=\s*new\s+TelegramBot\([^;]+;?\s*\)\s*;?/;
  const m = s.match(hook);
  if (m) {
    const idx = s.indexOf(m[0]) + m[0].length;
    const helper = `

/** kirim pesan panjang aman untuk Telegram (tanpa kirim .txt) */
async function sendLong(chatId, text, extra = {}) {
  const MAX = 3900; // <4096, beri buffer
  const t = String(text ?? '');
  if (t.length <= MAX) return bot.sendMessage(chatId, t, extra);

  const lines = t.split('\\n');
  let buf = '';
  for (const line of lines) {
    const would = buf ? (buf + '\\n' + line) : line;
    if (would.length > MAX) {
      await bot.sendMessage(chatId, buf, extra);
      buf = line;
    } else {
      buf = would;
    }
  }
  if (buf) await bot.sendMessage(chatId, buf, extra);
}
`;
    s = s.slice(0, idx) + helper + s.slice(idx);
  }
} else {
  // Jika sudah ada, buang bagian kirim dokumen & blok "Kirim file txt ..."
  s = s.replace(/await\s+bot\.sendDocument\([^)]*\);\s*/g, '');
  s = s.replace(/[\t ]*\/\/\s*Kirim file txt[\s\S]*?}\s*$/m, '');
}

// Pastikan pemanggilan hasil pakai sendLong (jika sebelumnya belum)
s = s
  .replace(/bot\.sendMessage\(\s*chatId\s*,\s*result(\s*,\s*\{[^)]*\})?\s*\)/g,
           (m)=> m.replace('bot.sendMessage', 'sendLong'))
  .replace(/bot\.sendMessage\(\s*chatId\s*,\s*combined(\s*,\s*\{[^)]*\})?\s*\)/g,
           (m)=> m.replace('bot.sendMessage', 'sendLong'));

fs.writeFileSync('bot.js', s);
console.log('✅ sendLong tanpa .txt diterapkan.');
JS

echo "==> Restart service"
systemctl restart cekrsltele || true
sleep 1
systemctl status cekrsltele -n 3 --no-pager || true
