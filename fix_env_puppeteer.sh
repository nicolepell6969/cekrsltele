#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-$HOME/cekrsltele}"
ENV_FILE="${ENV_FILE:-$APP_DIR/.env}"
SERVICE="${SERVICE:-cekrsltele}"

clean_val(){ # strip CR, leading/trailing spaces, quotes, dan komentar inline
  printf '%s' "$1" | tr -d '\r' | sed 's/[[:space:]]*#.*$//' | sed 's/^ *//; s/ *$//' | sed 's/^"//; s/"$//' | sed "s/^'//; s/'$//"
}

echo "==> Baca & bersihkan $ENV_FILE"
[[ -f "$ENV_FILE" ]] || { echo "❌ .env tidak ditemukan"; exit 1; }

# Muat nilai lama (apa adanya)
TOK_RAW="$(grep -E '^TELEGRAM_BOT_TOKEN=' "$ENV_FILE" | tail -n1 | cut -d= -f2- || true)"
HEAD_RAW="$(grep -E '^HEADLESS='             "$ENV_FILE" | tail -n1 | cut -d= -f2- || true)"
TOUT_RAW="$(grep -E '^PAGE_TIMEOUT_MS='      "$ENV_FILE" | tail -n1 | cut -d= -f2- || true)"
RXHB_RAW="$(grep -E '^RX_HIGHER_IS_BETTER='  "$ENV_FILE" | tail -n1 | cut -d= -f2- || true)"
PUPP_RAW="$(grep -E '^PUPPETEER_EXECUTABLE_PATH=' "$ENV_FILE" | tail -n1 | cut -d= -f2- || true)"
TZ_RAW="$(grep -E '^TZ=' "$ENV_FILE" | tail -n1 | cut -d= -f2- || true)"

TOK="$(clean_val "$TOK_RAW")"
HEAD="$(clean_val "${HEAD_RAW:-true}")"
TOUT="$(clean_val "${TOUT_RAW:-60000}")"
RXHB="$(clean_val "${RXHB_RAW:-true}")"
TZV="$(clean_val "${TZ_RAW:-Asia/Jakarta}")"

# Deteksi chromium lokal (opsional)
FOUND_PATH=""
for p in /usr/bin/google-chrome-stable /usr/bin/google-chrome /usr/bin/chromium /usr/bin/chromium-browser; do
  [[ -x "$p" ]] && { FOUND_PATH="$p"; break; }
done

if [[ -n "$FOUND_PATH" ]]; then
  echo "   • Ditemukan Chrome/Chromium: $FOUND_PATH"
  PUPP="$FOUND_PATH"
else
  echo "   • Chrome lokal tidak ditemukan, pakai Chromium bawaan Puppeteer."
  PUPP=""  # kosongkan → Puppeteer bundle
fi

# Tulis ulang .env yang bersih (tanpa komentar inline)
tmpf="$(mktemp)"
{
  echo "TELEGRAM_BOT_TOKEN=$TOK"
  echo "TZ=$TZV"
  echo "HEADLESS=$HEAD"
  echo "PAGE_TIMEOUT_MS=$TOUT"
  echo "RX_HIGHER_IS_BETTER=$RXHB"
  echo "PUPPETEER_EXECUTABLE_PATH=$PUPP"
} > "$tmpf"
mv "$tmpf" "$ENV_FILE"

echo "==> Pastikan paket puppeteer terpasang (bundled Chromium)"
if ! node -e "require('puppeteer');" >/dev/null 2>&1; then
  npm i puppeteer@^22 --no-audit --no-fund
fi

echo "==> Pastikan systemd membaca .env"
OVR_DIR="/etc/systemd/system/${SERVICE}.service.d"
mkdir -p "$OVR_DIR"
cat > "${OVR_DIR}/override-env.conf" <<EOF
[Service]
EnvironmentFile=${ENV_FILE}
WorkingDirectory=${APP_DIR}
EOF

echo "==> Reload & restart service"
systemctl daemon-reload
systemctl restart "${SERVICE}"

echo "==> Logs terakhir:"
journalctl -u "${SERVICE}" -n 40 --no-pager
echo "✅ Selesai. Coba /cek lagi."
