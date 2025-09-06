#!/usr/bin/env bash
set -euo pipefail

git config user.name  "${GIT_NAME:-nicolepell6969}"
git config user.email "${GIT_EMAIL:-ferenrezareynaldo5@gmail.com}"

echo "==> Backup bot.js"
cp -f bot.js bot.js.bak_wa_$(date +%Y%m%d-%H%M%S) || true

echo "==> Tambah adminStore.js (persisten admins.json)"
if [ ! -f adminStore.js ]; then
cat > adminStore.js <<'JS'
const fs = require('fs');
const path = require('path');
const FILE = path.join(__dirname, 'admins.json');

function _read() {
  try {
    if (!fs.existsSync(FILE)) return { admins: [] };
    return JSON.parse(fs.readFileSync(FILE, 'utf8') || '{"admins":[]}');
  } catch { return { admins: [] }; }
}
function _write(obj){ try { fs.writeFileSync(FILE, JSON.stringify(obj, null, 2)); } catch {} }

function seedFromEnv(){
  const seed = String(process.env.ADMIN_IDS || '')
    .split(',').map(s=>s.trim()).filter(Boolean).map(x=>String(Number(x))).filter(Boolean);
  if (!seed.length) return;
  const obj=_read(); const set=new Set((obj.admins||[]).map(String));
  for (const id of seed) set.add(id);
  obj.admins = Array.from(set);
  _write(obj);
}
function listAdmins(){ return (_read().admins||[]).map(String); }
function isAdmin(id){ return listAdmins().includes(String(id)); }
function addAdmin(id){
  const sid = String(Number(id)); if (!sid || sid==='NaN') throw new Error('ID tidak valid');
  const obj=_read(); const set=new Set((obj.admins||[]).map(String)); set.add(sid);
  obj.admins = Array.from(set); _write(obj); return obj.admins;
}
function removeAdmin(id){
  const sid=String(Number(id)); const obj=_read();
  obj.admins=(obj.admins||[]).map(String).filter(x=>x!==sid); _write(obj); return obj.admins;
}
module.exports = { seedFromEnv, listAdmins, isAdmin, addAdmin, removeAdmin };
JS
fi

echo "==> Patch bot.js: tambah WA manager + admin commands"
node - <<'JS' > .apply.js
const fs=require('fs');
let s=fs.readFileSync('bot.js','utf8');

// pastikan dotenv ada di baris awal
if(!/dotenv/.test(s)){ s='require("dotenv").config({ path: __dirname + "/.env" });\n'+s; }

// sisipkan adminStore + helper admin bila belum ada
if(!/adminStore\.js/.test(s)){
  s = s.replace(/(\n\/\/ ===== Handler pesan =====|bot\.on\('message')/m,
`
// ===== Admin store & helper =====
const adminStore = require('./adminStore'); adminStore.seedFromEnv();
function isAdminId(id){ try { return adminStore.isAdmin(id); } catch { return false; } }
function requireAdmin(msg, fn){
  const id = (msg.from && msg.from.id) || msg.chat?.id;
  if (!isAdminId(id)) return bot.sendMessage(msg.chat.id, '🚫 Perintah ini khusus admin. Minta admin menambahkan ID kamu via /add_admin <telegram_id>.');
  return fn();
}
$1`);
}

// tambahkan daftar command valid (guard unknown command)
if(!/PUBLIC_CMDS/.test(s)){
  s = s.replace(/const low = text.toLowerCase\(\);/,
`const low = text.toLowerCase();
const PUBLIC_CMDS = new Set(['/cek','/history','/help']);
const ADMIN_CMDS  = new Set(['/admins','/add_admin','/remove_admin','/wa_status','/wa_enable','/wa_disable','/wa_pair']);
const cmdMatch = text.startsWith('/') ? text.split(/\\s+/,1)[0].toLowerCase() : '';
if (cmdMatch && !PUBLIC_CMDS.has(cmdMatch) && !ADMIN_CMDS.has(cmdMatch)) {
  return bot.sendMessage(chatId, "ℹ️ Perintah tidak dikenali.\\nKetik /help untuk daftar perintah.");
}`
  );
}

// tambahkan /help, /admins, /add_admin, /remove_admin jika belum ada
if(!/\/admins/.test(s)){
s = s.replace(/(if \(low === '\/help'[\s\S]*?return bot\.sendMessage[\s\S]*?\}\n)/m, `$1
  if (low === '/admins') {
    return requireAdmin(msg, () => {
      const list = adminStore.listAdmins();
      const pretty = list.length ? list.map(x => '• '+x).join('\\n') : '(kosong)';
      return bot.sendMessage(chatId, '👮 *Admin terdaftar:*\\n'+pretty, { parse_mode:'Markdown' });
    });
  }
  if (low.startsWith('/add_admin')) {
    return requireAdmin(msg, () => {
      const id = text.split(/\\s+/,2)[1];
      if (!id) return bot.sendMessage(chatId, '❗ Format: /add_admin <telegram_id>');
      try { adminStore.addAdmin(id); return bot.sendMessage(chatId, '✅ Admin '+id+' ditambahkan.'); }
      catch(e){ return bot.sendMessage(chatId, '❌ Gagal: '+e.message); }
    });
  }
  if (low.startsWith('/remove_admin')) {
    return requireAdmin(msg, () => {
      const id = text.split(/\\s+/,2)[1];
      if (!id) return bot.sendMessage(chatId, '❗ Format: /remove_admin <telegram_id>');
      adminStore.removeAdmin(id);
      return bot.sendMessage(chatId, '🗑️ Admin '+id+' dihapus.');
    });
  }
`);
}

// tambahkan WA manager (Baileys) + command admin WA*
if(!/\/\/ === WhatsApp Manager/.test(s)){
s += `

// === WhatsApp Manager (Baileys) ===
let WA_ENABLED = (String(process.env.WA_ENABLED||'false').toLowerCase()==='true');
let waClient = null, waStateReady = false;
let makeWASocket, useMultiFileAuthState, fetchLatestBaileysVersion;
try {
  ({ default: makeWASocket, useMultiFileAuthState, fetchLatestBaileysVersion } = require("@whiskeysockets/baileys"));
} catch {
  // akan terinstall oleh skrip bash; cegah crash saat require
}

async function waStart(notifyChatId){
  if (waClient || !makeWASocket) { return; }
  const { state, saveCreds } = await useMultiFileAuthState(__dirname + '/wa_auth');
  const { version } = await fetchLatestBaileysVersion().catch(()=>({version:[2,3000,0]}));
  waClient = makeWASocket({ version, auth: state, printQRInTerminal: false, syncFullHistory: false, browser: ['cekrsltele','Chrome','1.0'] });

  waClient.ev.on('creds.update', saveCreds);
  waClient.ev.on('connection.update', (u)=>{
    const { connection, lastDisconnect, qr } = u;
    if (qr && notifyChatId){
      try {
        const qrt = require('qrcode-terminal');
        let ascii = '';
        qrt.generate(qr, { small:true }, (c)=> ascii=c );
        bot.sendMessage(notifyChatId, '📲 *Scan QR WhatsApp berikut di WA Business App*\\n(aktif 60 detik, kirim /wa_pair lagi bila kadaluarsa)\\n\\n```\\n'+ascii+'\\n```', { parse_mode:'Markdown' });
      } catch (e) {
        bot.sendMessage(notifyChatId, 'QR tersedia namun gagal render ASCII: '+e.message);
      }
    }
    if (connection==='open' && notifyChatId){
      bot.sendMessage(notifyChatId, '✅ WhatsApp tersambung.');
    }
    if (connection==='close' && notifyChatId){
      const reason = (lastDisconnect && lastDisconnect.error && lastDisconnect.error?.message) || 'unknown';
      bot.sendMessage(notifyChatId, '❌ WhatsApp terputus: '+reason);
      waClient = null;
      if (WA_ENABLED) setTimeout(()=>waStart(notifyChatId), 5000);
    }
  });
}

async function waStop(){
  try { if (waClient?.ws) waClient.ws.close(); } catch {}
  try { await waClient?.end?.(); } catch {}
  waClient = null;
}

function waStatusText(){
  const up = waClient ? 'CONNECTED' : 'OFFLINE';
  return 'WA_ENABLED='+WA_ENABLED+' | status='+up;
}

// ==== Command admin WA ====
bot.on('message', async (msg)=>{
  const chatId = msg.chat.id; const text = String(msg.text||'').trim().toLowerCase();
  if (text === '/wa_status') {
    return requireAdmin(msg, ()=> bot.sendMessage(chatId, 'ℹ️ '+waStatusText()));
  }
  if (text === '/wa_enable') {
    return requireAdmin(msg, async ()=>{
      WA_ENABLED = true;
      bot.sendMessage(chatId, '🔛 WA enabled. Menjalankan koneksi…');
      await waStart(chatId);
    });
  }
  if (text === '/wa_disable') {
    return requireAdmin(msg, async ()=>{
      WA_ENABLED = false;
      await waStop();
      bot.sendMessage(chatId, '🔴 WA disabled & koneksi ditutup.');
    });
  }
  if (text === '/wa_pair') {
    return requireAdmin(msg, async ()=>{
      if (!WA_ENABLED) bot.sendMessage(chatId, 'ℹ️ WA_ENABLED masih false. Ketik /wa_enable dulu.');
      await waStart(chatId);
    });
  }
});

// Autostart bila WA_ENABLED=true
if (WA_ENABLED) { waStart(null).catch(()=>{}); }
`;
}

process.stdout.write(s);
JS

node .apply.js > bot.js.new
mv bot.js.new bot.js
rm -f .apply.js

echo "==> Tambah .env.example (WA_ENABLED & ADMIN_IDS) bila belum"
grep -q '^WA_ENABLED=' .env.example 2>/dev/null || echo -e "\n# Jalankan WhatsApp saat start (true/false)\nWA_ENABLED=false" >> .env.example
grep -q '^ADMIN_IDS=' .env.example 2>/dev/null || echo -e "\n# Comma separated Telegram user IDs yang diizinkan sebagai admin\nADMIN_IDS=" >> .env.example

echo "==> Tambah default WA_ENABLED ke .env bila belum"
if [ -f .env ]; then
  grep -q '^WA_ENABLED=' .env || echo 'WA_ENABLED=false' >> .env
else
  echo -e "TELEGRAM_BOT_TOKEN=\nWA_ENABLED=false\nADMIN_IDS=\n" > .env
fi

echo "==> Install dependencies WhatsApp"
npm i @whiskeysockets/baileys qrcode-terminal --silent

echo "==> Commit & push"
git add bot.js adminStore.js .env.example .env package.json package-lock.json
git commit -m "feat: add unified WhatsApp manager (Baileys) + admin controls from Telegram"
git pull --rebase origin main || true
git push origin main || true

echo "==> Restart service"
sudo systemctl daemon-reload
sudo systemctl restart cekrsltele
sleep 2
sudo systemctl status cekrsltele --no-pager -l | sed -n '1,18p'

echo "✅ Selesai. Pakai dari Telegram (admin):"
echo "   /wa_status  – cek status"
echo "   /wa_enable  – aktifkan WA (auto connect)"
echo "   /wa_pair    – kirim QR ASCII untuk pairing"
echo "   /wa_disable – matikan WA"
echo "   /admins     – lihat admin | /add_admin <id> | /remove_admin <id>"
