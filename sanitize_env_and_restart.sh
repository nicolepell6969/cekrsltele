#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-$HOME/cekrsltele}"
ENV_FILE="${ENV_FILE:-$APP_DIR/.env}"
SERVICE="${SERVICE:-cekrsltele}"

echo "==> Cek & bersihkan TELEGRAM_BOT_TOKEN di $ENV_FILE"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ $ENV_FILE tidak ditemukan"; exit 1
fi

# Ambil token mentah (ambil yang terakhir jika duplikat)
RAW_LINE="$(grep -n '^[[:space:]]*TELEGRAM_BOT_TOKEN=' "$ENV_FILE" | tail -n1 || true)"
if [[ -z "$RAW_LINE" ]]; then
  echo "❌ TELEGRAM_BOT_TOKEN= tidak ada di .env"; exit 1
fi

RAW_TOKEN="${RAW_LINE#*=}"

# Bersihkan: hapus quote, spasi di kiri/kanan, CRLF
CLEAN_TOKEN="$(printf '%s' "$RAW_TOKEN" | tr -d '\r' | sed 's/^ *//; s/ *$//' | sed 's/^"//; s/"$//' | sed "s/^'//; s/'$//")"
LEN=${#CLEAN_TOKEN}
echo "   • Panjang token setelah dibersihkan: $LEN"

if (( LEN < 40 )); then
  echo "⚠️  Token terlihat pendek. Tetap lanjut uji ke API…"
fi

echo "==> Uji getMe ke API Telegram"
R="$(curl -sS "https://api.telegram.org/bot${CLEAN_TOKEN}/getMe" || true)"
echo "   • Respon: $R"
echo "$R" | grep -q '"ok":true' || { echo "❌ Token invalid/expired. Revoke & dapatkan token baru dari @BotFather, lalu jalankan script ini lagi."; exit 2; }

echo "==> Tulis ulang baris TELEGRAM_BOT_TOKEN= (pastikan tunggal & bersih)"
# Hapus semua baris token lama, lalu append baris bersih di akhir file
tmpf="$(mktemp)"
grep -v '^[[:space:]]*TELEGRAM_BOT_TOKEN=' "$ENV_FILE" > "$tmpf" || true
printf '\nTELEGRAM_BOT_TOKEN=%s\n' "$CLEAN_TOKEN" >> "$tmpf"
mv "$tmpf" "$ENV_FILE"

echo "==> Pastikan systemd membaca .env"
OVR_DIR="/etc/systemd/system/${SERVICE}.service.d"
mkdir -p "$OVR_DIR"
cat > "${OVR_DIR}/override-env.conf" <<EOF
[Service]
EnvironmentFile=${ENV_FILE}
WorkingDirectory=${APP_DIR}
EOF

echo "==> Matikan webhook (bot kita polling)"
curl -sS "https://api.telegram.org/bot${CLEAN_TOKEN}/deleteWebhook" >/dev/null || true

echo "==> Reload daemon & restart service"
systemctl daemon-reload
systemctl restart "${SERVICE}"

echo "==> Status singkat:"
systemctl status "${SERVICE}" --no-pager -l | sed -n '1,15p' || true
echo "==> 30 log terakhir:"
journalctl -u "${SERVICE}" -n 30 --no-pager || true

echo "✅ Selesai. Coba kirim /help ke bot. Jika masih 401, revoke token di BotFather, update .env, lalu jalankan script ini lagi."
