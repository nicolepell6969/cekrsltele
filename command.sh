#!/usr/bin/env bash
set -euo pipefail

SERVICE=cekrsltele
REPO_DIR="$HOME/cekrsltele"
cd "$REPO_DIR"

# --- Patch launcher flags Puppeteer biar ringan ---
# (checkMetroStatus.js sudah pakai args dasar; tambahkan flags hemat proses)
sed -i 's/args: \[/args: \[\n      "--single-process", "--no-zygote", "--disable-dev-shm-usage",/g' checkMetroStatus.js || true

# --- Tambah graceful shutdown di bot utama (bot.js) bila file ada ---
if grep -q "new TelegramBot" bot.js 2>/dev/null; then
  awk '1; END{
    print "";
    print "// === graceful shutdown ===";
    print "function quit(){ try{bot.stopPolling();}catch{} setTimeout(()=>process.exit(0),500);} ";
    print "process.on(\"SIGTERM\", quit);";
    print "process.on(\"SIGINT\", quit);";
  }' bot.js > bot.js.new && mv bot.js.new bot.js
fi

# --- Kalau kamu pakai multiBot.js (Telegram+WhatsApp), tambahkan graceful shutdown ---
if [ -f multiBot.js ]; then
  # Pastikan ada referensi klien WA & TG
  if grep -q "new TelegramBot" multiBot.js && grep -q "new Client" multiBot.js; then
    # sisipkan handler only once
    if ! grep -q "graceful shutdown" multiBot.js; then
      cat >> multiBot.js <<'EOF'

// === graceful shutdown ===
async function shutdown() {
  try { tg.stopPolling?.(); } catch {}
  try { await wa.destroy?.(); } catch {}
  // beri waktu puppeteer tutup
  setTimeout(() => process.exit(0), 800);
}
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
EOF
    fi
  fi
fi

# --- Update unit systemd override (stop lebih smooth) ---
sudo mkdir -p /etc/systemd/system/${SERVICE}.service.d
sudo tee /etc/systemd/system/${SERVICE}.service.d/override-timeout.conf >/dev/null <<'UNIT'
[Service]
# Stop lebih manusiawi: TERM ke main + anak, lalu KILL jika masih bandel
KillMode=mixed
TimeoutStopSec=20
# Tambah waktu start kalau butuh chromium dan WA init
TimeoutStartSec=60
# Chromium lebih irit kalau di-set env ini (opsional)
# Environment=PAGE_TIMEOUT_MS=20000
# Environment=MAX_CANDIDATES=5
# Environment=PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser
UNIT

# --- Commit & restart ---
git add -A
git -c user.name="nicolepell6969" -c user.email="ferenrezareynaldo5@gmail.com" \
  commit -m "chore: graceful shutdown + systemd KillMode=mixed & timeouts; puppeteer light flags" || true

git push

sudo systemctl daemon-reload
sudo systemctl restart ${SERVICE}
systemctl status ${SERVICE} --no-pager -l | sed -n '1,14p'
