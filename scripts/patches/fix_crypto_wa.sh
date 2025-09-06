#!/usr/bin/env bash
set -euo pipefail

SERVICE="${SERVICE:-cekrsltele}"

echo "==> Backup bot.js"
cp -f bot.js bot.js.bak_crypto_$(date +%Y%m%d-%H%M%S) || true

echo "==> Tambah require('crypto') bila belum ada"
if ! grep -q "require('crypto')" bot.js; then
  sed -i '1irequire("crypto");' bot.js
  echo "   • Tambah require('crypto') di baris pertama bot.js"
else
  echo "   • crypto sudah ada, lewati"
fi

echo "==> Commit & push perubahan"
git add bot.js 2>/dev/null || true
git commit -m "fix(wa): add require crypto for Baileys" || true
git pull --rebase origin main || true
git push origin main || true

echo "==> Restart service"
systemctl daemon-reload || true
systemctl restart "$SERVICE" || true
sleep 1
journalctl -u "$SERVICE" -n 20 --no-pager || true

echo "✅ Selesai. WhatsApp seharusnya sudah tidak error crypto lagi."
