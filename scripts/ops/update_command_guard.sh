#!/usr/bin/env bash
set -euo pipefail

# Backup bot.js dulu
back="bot.js.bak_$(date +%Y%m%d-%H%M%S)"
cp bot.js "$back"
echo "Backup: $back"

# Sisipkan guard setelah 'const low = text.toLowerCase();'
sed -i '0,/const low = text.toLowerCase();/{
s/const low = text.toLowerCase();/const low = text.toLowerCase();\
  const cmdMatch = text.startsWith(\\'\\/\\') ? text.split(/\\s+/,1)[0].toLowerCase() : \\'\\';\
  const PUBLIC_CMDS = new Set([\\'\\/cek\\',\\'\\/history\\',\\'\\/help\\']);\
  const ADMIN_CMDS = new Set([\\'\\/admins\\',\\'\\/add_admin\\',\\'\\/remove_admin\\',\\'\\/wa_status\\',\\'\\/wa_enable\\',\\'\\/wa_disable\\',\\'\\/wa_pair\\']);\
  if (cmdMatch && !PUBLIC_CMDS.has(cmdMatch) && !ADMIN_CMDS.has(cmdMatch)) {\
    return bot.sendMessage(chatId, \\\"ℹ️ Perintah tidak dikenali.\\nKetik \\/help untuk daftar perintah.\\\");\
  }/
}' bot.js

echo "File diupdate ✅"

git add bot.js
git commit -m "fix: guard hanya tampil untuk command publik; admin commands tidak kena warning"
git pull --rebase origin main || true
git push origin main
echo "✅ Selesai. Warning hanya muncul untuk command publik yang salah."
