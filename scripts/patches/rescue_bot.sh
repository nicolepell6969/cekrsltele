#!/usr/bin/env bash
set -euo pipefail
APP="${APP:-$HOME/cekrsltele}"
cd "$APP"

echo "==> Cek repo git…"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ ! -s bot.js ]; then
    echo "bot.js kosong → coba restore dari HEAD…"
    if git cat-file -e HEAD:bot.js 2>/dev/null; then
      git checkout -- bot.js || git restore --source=HEAD -- bot.js || true
    else
      echo "HEAD tidak punya bot.js → coba origin/main…"
      git fetch origin main --quiet || true
      if git cat-file -e origin/main:bot.js 2>/dev/null; then
        git show origin/main:bot.js > bot.js
      else
        echo "origin/main juga tidak ada → unduh raw dari GitHub…"
        GITHUB_USER="${GITHUB_USER:-nicolepell6969}"
        GITHUB_REPO="${GITHUB_REPO:-cekrsltele}"
        curl -fsSL "https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/main/bot.js" -o bot.js
      fi
    fi
  else
    echo "bot.js ada (tidak kosong) — lewati restore."
  fi
else
  echo "Bukan repo git → unduh raw dari GitHub…"
  GITHUB_USER="${GITHUB_USER:-nicolepell6969}"
  GITHUB_REPO="${GITHUB_REPO:-cekrsltele}"
  curl -fsSL "https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/main/bot.js" -o bot.js
fi

# Pastikan berhasil
if [ ! -s bot.js ]; then
  echo "❌ Gagal memulihkan bot.js (masih kosong)."; exit 1
fi

# Sisipkan dotenv di baris pertama jika belum ada
if ! grep -q 'dotenv' bot.js; then
  TMP="$(mktemp)"
  printf 'require("dotenv").config({ path: __dirname + "/.env" });\n' > "$TMP"
  cat bot.js >> "$TMP"
  mv "$TMP" bot.js
fi

echo "==> Restart service…"
systemctl daemon-reload || true
systemctl restart cekrsltele || true
sleep 2
systemctl status cekrsltele --no-pager -l | sed -n '1,25p'
echo "==> Log terakhir:"
journalctl -u cekrsltele -n 50 --no-pager
