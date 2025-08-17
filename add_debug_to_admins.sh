#!/usr/bin/env bash
set -euo pipefail

SERVICE="${SERVICE:-cekrsltele}"

echo "==> Backup bot.js"
cp -f bot.js bot.js.bak_debug_$(date +%Y%m%d-%H%M%S) 2>/dev/null || true

echo "==> Sisipkan helper debug ke admin (jika belum ada)"
if ! grep -q 'function notifyAdmins' bot.js; then
  cat >> bot.js <<'JS'

// ===== DEBUG: kirim error ke admin via Telegram =====
function _getAdminIds(){
  try {
    const list = (adminStore && typeof adminStore.listAdmins==='function')
      ? adminStore.listAdmins()
      : [];
    return (list||[]).map(x=>String(x)).filter(Boolean);
  } catch { return []; }
}
function notifyAdmins(text){
  try {
    const ids = _getAdminIds();
    if (!ids.length) return;
    const msg = `⚠️ [DEBUG ERROR]\n${text}`;
    for (const id of ids) { bot.sendMessage(id, msg).catch(()=>{}); }
  } catch {}
}

// polling error → kirim ke admin juga
try {
  bot.on('polling_error', (err)=>{
    const body = (err && err.response && err.response.body) ? err.response.body : (err && err.message ? err.message : String(err));
    notifyAdmins(`[polling_error] ${body}`);
  });
} catch {}

// global handlers
process.on('uncaughtException', (err)=>{
  const msg = (err && err.stack) ? err.stack : String(err);
  try { console.error('uncaughtException', err); } catch {}
  notifyAdmins(`Uncaught Exception:\n${msg}`);
});
process.on('unhandledRejection', (reason, p)=>{
  const msg = (reason && reason.stack) ? reason.stack : String(reason);
  try { console.error('unhandledRejection', reason); } catch {}
  notifyAdmins(`Unhandled Rejection:\n${msg}`);
});

// util opsional untuk kirim debug manual dari tempat lain:
// bot.sendAdminDebug?.('teks debug');
// atau panggil notifyAdmins('pesan');
bot.sendAdminDebug = (text)=> { try { notifyAdmins(text); } catch {} };
JS
else
  echo "   • notifyAdmins() sudah ada, lewati penyisipan."
fi

echo "==> Pastikan .env punya ADMIN_IDS (agar admin bisa menerima debug)"
if [ -f .env ]; then
  grep -q '^ADMIN_IDS=' .env || echo 'ADMIN_IDS=' >> .env
else
  echo -e "TELEGRAM_BOT_TOKEN=\nWA_ENABLED=false\nADMIN_IDS=\n" > .env
fi

echo "==> Seed admins dari .env jika adminStore tersedia"
node - <<'JS' || true
try {
  require('dotenv').config({ path: __dirname + '/.env' });
  const s = require('./adminStore');
  if (s && typeof s.seedFromEnv==='function'){ s.seedFromEnv(); console.log('Seed admin OK'); }
} catch(e){ console.log('Seed admin dilewati:', e.message); }
JS

echo "==> Commit & push"
git add bot.js .env 2>/dev/null || true
git commit -m "feat(debug): kirim error ke admin (notifyAdmins + global handlers)" || true
git pull --rebase origin main || true
git push origin main || true

echo "==> Restart service"
systemctl daemon-reload || true
systemctl restart "$SERVICE" || true
sleep 1
journalctl -u "$SERVICE" -n 20 --no-pager || true

echo "✅ Selesai."
echo "ℹ️ Pastikan ADMIN_IDS di .env berisi Telegram user ID admin (pisah dengan koma)."
echo "   Contoh: ADMIN_IDS=123456789,987654321"
