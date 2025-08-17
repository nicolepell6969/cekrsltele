#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(pwd)"
BOT="$APP_DIR/bot.js"
SVC="${SERVICE:-cekrsltele}"

[[ -f "$BOT" ]] || { echo "❌ bot.js tidak ditemukan"; exit 1; }

# 1) Backup
cp -f "$BOT" "bot.js.bak_minifix_$(date +%Y%m%d-%H%M%S)"

# 2) Patch minimal:
#   - Comment baris 'part = takeUntil(...' yang korup
#   - Comment baris 'dummy regex' yang menimbulkan invalid regexp
#   - Comment baris teks lepas berisi 'atau spasi'
#   - Comment fragmen WA 'connection.update' nyasar (sampai sebelum 'waClient = sock;')

# a) baris 'part = takeUntil('
sed -i 's/^\(\s*\)part\s*=\s*takeUntil\s*(.*/\1\/\/ [FIX] disabled broken takeUntil line/g' "$BOT"

# b) baris yang mengandung 'dummy regex'
sed -i 's/^\(\s*\)\(.*dummy regex.*\)$/\1\/\/ [FIX] \2/g' "$BOT"

# c) baris lepas yang mengandung 'atau spasi' (dan belum dikomentari)
awk '
  BEGIN{changed=0}
  {
    if ($0 ~ /atau spasi/ && $0 !~ /^[[:space:]]*\/\//) {
      print "// [FIX] " $0; changed++
    } else print $0
  }
' "$BOT" > "$BOT.tmp" && mv "$BOT.tmp" "$BOT"

# d) comment fragmen WA connection.update yang terpotong (di luar handler)
#    rentang: dari baris yang memuat "WA connection.update (QR" sampai sebelum "waClient = sock;"
awk '
  BEGIN{infrag=0}
  {
    if ($0 ~ /WA connection\.update .*QR/) { infrag=1 }
    if (infrag==1) {
      print "// [FIX-BLOCK] " $0
      if ($0 ~ /waClient[[:space:]]*=[[:space:]]*sock[[:space:]]*;/) { infrag=0 }
    } else {
      print $0
    }
  }
' "$BOT" > "$BOT.tmp" && mv "$BOT.tmp" "$BOT"

# 3) Cek sintaks (compile saja, tidak dieksekusi)
node -e "new Function(require('fs').readFileSync('bot.js','utf8'))" \
  && echo "✅ Syntax OK" || { echo "❌ Syntax masih error"; exit 1; }

# 4) Restart service
systemctl restart "$SVC"
sleep 1
systemctl --no-pager --full status "$SVC" -l || true
