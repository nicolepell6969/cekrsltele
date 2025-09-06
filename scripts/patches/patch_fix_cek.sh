#!/usr/bin/env bash
set -euo pipefail

SERVICE="${SERVICE:-cekrsltele}"

echo "==> Backup bot.js lama"
cp -f bot.js bot.js.bak_fixcek_$(date +%Y%m%d-%H%M%S) 2>/dev/null || true

echo "==> Tulis bot.js baru"
cat > bot.js <<'JS'
// === Load ENV + deps
require('dotenv').config({ path: __dirname + '/.env' });
const fs = require('fs');
const TelegramBot = require('node-telegram-bot-api');

// === Modules opsional (tetap pakai file kamu)
let checkMetroStatus = null;
try { checkMetroStatus = require('./checkMetroStatus'); }
catch { console.error('WARN: checkMetroStatus.js tidak ditemukan. /cek akan gagal.'); }

let adminStore = null;
try { adminStore = require('./adminStore'); adminStore.seedFromEnv?.(); }
catch {
  // fallback sederhana
  const path = require('path'); const FILE = path.join(__dirname,'admins.json');
  function _read(){ try{ if(!fs.existsSync(FILE)) return {admins:[]}; return JSON.parse(fs.readFileSync(FILE,'utf8')||'{"admins":[]}'); }catch{return{admins:[]}} }
  function _write(o){ try{ fs.writeFileSync(FILE, JSON.stringify(o,null,2)); }catch{} }
  function seedFromEnv(){
    const ids = String(process.env.ADMIN_IDS||'').split(',').map(s=>s.trim()).filter(Boolean).map(x=>String(Number(x))).filter(Boolean);
    if (!ids.length) return; const o=_read(); const set=new Set((o.admins||[]).map(String)); ids.forEach(i=>set.add(i)); o.admins=Array.from(set); _write(o);
  }
  function listAdmins(){ return (_read().admins||[]).map(String); }
  function isAdmin(id){ return listAdmins().includes(String(id)); }
  function addAdmin(id){ const sid=String(Number(id)); if(!sid||sid==='NaN') throw new Error('ID tidak valid'); const o=_read(); const set=new Set((o.admins||[]).map(String)); set.add(sid); o.admins=Array.from(set); _write(o); return o.admins; }
  function removeAdmin(id){ const sid=String(Number(id)); const o=_read(); o.admins=(o.admins||[]).map(String).filter(x=>x!==sid); _write(o); return o.admins; }
  adminStore = { seedFromEnv, listAdmins, isAdmin, addAdmin, removeAdmin };
  adminStore.seedFromEnv();
}

// === Helper
const token = process.env.TELEGRAM_BOT_TOKEN || '';
if (!token) { console.error('ERROR: TELEGRAM_BOT_TOKEN kosong di .env'); process.exit(1); }
const bot = new TelegramBot(token, { polling: { interval: 750, autoStart: true } });
bot.getMe().then(me=>console.log(`Telegram bot: @${me.username} (id:${me.id})`)).catch(e=>console.error('getMe error:', e?.message));
bot.on('polling_error', (err)=> console.error('polling_error:', err?.response?.body || err?.message || err));

function isAdmin(id){ return adminStore?.isAdmin?.(id) || false; }
async function notifyAdmins(text){
  try{
    const ids = adminStore?.listAdmins?.() || [];
    for (const sid of ids) { try { await bot.sendMessage(sid, text); } catch {} }
  }catch{}
}
function runWithTimeout(promise, ms=90000){
  return Promise.race([
    promise,
    new Promise((_,rej)=> setTimeout(()=>rej(new Error(`Timeout ${ms}ms`)), ms))
  ]);
}

// === History minimal
const historyFilePath = './history.json';
let history = [];
try { if (fs.existsSync(historyFilePath)) { const raw = fs.readFileSync(historyFilePath); if (raw) history = JSON.parse(raw); } } catch(e){ history = []; }
function saveHistory(){ try{ fs.writeFileSync(historyFilePath, JSON.stringify(history,null,2)); } catch(e){} }
function isDuplicate(ne1, ne2){ return history.some(h => (h.ne1===ne1 && h.ne2===ne2) || (h.ne1===ne2 && h.ne2===ne1)); }
function addHistory(ne1, ne2, result, name, startTime, endTime){
  if (ne2 && isDuplicate(ne1, ne2)) return;
  const ts = new Date(startTime).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' });
  const shortNe1 = (ne1.split('-')[1]||ne1).slice(0,4);
  const shortNe2 = ne2 ? (ne2.split('-')[1]||ne2).slice(0,4) : '';
  const duration = (endTime - startTime) / 1000;
  history.push({ name, ne1, ne2: ne2||'', shortNe1, shortNe2, result, ts, duration });
  saveHistory();
}
function createHistoryButtons(){
  return history.map((entry, idx) => ([
    { text: `Ulangi ${entry.shortNe1}${entry.shortNe2?` ↔ ${entry.shortNe2}`:''}`, callback_data: `retry_${idx}` },
    { text: `Hapus ${entry.shortNe1}${entry.shortNe2?` ↔ ${entry.shortNe2}`:''}`, callback_data: `delete_${idx}` },
  ]));
}

// === FREE TEXT parsing (pakai textToCommand.js)
let buildCekCommandFromText=null;
try { ({ buildCekCommandFromText } = require('./textToCommand')); }
catch { buildCekCommandFromText = (t)=>({cmd:null, list:[], note:'parser tidak ada'}); }

// === Command list
const PUBLIC_COMMANDS = ['/help','/cek','/history'];
const ADMIN_COMMANDS  = ['/add_admin','/remove_admin','/admins']; // WA commands sengaja tidak disini agar tidak mengganggu

// === Handler pesan
bot.on('message', async (msg) => {
  const chatId = msg.chat.id;
  const text = (msg.text || '').trim();
  const low  = text.toLowerCase();

  // ===== Admin: add/remove/list =====
  if (low.startsWith('/add_admin') && isAdmin(chatId)) {
    const id = String((text.split(/\s+/)[1]||'')).trim();
    if (!id) return bot.sendMessage(chatId, 'Format: /add_admin <TELEGRAM_USER_ID>');
    try { adminStore.addAdmin(id); return bot.sendMessage(chatId, `✅ Admin ditambahkan: ${id}`); }
    catch(e){ return bot.sendMessage(chatId, `❌ Gagal tambah admin: ${e.message}`); }
  }
  if (low.startsWith('/remove_admin') && isAdmin(chatId)) {
    const id = String((text.split(/\s+/)[1]||'')).trim();
    if (!id) return bot.sendMessage(chatId, 'Format: /remove_admin <TELEGRAM_USER_ID>');
    try { adminStore.removeAdmin(id); return bot.sendMessage(chatId, `✅ Admin dihapus: ${id}`); }
    catch(e){ return bot.sendMessage(chatId, `❌ Gagal hapus admin: ${e.message}`); }
  }
  if (low === '/admins' && isAdmin(chatId)) {
    const ids = adminStore.listAdmins();
    return bot.sendMessage(chatId, `👑 Admins:\n- ${ids.join('\n- ') || '(kosong)'}`);
  }

  // ===== /help
  if (low === '/help') {
    return bot.sendMessage(chatId,
`📖 *Daftar Perintah*
/cek <NE1> [NE2]  — Cek 1 sisi (NE1) atau 2 sisi (NE1↔NE2)
/history          — Tombol riwayat cek
/help             — Bantuan

Tips:
• Kirim teks bebas berisi log/diagnosa — bot akan mendeteksi NE dan menampilkan tombol "▶️ Jalankan sekarang".`, { parse_mode:'Markdown' });
  }

  // ===== /history
  if (low === '/history') {
    if (!history.length) return bot.sendMessage(chatId, '❌ Belum ada riwayat pengecekan.');
    return bot.sendMessage(chatId, '👉 Klik di bawah untuk cek ulang atau hapus riwayat:', {
      reply_markup: { inline_keyboard: createHistoryButtons() }
    });
  }

  // ===== /cek (robust: /cek[spasi|akhir])
  if (/^\/cek(\s+|$)/.test(low)) {
    const tail  = text.slice(4); // buang '/cek'
    const parts = tail.split(/\s+/).map(s=>s.trim()).filter(Boolean);

    if (parts.length === 0) {
      return bot.sendMessage(chatId, '❗ Format salah.\nContoh:\n• /cek SBY-AAA-EN1-H910D\n• /cek SBY-AAA-EN1-H910D SBY-BBB-OPT-H910D');
    }

    // 1 NE
    if (parts.length === 1) {
      const ne = parts[0];
      await bot.sendMessage(chatId, `🔄 Cek satu NE: ${ne}…`);
      try {
        const start  = Date.now();
        const result = await runWithTimeout(
          checkMetroStatus && checkMetroStatus.checkSingleNE
            ? checkMetroStatus.checkSingleNE(ne)
            : Promise.reject(new Error('checkMetroStatus.checkSingleNE tidak tersedia')), 90000
        );
        const end = Date.now();
        addHistory(ne, null, result, ne, start, end);
        return bot.sendMessage(chatId, `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${result}`);
      } catch(e){
        await notifyAdmins(`🚨 /cek 1 NE gagal oleh ${chatId}\nNE: ${ne}\nError: ${e.message}`);
        return bot.sendMessage(chatId, `❌ Gagal cek NE.\nError: ${e.message}`);
      }
    }

    // 2 NE (ambil 2 pertama saja)
    const ne1 = parts[0], ne2 = parts[1];
    await bot.sendMessage(chatId, `🔄 Cek dua sisi: ${ne1} ↔ ${ne2}…`);
    try {
      const start = Date.now();
      const r1 = await runWithTimeout(checkMetroStatus(ne1, ne2, { mode: 'normal' }), 90000);
      const r2 = await runWithTimeout(checkMetroStatus(ne2, ne1, { mode: 'normal' }), 90000);
      const end = Date.now();
      const combined = `${r1}\n────────────\n${r2}`;
      addHistory(ne1, ne2, combined, `${ne1} ${ne2}`, start, end);
      return bot.sendMessage(chatId, `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${combined}`);
    } catch(e){
      await notifyAdmins(`🚨 /cek 2 NE gagal oleh ${chatId}\nNE1: ${ne1}\nNE2: ${ne2}\nError: ${e.message}`);
      return bot.sendMessage(chatId, `❌ Gagal cek 2 sisi.\nError: ${e.message}`);
    }
  }

  // ===== Callback buttons (cek ulang / hapus / run dari parsing)
  // run dua sisi dari tombol
  if (msg.data) { /* no-op; handled in callback_query */ }

  // ===== FREE TEXT: parsing -> tampilkan tombol (tidak auto-run)
  if (!text.startsWith('/')) {
    try {
      const { cmd, list } = buildCekCommandFromText(text);
      if (list && list.length === 1) {
        const ne = list[0];
        return bot.sendMessage(chatId, `NE terdeteksi: ${ne}\n\nGunakan perintah ini:\n/cek ${ne}`, {
          reply_markup: { inline_keyboard: [[{ text: '▶️ Jalankan sekarang', callback_data: `run1_${ne}` }]] }
        });
      }
      if (list && list.length >= 2) {
        const a = list[0], b = list.find(x=>x!==a) || list[1];
        return bot.sendMessage(chatId, `NE terdeteksi: ${list.join(', ')}\n\nGunakan perintah ini:\n/cek ${a} ${b}`, {
          reply_markup: { inline_keyboard: [[{ text: '▶️ Jalankan sekarang', callback_data: `run2_${a}_${b}` }]] }
        });
      }
    } catch(e){
      await notifyAdmins(`ℹ️ Parser teks gagal: ${e.message}`);
    }
    // Jika bukan perintah & tidak ada NE terdeteksi: diam saja
    return;
  }

  // ===== Warning perintah tak dikenal (hanya untuk public command; admin command dikecualikan)
  const isAdminLike = ADMIN_COMMANDS.some(c => low.startsWith(c)) || low.startsWith('/wa_');
  const isKnownPublic = PUBLIC_COMMANDS.includes(low.split(/\s+/)[0]);
  if (text.startsWith('/') && !isKnownPublic && !isAdminLike) {
    return bot.sendMessage(chatId, 'ℹ️ Perintah tidak dikenali.\nKetik /help untuk daftar perintah.');
  }
});

// ===== callback_query (tombol)
bot.on('callback_query', async (query) => {
  const { data, message } = query;
  const chatId = message.chat.id;
  try {
    await bot.answerCallbackQuery(query.id);

    if (data.startsWith('run1_')) {
      const ne = data.substring('run1_'.length);
      await bot.sendMessage(chatId, `🔄 Checking: ${ne}…`);
      const start = Date.now();
      try {
        const result = await runWithTimeout(
          checkMetroStatus && checkMetroStatus.checkSingleNE
            ? checkMetroStatus.checkSingleNE(ne)
            : Promise.reject(new Error('checkMetroStatus.checkSingleNE tidak tersedia')), 90000
        );
        const end = Date.now();
        addHistory(ne, null, result, ne, start, end);
        return bot.sendMessage(chatId, `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${result}`);
      } catch(e){
        await notifyAdmins(`🚨 run1 gagal: ${ne}\nError: ${e.message}`);
        return bot.sendMessage(chatId, `❌ Gagal cek NE.\nError: ${e.message}`);
      }
    }

    if (data.startsWith('run2_')) {
      const parts = data.substring('run2_'.length).split('_');
      const ne1 = parts[0], ne2 = parts.slice(1).join('_'); // jaga-jaga kalau NE mengandung underscore
      await bot.sendMessage(chatId, `🔄 Checking: ${ne1} ↔ ${ne2}…`);
      const start = Date.now();
      try {
        const r1 = await runWithTimeout(checkMetroStatus(ne1, ne2, { mode: 'normal' }), 90000);
        const r2 = await runWithTimeout(checkMetroStatus(ne2, ne1, { mode: 'normal' }), 90000);
        const end = Date.now();
        const combined = `${r1}\n────────────\n${r2}`;
        addHistory(ne1, ne2, combined, `${ne1} ${ne2}`, start, end);
        return bot.sendMessage(chatId, `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${combined}`);
      } catch(e){
        await notifyAdmins(`🚨 run2 gagal: ${ne1} ↔ ${ne2}\nError: ${e.message}`);
        return bot.sendMessage(chatId, `❌ Gagal cek 2 sisi.\nError: ${e.message}`);
      }
    }

    if (data.startsWith('retry_')) {
      const index = data.startsWith('retry_last_') ? parseInt(data.split('_').pop(),10) : parseInt(data.split('_')[1],10);
      const entry = history[index];
      if (!entry) return;
      if (!entry.ne2) {
        await bot.sendMessage(chatId, `🔄 Checking: ${entry.ne1}…`);
        const start = Date.now();
        try {
          const result = await runWithTimeout(checkMetroStatus.checkSingleNE(entry.ne1), 90000);
          const end = Date.now();
          addHistory(entry.ne1, null, result, entry.ne1, start, end);
          return bot.sendMessage(chatId, `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${result}`);
        } catch(e){
          await notifyAdmins(`🚨 retry 1 gagal: ${entry.ne1}\nError: ${e.message}`);
          return bot.sendMessage(chatId, `❌ Gagal cek NE.\nError: ${e.message}`);
        }
      } else {
        await bot.sendMessage(chatId, `🔄 Checking: ${entry.ne1} ↔ ${entry.ne2}…`);
        const start = Date.now();
        try {
          const r1 = await runWithTimeout(checkMetroStatus(entry.ne1, entry.ne2, { mode: 'normal' }), 90000);
          const r2 = await runWithTimeout(checkMetroStatus(entry.ne2, entry.ne1, { mode: 'normal' }), 90000);
          const end = Date.now();
          const combined = `${r1}\n────────────\n${r2}`;
          addHistory(entry.ne1, entry.ne2, combined, `${entry.ne1} ${entry.ne2}`, start, end);
          return bot.sendMessage(chatId, `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${combined}`);
        } catch(e){
          await notifyAdmins(`🚨 retry 2 gagal: ${entry.ne1} ↔ ${entry.ne2}\nError: ${e.message}`);
          return bot.sendMessage(chatId, `❌ Gagal cek 2 sisi.\nError: ${e.message}`);
        }
      }
    }

    if (data.startsWith('delete_')) {
      const index = parseInt(data.split('_')[1],10);
      const entry = history[index];
      if (entry) {
        history.splice(index,1);
        saveHistory();
        return bot.sendMessage(chatId, `✅ Riwayat ${entry.ne1}${entry.ne2?` ↔ ${entry.ne2}`:''} dihapus.`);
      }
    }
  } catch (e) {
    console.error('callback error:', e);
    await notifyAdmins(`🚨 callback error: ${e.message}`);
    bot.answerCallbackQuery(query.id, { text: '❌ Terjadi kesalahan. Coba lagi!', show_alert: true });
  }
});

// === END bot.js
JS

echo "==> Pastikan ADMIN_IDS ada di .env (kalau belum, tambahkan baris kosong)"
if ! grep -q '^ADMIN_IDS=' .env 2>/dev/null; then
  echo "ADMIN_IDS=" >> .env
fi

echo "==> Install deps minimum (tanpa WA):"
npm i --silent node-telegram-bot-api dotenv >/dev/null 2>&1 || true

echo "==> Restart service"
systemctl daemon-reload || true
systemctl restart "$SERVICE" || true
sleep 1
journalctl -u "$SERVICE" -n 20 --no-pager || true
