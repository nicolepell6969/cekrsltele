#!/usr/bin/env bash
set -euo pipefail

git config user.name  "${GIT_NAME:-nicolepell6969}"
git config user.email "${GIT_EMAIL:-ferenrezareynaldo5@gmail.com}"

cp -f bot.js bot.js.bak_invalidcmd_$(date +%Y%m%d-%H%M%S)

# Tambahkan blok untuk deteksi command tidak dikenal
# Cari switch-case utama, sebelum "default:" tambahkan handler
# Lalu ganti default fallback 👍 jadi parsing biasa

sed -i "/switch (command)/a \\
    case undefined:\\n        // bukan command, biarkan parser teks bebas jalan\\n        break;\\n    case '':\\n        break;" bot.js

# Ganti fallback default sebelumnya
sed -i "s/return bot\.sendMessage(chatId, '👍');/return bot.sendMessage(chatId, 'ℹ️ Perintah tidak dikenali.\\\\nKetik \\/help untuk daftar perintah.');/g" bot.js

git add bot.js
git commit -m "fix: show ℹ️ warning only for invalid commands, not free text"
git pull --rebase origin main || true
git push origin main || true

if systemctl is-enabled cekrsltele.service >/dev/null 2>&1; then
  systemctl restart cekrsltele.service
  systemctl status cekrsltele.service --no-pager -l | sed -n '1,12p'
fi

echo "✅ Selesai. Warning hanya muncul jika command salah (/xxx). Teks biasa tetap diparse."
