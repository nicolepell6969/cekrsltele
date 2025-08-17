// === CRYPTO SHIM (untuk Baileys) ===
(() => {
  try {
    const nodeCrypto = require('node:crypto');
    if (!globalThis.crypto) globalThis.crypto = nodeCrypto.webcrypto || nodeCrypto;
  } catch {
    try {
      const c = require('crypto');
      if (!globalThis.crypto) globalThis.crypto = c;
    } catch {}
  }
})();
require('dotenv').config({ path: __dirname + '/.env' });

const fs = require('fs');
const path = require('path');
const TelegramBot = require('node-telegram-bot-api');
const QR = require('qrcode');

// ===== Dependencies opsional (WhatsApp) =====
let makeWASocket, useMultiFileAuthState, fetchLatestBaileysVersion;
try { ({ default: makeWASocket, useMultiFileAuthState, fetchLatestBaileysVersion } = require('@whiskeysockets/baileys')); } catch {}

let checkMetroStatus = null;
try { checkMetroStatus = require('./checkMetroStatus'); }
catch { console.error('WARN: checkMetroStatus.js tidak ditemukan'); }

// ===== Admin store (persisten) =====
let adminStore = null;
try { adminStore = require('./adminStore'); adminStore.seedFromEnv?.(); }
catch {
  const FILE = path.join(__dirname,'admins.json');
  function _read(){ try{ if(!fs.existsSync(FILE)) return {admins:[]}; return JSON.parse(fs.readFileSync(FILE,'utf8')||'{"admins":[]}'); }catch{return{admins:[]}} }
  function _write(o){ try{ fs.writeFileSync(FILE, JSON.stringify(o,null,2)); }catch{} }
  function seedFromEnv(){
    const ids=String(process.env.ADMIN_IDS||'').split(',').map(s=>s.trim()).filter(Boolean).map(x=>String(Number(x))).filter(Boolean);
    if(!ids.length) return; const o=_read(); const set=new Set((o.admins||[]).map(String)); ids.forEach(i=>set.add(i)); o.admins=[...set]; _write(o);
  }
  function listAdmins(){ return (_read().admins||[]).map(String); }
  function isAdmin(id){ return listAdmins().includes(String(id)); }
  function addAdmin(id){ const sid=String(Number(id)); if(!sid||sid==='NaN') throw new Error('ID tidak valid'); const o=_read(); const set=new Set((o.admins||[]).map(String)); set.add(sid); o.admins=[...set]; _write(o); return o.admins; }
  function removeAdmin(id){ const sid=String(Number(id)); const o=_read(); o.admins=(o.admins||[]).map(String).filter(x=>x!==sid); _write(o); return o.admins; }
  adminStore = { seedFromEnv, listAdmins, isAdmin, addAdmin, removeAdmin };
  adminStore.seedFromEnv();
}

// ===== Telegram init =====
const token = process.env.TELEGRAM_BOT_TOKEN || '';
if (!token) { console.error('ERROR: TELEGRAM_BOT_TOKEN kosong di .env'); process.exit(1); }
const bot = new TelegramBot(token, { polling: { interval: 800, autoStart: true } });

// ===== Helper: kirim panjang aman =====
async function sendLong(chatId, text, extra = {}) {
  const MAX = 3900; // buffer <4096
  const t = String(text ?? '');
  if (t.length <= MAX) return bot.sendMessage(chatId, t, extra);

  const lines = t.split('\n'); let buf = '';
  let msg;
  for (const line of lines) {
    const would = buf ? (buf + '\n' + line) : line;
    if (would.length > MAX) { msg = await bot.sendMessage(chatId, buf, extra); buf = line; }
    else { buf = would; }
  }
  if (buf) msg = await bot.sendMessage(chatId, buf, extra);
  return msg;
}

// ===== History store =====
const HISTORY_FILE = path.join(__dirname, 'history.json');
let history = [];
function loadHistory(){
  try { if (fs.existsSync(HISTORY_FILE)) history = JSON.parse(fs.readFileSync(HISTORY_FILE,'utf8')||'[]'); }
  catch { history = []; }
}
function saveHistory(){
  try { fs.writeFileSync(HISTORY_FILE, JSON.stringify(history,null,2)); } catch {}
}
function addHistory(ne1, ne2, text, label, start, end){
  history.push({ ne1, ne2, text, label, at: end, dur_ms: (end-start) });
  saveHistory();
}
function createHistoryButtons(){
  const rows = [];
  history.forEach((h, idx) => {
    const title = h.ne2 ? `${h.ne1} ↔ ${h.ne2}` : h.ne1;
    rows.push([
      { text: `▶️ ${title}`, callback_data: h.ne2 ? `retry_${idx}` : `retry1_${idx}` },
      { text: '🗑️ Hapus', callback_data: `delete_${idx}` }
    ]);
  });
  return rows;
}
loadHistory();

// ===== WA state =====
let WA_ENABLED = (String(process.env.WA_ENABLED||'false').toLowerCase()==='true');
let waClient = null;

async function waStart(notifyChatId){
  if (!WA_ENABLED) return bot.sendMessage(notifyChatId, 'ℹ️ WhatsApp tidak diaktifkan. Set WA_ENABLED=true di .env dan restart.');
  if (waClient) return bot.sendMessage(notifyChatId, 'ℹ️ WhatsApp sudah tersambung (atau proses login berjalan).');
  if (!makeWASocket || !useMultiFileAuthState) return bot.sendMessage(notifyChatId, '❌ Library Baileys tidak terpasang.');

  const { state, saveCreds } = await useMultiFileAuthState(path.join(__dirname,'wa_auth'));
  let version = [2,3000,0]; try { ({ version } = await fetchLatestBaileysVersion()); } catch {}

  const sock = makeWASocket({
    version, auth: state, printQRInTerminal:false, syncFullHistory:false, browser:['cekrsltele','Chrome','1.0']
  });

  sock.ev.on('connection.update', async (u)=>{
    const { qr, connection, lastDisconnect } = u;
    if (qr && notifyChatId){
      try {
        const buf = await QR.toBuffer(qr, { type: 'png', scale: 6, margin: 1 });
        await bot.sendPhoto(notifyChatId, buf, { caption: '📲 Scan QR WhatsApp (±60 detik). Jika kadaluarsa, kirim /wa_pair lagi.' });
      } catch (e) {
        try {
          const qrt = require('qrcode-terminal');
          let ascii = ''; qrt.generate(qr, { small: true }, c => ascii = c);
          await bot.sendMessage(notifyChatId, 'QR WhatsApp (ASCII):\n\n' + ascii);
        } catch {}
      }
    }
    if (connection === 'open') {
      waClient = sock;
      if (notifyChatId) bot.sendMessage(notifyChatId, '✅ WhatsApp tersambung.');
    } else if (connection === 'close') {
      if (notifyChatId) bot.sendMessage(notifyChatId, '⚠️ WhatsApp terputus: ' + ((lastDisconnect && lastDisconnect.error && lastDisconnect.error.message) || 'Terputus'));
      waClient = null;
    }
  });

  sock.ev.on('creds.update', saveCreds);
}

// ===== Utility =====
function isAdmin(chatId){ try { return adminStore.isAdmin(String(chatId)); } catch { return false; } }
function runWithTimeout(promise, ms=180000){
  return new Promise((resolve, reject)=>{
    const to = setTimeout(()=> reject(new Error('Timeout')), ms);
    promise.then(v=>{ clearTimeout(to); resolve(v); }).catch(e=>{ clearTimeout(to); reject(e); });
  });
}

// ===== Bot ready =====
bot.getMe().then(me=>console.log(`Telegram bot: @${me.username} (id:${me.id})`)).catch(e=>console.error('getMe error:', e?.message));
bot.on('polling_error', (err)=> console.error('polling_error:', err?.response?.body || err?.message || err));

// ===== Command handler =====
bot.on('message', async (msg) => {
  const chatId = msg.chat.id;
  const text = (msg.text || '').trim();
  const low = text.toLowerCase();

  // /help
  if (low === '/help'){
    const helpText =
`📋 *Perintah Utama*
/help — daftar perintah
/cek <NE1> [NE2] — cek RX (2 sisi bila 2 NE)
/history — tombol riwayat

📋 *Admin*
/add_admin <id>
/remove_admin <id>
/admins — list admin

📲 *WhatsApp*
/wa_status
/wa_enable
/wa_disable
/wa_pair — kirim QR ke sini`;
    return bot.sendMessage(chatId, helpText, { parse_mode: 'Markdown' });
  }

  // /admins, /add_admin, /remove_admin
  if (low.startsWith('/admins')){
    const admins = adminStore.listAdmins();
    return bot.sendMessage(chatId, `👮 Admins: ${admins.length ? admins.join(', ') : '(kosong)'}`);
  }
  if (low.startsWith('/add_admin')){
    if (!isAdmin(chatId)) return bot.sendMessage(chatId, '❌ Hanya admin yang bisa menambah admin.');
    const id = text.split(/\s+/)[1];
    if (!id) return bot.sendMessage(chatId, '⚠️ Format: /add_admin <id>');
    try { adminStore.addAdmin(id); return bot.sendMessage(chatId, `✅ Admin ditambah: ${id}`); }
    catch(e){ return bot.sendMessage(chatId, '❌ '+(e?.message||e)); }
  }
  if (low.startsWith('/remove_admin')){
    if (!isAdmin(chatId)) return bot.sendMessage(chatId, '❌ Hanya admin yang bisa menghapus admin.');
    const id = text.split(/\s+/)[1];
    if (!id) return bot.sendMessage(chatId, '⚠️ Format: /remove_admin <id>');
    try { adminStore.removeAdmin(id); return bot.sendMessage(chatId, `✅ Admin dihapus: ${id}`); }
    catch(e){ return bot.sendMessage(chatId, '❌ '+(e?.message||e)); }
  }

  // /wa_status, /wa_enable, /wa_disable, /wa_pair
  if (low === '/wa_status'){
    const state = WA_ENABLED ? (waClient ? 'tersambung' : 'belum tersambung') : 'non-aktif';
    return bot.sendMessage(chatId, `📲 WA: ${state}`);
  }
  if (low === '/wa_enable'){
    if (!isAdmin(chatId)) return bot.sendMessage(chatId, '❌ Hanya admin.');
    WA_ENABLED = true;
    return bot.sendMessage(chatId, '✅ WA_ENABLED = true. Jalankan /wa_pair untuk login atau restart service.');
  }
  if (low === '/wa_disable'){
    if (!isAdmin(chatId)) return bot.sendMessage(chatId, '❌ Hanya admin.');
    WA_ENABLED = false;
    try { if (waClient?.end) await waClient.end(); } catch {}
    waClient = null;
    return bot.sendMessage(chatId, '✅ WA dinonaktifkan.');
  }
  if (low === '/wa_pair'){
    if (!isAdmin(chatId)) return bot.sendMessage(chatId, '❌ Hanya admin.');
    return waStart(chatId);
  }

  // /history
  if (low === '/history') {
    if (!history.length) return bot.sendMessage(chatId, '❌ Belum ada riwayat pengecekan.');
    return bot.sendMessage(chatId, '👉 Klik di bawah untuk cek ulang atau hapus riwayat:', {
      reply_markup: { inline_keyboard: createHistoryButtons() }
    });
  }

  // /cek <NE1> [NE2]
  if (low.startsWith('/cek')){
    const parts = text.split(/\s+/).slice(1).filter(Boolean);
    if (parts.length === 0) return bot.sendMessage(chatId, '❗ Format: /cek <NE1> [NE2]');

    // satu NE → tampil semua RX untuk NE tsb
    if (parts.length === 1) {
      const ne = parts[0];
      const m = await bot.sendMessage(chatId, `🔄 Checking: ${ne}...`);
      try {
        const start = Date.now();
        const result = await runWithTimeout(checkMetroStatus.checkSingleNE(ne), Number(process.env.CEK_TIMEOUT_MS || 120000));
        const end = Date.now();
        const finalText = `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${result}`;
        return bot.editMessageText(finalText, { chat_id: chatId, message_id: m.message_id });
      } catch(e){
        return bot.editMessageText('❌ Gagal cek 1 NE: '+(e?.message||e), { chat_id: chatId, message_id: m.message_id });
      }
    }

    // dua NE → HANYA satu panggilan (tidak dobel)
    if (parts.length >= 2) {
      const ne1 = parts[0], ne2 = parts[1];
      const m = await bot.sendMessage(chatId, `🔄 Checking: ${ne1} ↔ ${ne2}...`);
      try {
        const start = Date.now();
        // Penting: cukup SEKALI panggil, checkMetroStatus sudah mengeluarkan 2 sisi
        const combined = await runWithTimeout(checkMetroStatus(ne1, ne2, { mode: 'normal' }), Number(process.env.CEK_TIMEOUT_MS || 180000));
        const end = Date.now();
        const finalText = `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${combined}`;
        addHistory(ne1, ne2, finalText, `${ne1} ${ne2}`, start, end);
        return bot.editMessageText(finalText, {
          chat_id: chatId,
          message_id: m.message_id,
          reply_markup: { inline_keyboard: [[{ text: '🔁 CEK ULANG', callback_data: `retry_last_${history.length-1}_${m.message_id}` }]] }
        });
      } catch(e){
        return bot.editMessageText('❌ Gagal cek 2 sisi: '+(e?.message||e), { chat_id: chatId, message_id: m.message_id });
      }
    }
  }

  // Teks bebas → parsing (opsional)
  // (Biarkan minimal supaya tidak spam)
});

// ===== Callback (cek ulang, run now, hapus) =====
bot.on('callback_query', async (q)=>{
  const { data, message } = q;
  const chatId = message.chat.id;
  const msgId = message.message_id;
  try {
    await bot.answerCallbackQuery(q.id);

    // retry terakhir dengan edit pesan yang sama
    if (data.startsWith('retry_last_')) {
      const parts = data.split('_'); // retry_last_{idx}_{origMsgId?}
      const idx = parseInt(parts[2], 10);
      const origMsgId = parts[3] ? Number(parts[3]) : msgId;
      const e = history[idx];
      if (!e) return;

      await bot.editMessageText('🔄 Checking ulang...', { chat_id: chatId, message_id: origMsgId });
      if (!e.ne2) {
        const start = Date.now();
        const result = await runWithTimeout(checkMetroStatus.checkSingleNE(e.ne1), Number(process.env.CEK_TIMEOUT_MS || 120000));
        const end = Date.now();
        const finalText = `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${result}`;
        return bot.editMessageText(finalText, {
          chat_id: chatId, message_id: origMsgId,
          reply_markup: { inline_keyboard: [[{ text: '🔁 Cek ulang', callback_data: `retry_last_${idx}_${origMsgId}` }]] }
        });
      } else {
        const start = Date.now();
        // Satu panggilan saja agar tidak dobel
        const combined = await runWithTimeout(checkMetroStatus(e.ne1, e.ne2, { mode: 'normal' }), Number(process.env.CEK_TIMEOUT_MS || 180000));
        const end = Date.now();
        const finalText = `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${combined}`;
        return bot.editMessageText(finalText, {
          chat_id: chatId, message_id: origMsgId,
          reply_markup: { inline_keyboard: [[{ text: '🔁 Cek ulang', callback_data: `retry_last_${idx}_${origMsgId}` }]] }
        });
      }
    }

    // retry by index (dari /history)
    if (data.startsWith('retry_')) {
      const idx = parseInt(data.split('_')[1], 10);
      const e = history[idx];
      if (!e) return;
      await bot.editMessageText('🔄 Checking ulang...', { chat_id: chatId, message_id: msgId });

      if (!e.ne2) {
        const start = Date.now();
        const result = await runWithTimeout(checkMetroStatus.checkSingleNE(e.ne1), Number(process.env.CEK_TIMEOUT_MS || 120000));
        const end = Date.now();
        const finalText = `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${result}`;
        return bot.editMessageText(finalText, {
          chat_id: chatId, message_id: msgId,
          reply_markup: { inline_keyboard: [[{ text: '🔁 Cek ulang', callback_data: `retry_${idx}` }]] }
        });
      } else {
        const start = Date.now();
        const combined = await runWithTimeout(checkMetroStatus(e.ne1, e.ne2, { mode: 'normal' }), Number(process.env.CEK_TIMEOUT_MS || 180000));
        const end = Date.now();
        const finalText = `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${combined}`;
        return bot.editMessageText(finalText, {
          chat_id: chatId, message_id: msgId,
          reply_markup: { inline_keyboard: [[{ text: '🔁 Cek ulang', callback_data: `retry_${idx}` }]] }
        });
      }
    }

    // delete index (update keyboard tanpa /history lagi)
    if (data.startsWith('delete_')) {
      const index = parseInt(data.split('_')[1], 10);
      const e = history[index];
      if (!e) return;

      history.splice(index,1); saveHistory();
      const kb = createHistoryButtons();
      const caption = kb.length ? '👉 Klik di bawah untuk cek ulang atau hapus riwayat:' : '✅ Riwayat kosong.';
      return bot.editMessageText(caption, {
        chat_id: chatId, message_id: msgId,
        reply_markup: { inline_keyboard: kb }
      });
    }
  } catch(err){
    console.error('callback error:', err);
    bot.answerCallbackQuery(q.id, { text: '❌ Terjadi kesalahan. Coba lagi!', show_alert: true }).catch(()=>{});
  }
});

// ===== Notifier penting =====
function notifyAdmins(text){
  try {
    const admins = adminStore.listAdmins();
    const target = admins[0];
    if (target) bot.sendMessage(Number(target), text).catch(()=>{});
  } catch {}
}
process.on('unhandledRejection', err=> notifyAdmins('⚠️ unhandledRejection: '+(err?.message||err)));
process.on('uncaughtException', err=> { notifyAdmins('⚠️ uncaughtException: '+(err?.message||err)); setTimeout(()=>process.exit(1), 500); });

// ===== Global error handlers (admin ping) =====
process.on('unhandledRejection', async (err) => {
  try { await bot.sendMessage(adminStore.listAdmins()[0], '❗ *UnhandledRejection*\n' + (err?.stack || err), { parse_mode:'Markdown' }); } catch {}
});
process.on('uncaughtException', async (err) => {
  try { await bot.sendMessage(adminStore.listAdmins()[0], '❗ *UncaughtException*\n' + (err?.stack || err), { parse_mode:'Markdown' }); } catch {}
  setTimeout(() => process.exit(1), 500);
});
