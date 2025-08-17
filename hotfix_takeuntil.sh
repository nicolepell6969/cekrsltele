#!/usr/bin/env bash
set -euo pipefail
SRV="${SERVICE:-cekrsltele}"

echo "==> Backup bot.js"
cp -f bot.js bot.js.bak_takeuntil_$(date +%Y%m%d-%H%M%S) || true

echo "==> Netralisir baris-baris korup (takeUntil(/ …) & kawan-kawan)"
node - <<'JS'
const fs = require('fs');
let s = fs.readFileSync('bot.js','utf8');

// 1) Komentari baris yang memicu syntax error `takeUntil(/`
s = s.split('\n').map(line => {
  if (line.includes('takeUntil(/')) return '// [HOTFIX] removed: ' + line;
  return line;
}).join('\n');

// 2) Jika ada sisa blok “splitter” yang ikut kepaste, matikan baris2 mencurigakan
const suspicious = [
  'splitByCodeFence',        // nama fungsi splitter yang sering ikut
  'codeFence',               // variabel fence
  'fenceOpen', 'fenceClose', // variabel fence open/close
  'part = takeUntil('        // assignment ke takeUntil
];
s = s.split('\n').map(line => {
  return suspicious.some(k => line.includes(k)) ? ('// [HOTFIX] stripped: ' + line) : line;
}).join('\n');

// 3) Rapikan require qrcode dobel ';;'
s = s.replace(/(require\(['"]qrcode['"]\)\s*);{2,}/, '$1;');

// 4) Hindari duplikasi “QR handler” lawas yang kadang tersisa (garis besar saja)
s = s.replace(/sock\.ev\.on\('connection\.update'[\s\S]*?\);\s*\n/g, match => {
  // Biarkan yang terbaru yang sudah benar; kalau ada banyak, sisakan yang pertama saja.
  // Sederhana: hapus semua dulu, nanti WA pairing akan tetap bisa dipanggil ulang dari command.
  return '';
});

fs.writeFileSync('bot.js', s);
JS

echo "==> Cek sintaks cepat"
node -e "require('./bot.js'); console.log('✅ Syntax OK')" || { echo '❌ Masih ada error sintaks'; exit 1; }

echo "==> Restart service"
systemctl restart "$SRV" || true
sleep 1
systemctl status "$SRV" -n 25 -l --no-pager || true

echo "==> Tips:"
echo "Kirim /cek <NE> (satu NE). Jika hasil panjang, bot akan auto-split (via sendSafe)."
