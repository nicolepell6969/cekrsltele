#!/usr/bin/env bash
set -euo pipefail

SERVICE="${SERVICE:-cekrsltele}"

echo "==> Backup bot.js"
cp -f bot.js bot.js.bak_crypto_shim_$(date +%Y%m%d-%H%M%S) || true

echo "==> Sisipkan crypto shim di baris paling atas bot.js (sekali saja)"
if ! grep -q "CRYPTO SHIM for Baileys" bot.js; then
  cat > .shim.js <<'JS'
// === CRYPTO SHIM for Baileys (WhatsApp) ===
(() => {
  try {
    // Node 18+: webcrypto tersedia via node:crypto
    const nodeCrypto = require('node:crypto');
    if (!globalThis.crypto) {
      globalThis.crypto = nodeCrypto.webcrypto || nodeCrypto;
    }
  } catch (e) {
    try {
      // Fallback ke crypto lama jika perlu
      const c = require('crypto');
      if (!globalThis.crypto) globalThis.crypto = c;
    } catch {}
  }
})();
JS
  # sisipkan di paling atas file
  cat .shim.js bot.js > bot.js.new && mv bot.js.new bot.js && rm -f .shim.js
  echo "   • Shim ditambahkan."
else
  echo "   • Shim sudah ada, lewati."
fi

echo "==> Pastikan dependency Baileys & ws up to date"
npm i @whiskeysockets/baileys qrcode-terminal ws --no-audit --no-fund

echo "==> Commit & push"
git add bot.js package.json package-lock.json 2>/dev/null || true
git commit -m "fix(wa): add Web Crypto shim for Baileys (globalThis.crypto)" || true
git pull --rebase origin main || true
git push origin main || true

echo "==> Restart service"
systemctl daemon-reload || true
systemctl restart "$SERVICE" || true
sleep 1
journalctl -u "$SERVICE" -n 40 --no-pager || true

echo "✅ Selesai. Coba /wa_enable lalu /wa_pair dari Telegram."
