#!/usr/bin/env bash
set -euo pipefail

git config user.name  "${GIT_NAME:-nicolepell6969}"
git config user.email "${GIT_EMAIL:-ferenrezareynaldo5@gmail.com}"

ts="$(date +%Y%m%d-%H%M%S)"
cp -f bot.js "bot.js.bak.singleNE.$ts"

# Tambahkan helper runWithTimeout bila belum ada (dipakai untuk 1 NE)
node - <<'JS' > .apply.js
const fs = require('fs');
let s = fs.readFileSync('bot.js','utf8');

if (!/function runWithTimeout\(/.test(s)) {
  const helper = `

// ===== Helper timeout umum =====
function runWithTimeout(promise, ms, tag='op'){
  return Promise.race([
    promise,
    new Promise((_,rej)=>setTimeout(()=>rej(new Error('Timeout '+ms+'ms @'+tag)), ms))
  ]);
}
`;
  // selipkan sebelum komentar "start WA jika enabled" supaya available di semua handler
  s = s.replace(/\/\/ start WA jika enabled/ig, helper + '\n// start WA jika enabled');
}

/**
 * Ganti blok handler "/cek" mode 1 NE menjadi versi yang:
 * - selipkan notifikasi "🔄 Cek satu NE: ..."
 * - tunggu checkSingleNE dengan timeout 90s
 * - tangani error/timeout => kirim pesan yang jelas
 */
s = s.replace(
  /if \(parts\.length === 1\) \{[\s\S]*?return bot\.sendMessage\(chatId,[\s\S]*?\);\s*\}/m,
  `if (parts.length === 1) {
      const ne = parts[0];
      await bot.sendMessage(chatId, \`🔄 Cek satu NE: \${ne}…\`);
      try {
        const start = Date.now();
        const result = await runWithTimeout(checkMetroStatus.checkSingleNE(ne), 90000, 'cek-1NE');
        const end = Date.now();
        const stamp = new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' });
        addHistory(ne, null, result, ne, start, end);
        return bot.sendMessage(chatId, \`🕛Checked Time: \${stamp}\\n\\n\${result}\`);
      } catch (e) {
        return bot.sendMessage(chatId, '⚠️ Gagal cek 1 NE: ' + e.message + '\\nCoba lagi atau gunakan format: /cek NE_A NE_B');
      }
    }`
);

process.stdout.write(s);
JS

node .apply.js > bot.js.new
mv bot.js.new bot.js
rm -f .apply.js

git add bot.js
git commit -m "fix(cek-1NE): robust single-NE handler with timeout & clear error"
git pull --rebase origin main || true
git push origin main || true

if systemctl is-enabled cekrsltele.service >/dev/null 2>&1; then
  systemctl restart cekrsltele.service
  systemctl status cekrsltele.service --no-pager -l | sed -n '1,14p'
fi

echo "✅ Fix applied. Coba /cek <NE_SAJA> lagi."
