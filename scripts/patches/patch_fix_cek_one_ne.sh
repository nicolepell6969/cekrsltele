#!/usr/bin/env bash
set -euo pipefail

SERVICE="${SERVICE:-cekrsltele}"

echo "==> 1) Backup bot.js"
cp -f bot.js bot.js.bak_fix1ne_$(date +%Y%m%d-%H%M%S) 2>/dev/null || true

echo "==> 2) Patch blok /cek (robust 1 NE & 2 NE) + warning hanya utk command tak dikenal"
node - <<'JS'
const fs = require('fs');
let s = fs.readFileSync('bot.js','utf8');

// Pastikan handler unknown command hanya muncul utk command (teks mulai dengan '/')
s = s.replace(
  /if\s*\(\s*isCommand\s*&&\s*!\s*PUBLIC_CMDS\.has\(cmdOnly\)\s*&&\s*!\s*ADMIN_CMDS\.has\(cmdOnly\)\s*\)\s*\{[\s\S]*?return bot\.sendMessage\(chatId,[\s\S]*?\);\s*\}/,
  `if (isCommand && !PUBLIC_CMDS.has(cmdOnly) && !ADMIN_CMDS.has(cmdOnly)) {
      return bot.sendMessage(chatId, "ℹ️ Perintah tidak dikenali.\\nKetik /help untuk daftar perintah.");
    }`
);

// Ganti seluruh blok "/cek" dengan implementasi yang pasti membalas utk 1 NE maupun 2 NE
const startKey = '// ===== /cek (robust 1 NE & 2 NE) =====';
const endKey   = '// Teks bebas';
const si = s.indexOf(startKey);
const ei = s.indexOf(endKey, si === -1 ? 0 : si);

const newBlock =
`${startKey}
  if (/^\\/cek(\\s+|$)/.test(low)) {
    if (!checkMetroStatus) return bot.sendMessage(chatId,'❌ checkMetroStatus.js tidak tersedia di server.');

    // buang '/cek' lalu pisahkan argumen longgar
    const tail  = text.replace(/^\\/cek/, '');
    const parts = tail.split(/\\s+/).map(x=>x.trim()).filter(Boolean);

    // === 1 NE ===
    if (parts.length === 1) {
      const ne = parts[0];
      await bot.sendMessage(chatId, '🔄 Cek satu NE: ' + ne + ' …');
      try {
        const start = Date.now();
        const result = await Promise.race([
          checkMetroStatus.checkSingleNE(ne),
          new Promise((_,rej)=>setTimeout(()=>rej(new Error('Timeout 90s @cek-1NE')), 90000))
        ]);
        const end = Date.now();
        const payload = result && String(result).trim().length
          ? result
          : '(i) tidak ada data dikembalikan dari server';
        addHistory(ne, null, payload, ne, start, end);
        return bot.sendMessage(
          chatId,
          '🕛Checked Time: ' + new Date(end).toLocaleString('id-ID',{timeZone:'Asia/Jakarta'}) + '\\n\\n' + payload
        );
      } catch (e) {
        // kirim debug ke admin agar kelihatan di PM
        try { bot.sendAdminDebug?.('(/cek 1 NE) ' + (e?.stack||e?.message||String(e))); } catch {}
        return bot.sendMessage(chatId, '❌ Gagal cek 1 NE: ' + (e?.message || String(e)));
      }
    }

    // === 2 NE (ambil dua sisi) ===
    if (parts.length >= 2) {
      const ne1 = parts[0], ne2 = parts[1];
      await bot.sendMessage(chatId, '🔄 ONCEK, DITUNGGU');
      try {
        const start = Date.now();
        const r1 = await Promise.race([
          checkMetroStatus(ne1, ne2, { mode:'normal' }),
          new Promise((_,rej)=>setTimeout(()=>rej(new Error('Timeout 90s @cek-A')), 90000))
        ]);
        const r2 = await Promise.race([
          checkMetroStatus(ne2, ne1, { mode:'normal' }),
          new Promise((_,rej)=>setTimeout(()=>rej(new Error('Timeout 90s @cek-B')), 90000))
        ]);
        const end = Date.now();
        const combined = String(r1||'') + '\\n────────────\\n' + String(r2||'');
        addHistory(ne1, ne2, combined, ne1+' '+ne2, start, end);
        return bot.sendMessage(
          chatId,
          '🕛Checked Time: ' + new Date(end).toLocaleString('id-ID',{timeZone:'Asia/Jakarta'}) + '\\n\\n' + combined,
          { reply_markup:{ inline_keyboard: [[{ text:'🔁 CEK ULANG', callback_data:'retry_last_' + (history.length-1) }]] } }
        );
      } catch (e) {
        try { bot.sendAdminDebug?.('(/cek 2 NE) ' + (e?.stack||e?.message||String(e))); } catch {}
        return bot.sendMessage(chatId, '❌ Gagal cek 2 sisi: ' + (e?.message || String(e)));
      }
    }

    return bot.sendMessage(chatId, '❗ Format: /cek <NE1> [NE2]');
  }
`;

if (si !== -1 && ei !== -1 && ei > si) {
  const before = s.slice(0, si);
  const after  = s.slice(ei);
  s = before + newBlock + after;
} else {
  // kalau marker tidak ketemu, inject saja sebelum "Teks bebas"
  const insertAt = s.indexOf(endKey);
  if (insertAt !== -1) {
    s = s.slice(0, insertAt) + newBlock + s.slice(insertAt);
  } else {
    // terakhir, tambahkan saja di akhir file (aman)
    s += '\n\n' + newBlock + '\n';
  }
}

fs.writeFileSync('bot.js', s);
console.log('OK: /cek block diganti.');
JS

echo "==> 3) Pastikan ADMIN_IDS ada di .env"
touch .env
grep -q '^ADMIN_IDS=' .env || echo 'ADMIN_IDS=' >> .env

echo "==> 4) Commit & (opsional) push"
git add bot.js .env || true
git commit -m "fix: robust /cek 1 NE & 2 NE, admin debug, ensure ADMIN_IDS in .env" || true
# kalau remote sudah diset, push; kalau tidak, biarkan diam
git rev-parse --is-inside-work-tree >/dev/null 2>&1 && git remote -v >/dev/null 2>&1 && git push || true

echo "==> 5) Restart service"
systemctl daemon-reload || true
systemctl restart "$SERVICE"
sleep 1
systemctl status --no-pager -l "$SERVICE" | sed -n '1,15p'
echo "==> 6) Tail log 25 baris terakhir:"
journalctl -u "$SERVICE" -n 25 --no-pager
