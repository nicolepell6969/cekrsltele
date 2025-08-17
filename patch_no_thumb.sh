#!/usr/bin/env bash
set -euo pipefail

# Identitas git (pakai default kamu)
git config user.name  "${GIT_NAME:-nicolepell6969}"
git config user.email "${GIT_EMAIL:-ferenrezareynaldo5@gmail.com}"

# Buat backup ringan
cp -f bot.js bot.js.bak_nothumb_$(date +%Y%m%d-%H%M%S)

# 1) Ganti fallback "👍" -> pesan bantuan singkat
#   Cari baris: return bot.sendMessage(chatId, '👍');
#   Ganti:      return bot.sendMessage(chatId, 'ℹ️ Perintah tidak dikenali.\nKetik /help untuk daftar perintah.');

sed -i "s/return bot\.sendMessage(chatId, '👍');/return bot.sendMessage(chatId, 'ℹ️ Perintah tidak dikenali.\\\\nKetik \\/help untuk daftar perintah.');/g" bot.js

# 2) Perbaiki semua pesan admin jadi konsisten & informatif
#   Kasus: "❌ Perintah ini khusus admin."
sed -i "s/❌ Perintah ini khusus admin\./🚫 Perintah ini khusus admin. Minta admin menambahkan ID kamu via \\/add_admin <telegram_id>./g" bot.js
#   Kasus: "Khusus admin."
sed -i "s/[^A-Za-z]Khusus admin\./ 🚫 Perintah ini khusus admin. Minta admin menambahkan ID kamu via \\/add_admin <telegram_id>./g" bot.js

# 3) Commit & push
git add bot.js
git commit -m "ux: remove 👍 fallback and improve admin-only warnings"
git pull --rebase origin main || true
git push origin main || true

# 4) Restart service
if systemctl is-enabled cekrsltele.service >/dev/null 2>&1; then
  systemctl restart cekrsltele.service
  systemctl status cekrsltele.service --no-pager -l | sed -n '1,12p'
fi

echo "✅ Selesai. Fallback 👍 dihapus, pesan admin diperbaiki."
