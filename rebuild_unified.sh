#!/usr/bin/env bash
set -euo pipefail

git config user.name  "${GIT_NAME:-nicolepell6969}"
git config user.email "${GIT_EMAIL:-ferenrezareynaldo5@gmail.com}"

echo "==> Backup any existing files"
cp -f bot.js bot.js.bak_$(date +%Y%m%d-%H%M%S) 2>/dev/null || true
cp -f adminStore.js adminStore.js.bak_$(date +%Y%m%d-%H%M%S) 2>/dev/null || true

echo "==> Write adminStore.js (admins.json persistence)"
cat > adminStore.js <<'JS'
const fs = require('fs');
const path = require('path');
const FILE = path.join(__dirname, 'admins.json');

function _read() {
  try {
    if (!fs.existsSync(FILE)) return { admins: [] };
    return JSON.parse(fs.readFileSync(FILE, 'utf8') || '{"admins":[]}');
  } catch {
    return { admins: [] };
  }
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

echo "==> Write bot.js (unified Telegram + WhatsApp)"
cat > bot.js <<'JS'
require('dotenv').config({ path: __dirname + '/.env' });

const fs = require('fs');
const TelegramBot = require('node-telegram-bot-api');
const adminStore = require('./adminStore');

let checkMetroStatus;
try { checkMetroStatus = require('./checkMetroStatus'); }
catch { console.error('WARN: checkMetroStatus.js tidak ditemukan. /cek akan gagal.'); checkMetroStatus = null; }

// ===== Admin seed =====
adminStore.seedFromEnv();
function isAdminId(id){ try { return adminStore.isAdmin(id); } catch { return false; } }
function requireAdmin(msg, fn){
  const id = (msg.from && msg.from.id) || msg.chat?.id;
  if (!isAdminId(id)) {
    return bot.sendMessage(msg.chat.id, 'Perintah ini khusus admin. Minta admin menambahkan ID Anda via /add_admin <telegram_id>.');
  }
  return fn();
}

// ===== Telegram init =====
const token = process.env.TELEGRAM_BOT_TOKEN || '';
if (!token) { console.error('ERROR: TELEGRAM_BOT_TOKEN kosong di .env'); process.exit(1); }
const bot = new TelegramBot(token, { polling: { interval: 800, autoStart: true } });
bot.getMe()
  .then(me => console.log(`Telegram bot: @${me.username} (id:${me.id})`))
  .catch(err => console.error('getMe error:', err?.message));
bot.on('polling_error', (err)=> console.error('polling_error:', err?.response?.body || err));

// ===== History sederhana =====
const historyFilePath = './history.json';
let history = [];
try { if (fs.existsSync(historyFilePath)) { const raw = fs.readFileSync(historyFilePath,'utf8'); if (raw) history = JSON.parse(raw); } }
catch { history = []; }
function saveHistory(){ try{ fs.writeFileSync(historyFilePath, JSON.stringify(history,null,2)); }catch{} }
function isDuplicate(ne1, ne2){ return history.some(h => (h.ne1===ne1 && h.ne2===ne2) || (h.ne1===ne2 && h.ne2===ne1)); }
function addHistory(ne1, ne2, result, name, startTime, endTime){
  if (ne2 && isDuplicate(ne1, ne2)) return;
  const timestamp = new Date(startTime).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' });
  const shortNe1 = (String(ne1).split('-')[1]||ne1).slice(0,4);
  const shortNe2 = ne2 ? (String(ne2).split('-')[1]||ne2).slice(0,4) : '';
  const duration = (endTime - startTime) / 1000;
  history.push({ name, ne1, ne2: ne2||'', shortNe1, shortNe2, result, timestamp, duration });
  saveHistory();
}

// ===== Helper timeout umum =====
function runWithTimeout(promise, ms, tag='op'){
  return Promise.race([
    promise,
    new Promise((_,rej)=>setTimeout(()=>rej(new Error('Timeout '+ms+'ms @'+tag)), ms))
  ]);
}

// ===== WhatsApp Manager (Baileys) =====
let WA_ENABLED = (String(process.env.WA_ENABLED||'false').toLowerCase()==='true');
let waClient = null;
let makeWASocket, useMultiFileAuthState, fetchLatestBaileysVersion;
try {
  ({ default: makeWASocket, useMultiFileAuthState, fetchLatestBaileysVersion } = require("@whiskeysockets/baileys"));
} catch {
  // akan di-install oleh skrip shell
}

async function waStart(notifyChatId){
  if (waClient || !makeWASocket) return;
  const { state, saveCreds } = await useMultiFileAuthState(__dirname + '/wa_auth');
  let version = [2,3000,0];
  try { ({ version } = await fetchLatestBaileysVersion()); } catch {}
  const sock = makeWASocket({ version, auth: state, printQRInTerminal: false, syncFullHistory: false, browser: ['cekrsltele','Chrome','1.0']});
  waClient = sock;
  sock.ev.on('creds.update', saveCreds);
  sock.ev.on('connection.update', (u)=>{
    const { connection, lastDisconnect, qr } = u;
    if (qr && notifyChatId){
      try {
        const qrt = require('qrcode-terminal');
        let ascii = '';
        qrt.generate(qr, { small:true }, (c)=> ascii=c );
        bot.sendMessage(notifyChatId, 'QR WhatsApp (scan di aplikasi WhatsApp):\n\n'+ascii);
      } catch (e) {
        bot.sendMessage(notifyChatId, 'QR tersedia namun gagal dirender: '+e.message);
      }
    }
    if (connection==='open' && notifyChatId){
      bot.sendMessage(notifyChatId, 'WhatsApp tersambung.');
    }
    if (connection==='close' && notifyChatId){
      const reason = (lastDisconnect && lastDisconnect.error && lastDisconnect.error?.message) || 'unknown';
      bot.sendMessage(notifyChatId, 'WhatsApp terputus: '+reason);
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

// ===== Handler pesan Telegram =====
bot.on('message', async (msg) => {
  const chatId = msg.chat.id;
  const text = String(msg.text || '').trim();
  const low = text.toLowerCase();

  // Guard unknown command: hanya untuk command publik & admin yang tidak dikenal.
  const PUBLIC_CMDS = new Set(['/cek','/history','/help']);
  const ADMIN_CMDS  = new Set(['/admins','/add_admin','/remove_admin','/wa_status','/wa_enable','/wa_disable','/wa_pair']);
  const cmdMatch = text.startsWith('/') ? text.split(/\s+/,1)[0].toLowerCase() : '';
  if (cmdMatch && !PUBLIC_CMDS.has(cmdMatch) && !ADMIN_CMDS.has(cmdMatch)) {
    return bot.sendMessage(chatId, "Perintah tidak dikenali.\nKetik /help untuk daftar perintah.");
  }

  // Help
  if (low === '/help' || low === '/start') {
    const help = [
      'Daftar Perintah:',
      '',
      '/cek NE_A NE_B   -> cek dua sisi',
      '/cek NE_A        -> cek satu NE (RX & Port)',
      '/history         -> riwayat pengecekan',
      '/help            -> bantuan',
      '',
      'Admin:',
      '/admins, /add_admin <id>, /remove_admin <id>',
      '/wa_status, /wa_enable, /wa_disable, /wa_pair',
    ].join('\n');
    return bot.sendMessage(chatId, help);
  }

  // Admin cmds
  if (low === '/admins') {
    return requireAdmin(msg, () => {
      const list = adminStore.listAdmins();
      const pretty = list.length ? list.map(x => '- '+x).join('\n') : '(kosong)';
      return bot.sendMessage(chatId, 'Admin terdaftar:\n'+pretty);
    });
  }
  if (low.startsWith('/add_admin')) {
    return requireAdmin(msg, () => {
      const id = text.split(/\s+/,2)[1];
      if (!id) return bot.sendMessage(chatId, 'Format: /add_admin <telegram_id>');
      try { adminStore.addAdmin(id); return bot.sendMessage(chatId, 'Admin '+id+' ditambahkan.'); }
      catch(e){ return bot.sendMessage(chatId, 'Gagal: '+e.message); }
    });
  }
  if (low.startsWith('/remove_admin')) {
    return requireAdmin(msg, () => {
      const id = text.split(/\s+/,2)[1];
      if (!id) return bot.sendMessage(chatId, 'Format: /remove_admin <telegram_id>');
      adminStore.removeAdmin(id);
      return bot.sendMessage(chatId, 'Admin '+id+' dihapus.');
    });
  }
  if (low === '/wa_status') {
    return requireAdmin(msg, ()=> bot.sendMessage(chatId, waStatusText()));
  }
  if (low === '/wa_enable') {
    return requireAdmin(msg, async ()=>{
      WA_ENABLED = true;
      bot.sendMessage(chatId, 'WA enabled. Menghubungkan...');
      await waStart(chatId);
    });
  }
  if (low === '/wa_disable') {
    return requireAdmin(msg, async ()=>{
      WA_ENABLED = false;
      await waStop();
      bot.sendMessage(chatId, 'WA disabled. Koneksi ditutup.');
    });
  }
  if (low === '/wa_pair') {
    return requireAdmin(msg, async ()=>{
      if (!WA_ENABLED) bot.sendMessage(chatId, 'WA_ENABLED masih false. Jalankan /wa_enable lebih dulu.');
      await waStart(chatId);
    });
  }

  // History
  if (low === '/history') {
    if (!history.length) return bot.sendMessage(chatId, 'Belum ada riwayat.');
    const buttons = history.map((entry, idx) => ([
      { text: `Ulangi ${entry.shortNe1}${entry.shortNe2?` ↔ ${entry.shortNe2}`:''}`, callback_data: `retry_${idx}` },
      { text: `Hapus ${entry.shortNe1}${entry.shortNe2?` ↔ ${entry.shortNe2}`:''}`, callback_data: `delete_${idx}` },
    ]));
    return bot.sendMessage(chatId, 'Klik untuk cek ulang atau hapus riwayat:', {
      reply_markup: { inline_keyboard: buttons }
    });
  }

  // /cek
  if (low.startsWith('/cek ')) {
    if (!checkMetroStatus) return bot.sendMessage(chatId, 'checkMetroStatus.js tidak tersedia di server.');
    const parts = text.split(' ').slice(1).map(s => s.trim()).filter(Boolean);

    // 1 NE
    if (parts.length === 1) {
      const ne = parts[0];
      await bot.sendMessage(chatId, 'Cek satu NE: '+ne+' ...');
      try {
        const start = Date.now();
        const result = await runWithTimeout(checkMetroStatus.checkSingleNE(ne), 90000, 'cek-1NE');
        const end = Date.now();
        addHistory(ne, null, result, ne, start, end);
        return bot.sendMessage(chatId, `Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${result}`);
      } catch (e) {
        return bot.sendMessage(chatId, 'Gagal cek 1 NE: '+e.message);
      }
    }

    // 2 NE
    if (parts.length === 2) {
      const [ne1, ne2] = parts;
      await bot.sendMessage(chatId, 'ONCEK, DITUNGGU');
      try {
        const start = Date.now();
        const r1 = await runWithTimeout(checkMetroStatus(ne1, ne2, { mode: 'normal' }), 90000, 'cek-A');
        const r2 = await runWithTimeout(checkMetroStatus(ne2, ne1, { mode: 'normal' }), 90000, 'cek-B');
        const end = Date.now();
        const combined = `${r1}\n────────────\n${r2}`;
        addHistory(ne1, ne2, combined, `${ne1} ${ne2}`, start, end);
        return bot.sendMessage(chatId, `Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${combined}`, {
          reply_markup: { inline_keyboard: [[{ text: 'Cek ulang', callback_data: `retry_last_${history.length-1}` }]] }
        });
      } catch (e) {
        return bot.sendMessage(chatId, 'Gagal cek 2 sisi: '+e.message);
      }
    }

    return bot.sendMessage(chatId, 'Format: /cek <NE1> [NE2]');
  }

  // Teks bebas: parser opsional (jika ada textToCommand.js)
  try {
    const { buildCekCommandFromText } = require('./textToCommand');
    const parsed = buildCekCommandFromText(text);
    const list = parsed?.list || [];
    if (list.length === 1) {
      const ne = list[0];
      return bot.sendMessage(chatId, `Ditemukan 1 NE dari teks.\nGunakan:\n/cek ${ne}`, {
        reply_markup: { inline_keyboard: [[{ text: 'Jalankan sekarang', callback_data: `runcek1_${ne}` }]] }
      });
    }
    if (list.length >= 2) {
      const a = list[0], b = list.find(x => x !== a) || list[1];
      return bot.sendMessage(chatId, `NE terdeteksi: ${list.join(', ')}\nGunakan:\n/cek ${a} ${b}`, {
        reply_markup: { inline_keyboard: [[{ text: 'Jalankan sekarang', callback_data: `runcek_${a}_${b}` }]] }
      });
    }
  } catch {}
});

// Callbacks
bot.on('callback_query', async (query) => {
  const { data, message } = query;
  const chatId = message.chat.id;
  try {
    await bot.answerCallbackQuery(query.id);

    if (data.startsWith('runcek_')) {
      if (!checkMetroStatus) return bot.sendMessage(chatId, 'checkMetroStatus.js tidak tersedia.');
      const [, ne1, ne2] = data.split('_');
      await bot.sendMessage(chatId, 'Checking: '+ne1+' ↔ '+ne2+' ...');
      const r1 = await checkMetroStatus(ne1, ne2, { mode: 'normal' });
      const r2 = await checkMetroStatus(ne2, ne1, { mode: 'normal' });
      const end = Date.now();
      return bot.sendMessage(chatId, `Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${r1}\n────────────\n${r2}`, {
        reply_markup: { inline_keyboard: [[{ text: 'Cek ulang', callback_data: `runcek_${ne1}_${ne2}` }]] }
      });
    }

    if (data.startsWith('runcek1_')) {
      if (!checkMetroStatus) return bot.sendMessage(chatId, 'checkMetroStatus.js tidak tersedia.');
      const ne = data.substring('runcek1_'.length);
      await bot.sendMessage(chatId, 'Checking: '+ne+' ...');
      const result = await checkMetroStatus.checkSingleNE(ne);
      const end = Date.now();
      return bot.sendMessage(chatId, `Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${result}`, {
        reply_markup: { inline_keyboard: [[{ text: 'Cek ulang', callback_data: `runcek1_${ne}` }]] }
      });
    }

    if (data.startsWith('retry_')) {
      let index = null;
      if (data.startsWith('retry_last_')) index = parseInt(data.split('_').pop(), 10);
      else index = parseInt(data.split('_')[1], 10);
      const entry = history[index];
      if (entry) {
        if (!entry.ne2) {
          await bot.sendMessage(chatId, 'Checking: '+entry.ne1+' ...');
          const result = await checkMetroStatus.checkSingleNE(entry.ne1);
          const end = Date.now();
          return bot.sendMessage(chatId, `Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${result}`, {
            reply_markup: { inline_keyboard: [[{ text: 'Cek ulang', callback_data: `runcek1_${entry.ne1}` }]] }
          });
        } else {
          await bot.sendMessage(chatId, 'Checking: '+entry.ne1+' ↔ '+entry.ne2+' ...');
          const r1 = await checkMetroStatus(entry.ne1, entry.ne2, { mode: 'normal' });
          const r2 = await checkMetroStatus(entry.ne2, entry.ne1, { mode: 'normal' });
          const end = Date.now();
          return bot.sendMessage(chatId, `Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${r1}\n────────────\n${r2}`, {
            reply_markup: { inline_keyboard: [[{ text: 'Cek ulang', callback_data: `runcek_${entry.ne1}_${entry.ne2}` }]] }
          });
        }
      }
    }

    if (data.startsWith('delete_')) {
      const index = parseInt(data.split('_')[1], 10);
      const entry = history[index];
      if (entry) {
        history.splice(index, 1);
        saveHistory();
        return bot.sendMessage(chatId, `Riwayat ${entry.ne1}${entry.ne2?` ↔ ${entry.ne2}`:''} dihapus.`);
      }
    }
  } catch (e) {
    console.error('callback error:', e);
    bot.answerCallbackQuery(query.id, { text: 'Terjadi kesalahan. Coba lagi.', show_alert: true });
  }
});

// Graceful shutdown
function quit(){ try{bot.stopPolling();}catch{} setTimeout(()=>process.exit(0),500);} 
process.on("SIGTERM", quit);
process.on("SIGINT", quit);

// Autostart WA jika WA_ENABLED=true
if (WA_ENABLED) { waStart(null).catch(()=>{}); }
JS

echo "==> Update .env.example and .env defaults"
grep -q '^WA_ENABLED=' .env.example 2>/dev/null || echo -e "\n# Jalankan WhatsApp saat start (true/false)\nWA_ENABLED=false" >> .env.example
grep -q '^ADMIN_IDS=' .env.example 2>/dev/null || echo -e "\n# Comma separated Telegram user IDs yang diizinkan sebagai admin\nADMIN_IDS=" >> .env.example
if [ -f .env ]; then
  grep -q '^WA_ENABLED=' .env || echo 'WA_ENABLED=false' >> .env
  grep -q '^ADMIN_IDS=' .env || echo 'ADMIN_IDS=' >> .env
else
  echo -e "TELEGRAM_BOT_TOKEN=\nWA_ENABLED=false\nADMIN_IDS=\n" > .env
fi

echo "==> Install WhatsApp deps"
npm i @whiskeysockets/baileys qrcode-terminal --silent

echo "==> Commit & push"
git add bot.js adminStore.js .env.example .env package.json package-lock.json
git commit -m "feat: unified Telegram+WhatsApp bot with admin controls and QR via Telegram"
git pull --rebase origin main || true
git push origin main || true

echo "==> Restart service"
systemctl daemon-reload || true
systemctl restart cekrsltele || true
sleep 2
systemctl status cekrsltele --no-pager -l | sed -n '1,18p'

echo "DONE. Dari Telegram (admin):"
echo "  /wa_status  (cek status)"
echo "  /wa_enable  (aktifkan WA, lalu /wa_pair untuk QR)"
echo "  /wa_disable (matikan WA)"
echo "  /admins | /add_admin <id> | /remove_admin <id>"
