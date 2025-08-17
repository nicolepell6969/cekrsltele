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

/* ================== Imports & Globals ================== */
const fs = require('fs');
const path = require('path');
const TelegramBot = require('node-telegram-bot-api');

let checkMetroStatus = null;
try { checkMetroStatus = require('./checkMetroStatus'); }
catch { console.error('WARN: checkMetroStatus.js tidak ditemukan'); }

let { buildCekCommandFromText } = (() => {
  try { return require('./textToCommand'); }
  catch { return { buildCekCommandFromText: (t)=>({cmd:null,list:[],note:'modul textToCommand.js tidak ada'}) }; }
})();

let adminStore = null;
try { adminStore = require('./adminStore'); adminStore.seedFromEnv?.(); }
catch {
  const FILE = path.join(__dirname,'admins.json');
  function _read(){ try{ if(!fs.existsSync(FILE)) return {admins:[]}; return JSON.parse(fs.readFileSync(FILE,'utf8')||'{"admins":[]}'); }catch{return{admins:[]}} }
  function _write(o){ try{ fs.writeFileSync(FILE, JSON.stringify(o,null,2)); }catch{} }
  function seedFromEnv(){ const ids=String(process.env.ADMIN_IDS||'').split(',').map(s=>s.trim()).filter(Boolean).map(x=>String(Number(x))).filter(Boolean); if(!ids.length) return; const o=_read(); const set=new Set((o.admins||[]).map(String)); ids.forEach(i=>set.add(i)); o.admins=[...set]; _write(o); }
  function listAdmins(){ return (_read().admins||[]).map(String); }
  function isAdmin(id){ return listAdmins().includes(String(id)); }
  function addAdmin(id){ const sid=String(Number(id)); if(!sid||sid==='NaN') throw new Error('ID tidak valid'); const o=_read(); const set=new Set((o.admins||[]).map(String)); set.add(sid); o.admins=[...set]; _write(o); return o.admins; }
  function removeAdmin(id){ const sid=String(Number(id)); const o=_read(); o.admins=(o.admins||[]).map(String).filter(x=>x!==sid); _write(o); return o.admins; }
  adminStore = { seedFromEnv, listAdmins, isAdmin, addAdmin, removeAdmin };
  adminStore.seedFromEnv();
}

/* ================== Telegram Init ================== */
const token = process.env.TELEGRAM_BOT_TOKEN || '';
if (!token) { console.error('ERROR: TELEGRAM_BOT_TOKEN kosong di .env'); process.exit(1); }
const bot = new TelegramBot(token, { polling: { interval: 800, autoStart: true } });

/* ================== Utils ================== */
async function runWithTimeout(promise, ms) {
  const t = new Promise((_, rej)=> setTimeout(()=>rej(new Error('Timeout')), ms));
  return Promise.race([promise, t]);
}

async function sendLong(chatId, text, extra = {}) {
  const MAX = 3900; // jaga jarak dari limit 4096
  const t = String(text ?? '');
  if (t.length <= MAX) return bot.sendMessage(chatId, t, extra);

  const lines = t.split('\n');
  let buf = '';
  let firstMsg;
  for (const line of lines) {
    const would = buf ? (buf + '\n' + line) : line;
    if (would.length > MAX) {
      const m = await bot.sendMessage(chatId, buf, extra);
      if (!firstMsg) firstMsg = m;
      buf = line;
    } else {
      buf = would;
    }
  }
  if (buf) {
    const m = await bot.sendMessage(chatId, buf, extra);
    if (!firstMsg) firstMsg = m;
  }
  return firstMsg;
}

/* ================== History Store ================== */
const HISTORY_FILE = path.join(__dirname, 'history.json');
let history = [];
function loadHistory(){
  try{ if(fs.existsSync(HISTORY_FILE)) history = JSON.parse(fs.readFileSync(HISTORY_FILE,'utf8')||'[]'); }catch{ history = []; }
}
function saveHistory(){
  try{ fs.writeFileSync(HISTORY_FILE, JSON.stringify(history, null, 2)); }catch{}
}
function addHistory(ne1, ne2, resultText, keyText, startedAt, endedAt) {
  history.push({
    ne1, ne2,
    key: keyText,
    at: endedAt || Date.now(),
    startedAt, endedAt,
    // Simpan hasil terakhir untuk “cek ulang cepat”
    lastResult: resultText
  });
  if (history.length > 50) history.shift(); // jaga ukuran
  saveHistory();
}
function createHistoryButtons(){
  const rows = [];
  for (let i = history.length-1; i>=0; i--){
    const e = history[i];
    const label = `${e.ne1}${e.ne2 ? ` ↔ ${e.ne2}` : ''}`;
    rows.push([
      { text:`↻ ${label}`, callback_data:`retry_${i}` },
      { text:'🗑 Hapus', callback_data:`delete_${i}` }
    ]);
  }
  return rows.length ? rows : [[{ text: '— Kosong —', callback_data:'noop' }]];
}
loadHistory();

/* ================== Help Text ================== */
const HELP_TEXT =
`📋 *Perintah Utama*
/help — daftar perintah
/cek <NE1> [NE2] — cek RX (1 atau 2 sisi) dalam *satu pesan*
/history — tombol riwayat (hapus/cek ulang _inline_)

📋 *Admin*
/add_admin <id>
/remove_admin <id>
/admins — list admin

📲 *WhatsApp* (opsional)
/wa_status
/wa_enable
/wa_disable
/wa_pair — (jika WA diaktifkan)
`.trim();

/* ================== Admin helpers ================== */
function ensureAdmin(id){
  try {
    if (!adminStore?.isAdmin) return false;
    return adminStore.isAdmin(String(id));
  } catch { return false; }
}

/* ================== Command Handling ================== */
let lastChatId = null;

bot.getMe()
  .then(me=>console.log(`Telegram bot: @${me.username} (id:${me.id})`))
  .catch(e=>console.error('getMe error:', e?.message));
bot.on('polling_error', (err)=> console.error('polling_error:', err?.response?.body || err?.message || err));

bot.on('message', async (msg) => {
  const chatId = msg.chat.id;
  lastChatId = chatId;
  const text = msg.text || '';
  const low = text.toLowerCase().trim();

  // ===== /help =====
  if (low === '/help') {
    return bot.sendMessage(chatId, HELP_TEXT, { parse_mode: 'Markdown' });
  }

  // ===== Admin commands =====
  if (low.startsWith('/add_admin')) {
    if (!ensureAdmin(chatId)) return bot.sendMessage(chatId, '❌ Hanya admin yang boleh menambah admin.');
    const id = String(text.split(/\s+/)[1]||'').trim();
    try { adminStore.addAdmin(id); return bot.sendMessage(chatId, `✅ Admin ditambah: ${id}`); }
    catch(e){ return bot.sendMessage(chatId, '❌ Gagal tambah admin: '+(e?.message||e)); }
  }
  if (low.startsWith('/remove_admin')) {
    if (!ensureAdmin(chatId)) return bot.sendMessage(chatId, '❌ Hanya admin yang boleh menghapus admin.');
    const id = String(text.split(/\s+/)[1]||'').trim();
    try { adminStore.removeAdmin(id); return bot.sendMessage(chatId, `✅ Admin dihapus: ${id}`); }
    catch(e){ return bot.sendMessage(chatId, '❌ Gagal hapus admin: '+(e?.message||e)); }
  }
  if (low === '/admins') {
    try {
      const list = adminStore.listAdmins();
      return bot.sendMessage(chatId, `👑 Admins: ${list.length?list.join(', '):'(kosong)'}`);
    } catch(e){ return bot.sendMessage(chatId, '❌ Gagal baca admin: '+(e?.message||e)); }
  }

  // ===== /history =====
  if (low === '/history') {
    if (!history.length) return bot.sendMessage(chatId, '❌ Belum ada riwayat pengecekan.');
    return bot.sendMessage(chatId, '👉 Klik di bawah untuk cek ulang atau hapus riwayat:', {
      reply_markup: { inline_keyboard: createHistoryButtons() }
    });
  }

  // ===== /cek =====
  if (low.startsWith('/cek')) {
    const parts = text.split(/\s+/).slice(1).filter(Boolean);

    // Kirim PESAN AWAL lalu EDIT PESAN yg sama saat hasil sudah siap
    const checkingText = parts.length >= 2
      ? `🔄 Checking: ${parts[0]} ↔ ${parts[1]}...`
      : `🔄 Checking: ${parts[0]||'(NE)'}...`;

    const msgPending = await bot.sendMessage(chatId, checkingText);

    // 1 NE
    if (parts.length === 1) {
      const ne = parts[0];
      try {
        const start = Date.now();
        const result = await runWithTimeout(checkMetroStatus.checkSingleNE(ne), Number(process.env.CEK_TIMEOUT_MS || 120000));
        const end = Date.now();
        const finalText = `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${result}`;
        addHistory(ne, null, finalText, ne, start, end);

        return bot.editMessageText(finalText, {
          chat_id: chatId,
          message_id: msgPending.message_id,
          reply_markup: { inline_keyboard: [[{ text: '🔁 CEK ULANG', callback_data: `retry_last_${history.length-1}` }]] }
        });
      } catch(e){
        return bot.editMessageText('❌ Gagal cek 1 NE: '+(e?.message||e), {
          chat_id: chatId, message_id: msgPending.message_id
        });
      }
    }

    // 2 NE
    if (parts.length >= 2) {
      const ne1 = parts[0], ne2 = parts[1];
      try {
        const start = Date.now();
        const r1 = await runWithTimeout(checkMetroStatus(ne1, ne2, { mode: 'normal' }), Number(process.env.CEK_TIMEOUT_MS || 180000));
        const r2 = await runWithTimeout(checkMetroStatus(ne2, ne1, { mode: 'normal' }), Number(process.env.CEK_TIMEOUT_MS || 180000));
        const end = Date.now();
        const combined = `${r1}\n────────────\n${r2}`;
        const finalText = `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${combined}`;

        addHistory(ne1, ne2, finalText, `${ne1} ${ne2}`, start, end);

        return bot.editMessageText(finalText, {
          chat_id: chatId,
          message_id: msgPending.message_id,
          reply_markup: { inline_keyboard: [[{ text: '🔁 CEK ULANG', callback_data: `retry_last_${history.length-1}` }]] }
        });
      } catch(e){
        return bot.editMessageText('❌ Gagal cek 2 sisi: '+(e?.message||e), {
          chat_id: chatId, message_id: msgPending.message_id
        });
      }
    }

    // salah format
    return bot.editMessageText('❗ Format: /cek <NE1> [NE2]', {
      chat_id: chatId, message_id: msgPending.message_id
    });
  }

  // ===== Teks bebas -> parsing NE =====
  if (text) {
    const { list } = buildCekCommandFromText(text);
    if (list && list.length === 1) {
      const ne = list[0];
      return bot.sendMessage(chatId, `ℹ️ Hanya menemukan 1 NE dari teks.\nNE terdeteksi: ${ne}\n\nGunakan perintah ini:\n/cek ${ne}`, {
        reply_markup: { inline_keyboard: [[{ text: '▶️ Jalankan sekarang', callback_data: `runcek1_${ne}` }]] }
      });
    }
    if (list && list.length >= 2) {
      const a = list[0], b = list.find(x=>x!==a) || list[1];
      return bot.sendMessage(chatId, `NE terdeteksi: ${list.join(', ')}\n\nGunakan perintah ini:\n/cek ${a} ${b}`, {
        reply_markup: { inline_keyboard: [[{ text: '▶️ Jalankan sekarang', callback_data: `runcek_${a}_${b}` }]] }
      });
    }
  }
});

/* ================== Callback Query ================== */
bot.on('callback_query', async (q)=>{
  const { data, message } = q;
  const chatId = message?.chat?.id;
  try {
    await bot.answerCallbackQuery(q.id);
    if (!chatId || !message) return;

    // Jalankan sekarang (2 NE)
    if (data.startsWith('runcek_')) {
      const [, ne1, ne2] = data.split('_');
      // edit pesan saat ini -> Checking...
      await bot.editMessageText(`🔄 Checking: ${ne1} ↔ ${ne2}...`, { chat_id: chatId, message_id: message.message_id });
      const r1 = await runWithTimeout(checkMetroStatus(ne1, ne2, { mode: 'normal' }), Number(process.env.CEK_TIMEOUT_MS || 180000));
      const r2 = await runWithTimeout(checkMetroStatus(ne2, ne1, { mode: 'normal' }), Number(process.env.CEK_TIMEOUT_MS || 180000));
      const end = Date.now();
      const finalText = `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${r1}\n────────────\n${r2}`;
      addHistory(ne1, ne2, finalText, `${ne1} ${ne2}`, end, end);
      return bot.editMessageText(finalText, {
        chat_id: chatId, message_id: message.message_id,
        reply_markup: { inline_keyboard: [[{ text: '🔁 Cek ulang', callback_data: `runcek_${ne1}_${ne2}` }]] }
      });
    }

    // Jalankan sekarang (1 NE)
    if (data.startsWith('runcek1_')) {
      const ne = data.substring('runcek1_'.length);
      await bot.editMessageText(`🔄 Checking: ${ne}...`, { chat_id: chatId, message_id: message.message_id });
      const result = await runWithTimeout(checkMetroStatus.checkSingleNE(ne), Number(process.env.CEK_TIMEOUT_MS || 120000));
      const end = Date.now();
      const finalText = `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${result}`;
      addHistory(ne, null, finalText, ne, end, end);
      return bot.editMessageText(finalText, {
        chat_id: chatId, message_id: message.message_id,
        reply_markup: { inline_keyboard: [[{ text: '🔁 Cek ulang', callback_data: `runcek1_${ne}` }]] }
      });
    }

    // Cek ulang dari history
    if (data.startsWith('retry_')) {
      let index = null;
      if (data.startsWith('retry_last_')) index = parseInt(data.split('_').pop(), 10);
      else index = parseInt(data.split('_')[1], 10);
      const e = history[index];
      if (e) {
        if (!e.ne2) {
          await bot.editMessageText(`🔄 Checking: ${e.ne1}...`, { chat_id: chatId, message_id: message.message_id });
          const result = await runWithTimeout(checkMetroStatus.checkSingleNE(e.ne1), Number(process.env.CEK_TIMEOUT_MS || 120000));
          const end = Date.now();
          const finalText = `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${result}`;
          addHistory(e.ne1, null, finalText, e.ne1, end, end);
          return bot.editMessageText(finalText, {
            chat_id: chatId, message_id: message.message_id,
            reply_markup: { inline_keyboard: [[{ text: '🔁 Cek ulang', callback_data: `runcek1_${e.ne1}` }]] }
          });
        } else {
          await bot.editMessageText(`🔄 Checking: ${e.ne1} ↔ ${e.ne2}...`, { chat_id: chatId, message_id: message.message_id });
          const r1 = await runWithTimeout(checkMetroStatus(e.ne1, e.ne2, { mode: 'normal' }), Number(process.env.CEK_TIMEOUT_MS || 180000));
          const r2 = await runWithTimeout(checkMetroStatus(e.ne2, e.ne1, { mode: 'normal' }), Number(process.env.CEK_TIMEOUT_MS || 180000));
          const end = Date.now();
          const finalText = `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${r1}\n────────────\n${r2}`;
          addHistory(e.ne1, e.ne2, finalText, `${e.ne1} ${e.ne2}`, end, end);
          return bot.editMessageText(finalText, {
            chat_id: chatId, message_id: message.message_id,
            reply_markup: { inline_keyboard: [[{ text: '🔁 Cek ulang', callback_data: `runcek_${e.ne1}_${e.ne2}` }]] }
          });
        }
      }
    }

    // Hapus history (dan REFRESH daftar pada pesan yang sama)
    if (data.startsWith('delete_')) {
      const index = parseInt(data.split('_')[1], 10);
      const e = history[index];
      if (e) {
        history.splice(index,1); saveHistory();
        const textHead = history.length
          ? '👉 Klik di bawah untuk cek ulang atau hapus riwayat:'
          : '✅ Riwayat dihapus. (Tidak ada entri tersisa)';
        return bot.editMessageText(textHead, {
          chat_id: chatId,
          message_id: message.message_id,
          reply_markup: { inline_keyboard: createHistoryButtons() }
        });
      } else {
        return bot.answerCallbackQuery(q.id, { text: 'Entri tidak ditemukan', show_alert:false });
      }
    }

    if (data === 'noop') {
      return bot.answerCallbackQuery(q.id, { text: 'Tidak ada aksi', show_alert:false });
    }

  } catch(err){
    console.error('callback error:', err);
    bot.answerCallbackQuery(q.id, { text: '❌ Terjadi kesalahan. Coba lagi!', show_alert: true }).catch(()=>{});
  }
});

/* ================== WhatsApp (opsional & aman) ================== */
// Hanya placeholder status agar tidak error bila modul tidak ada
let WA_ENABLED = (String(process.env.WA_ENABLED||'false').toLowerCase()==='true');
bot.onText(/^\/wa_status$/, (msg)=>{
  return bot.sendMessage(msg.chat.id, `WA status: ${WA_ENABLED ? 'ENABLED' : 'DISABLED'}`);
});
bot.onText(/^\/wa_enable$/, (msg)=>{
  if (!ensureAdmin(msg.chat.id)) return bot.sendMessage(msg.chat.id, '❌ Khusus admin.');
  WA_ENABLED = true;
  return bot.sendMessage(msg.chat.id, '✅ WA diaktifkan (butuh implementasi jalankan konektor Baileys).');
});
bot.onText(/^\/wa_disable$/, (msg)=>{
  if (!ensureAdmin(msg.chat.id)) return bot.sendMessage(msg.chat.id, '❌ Khusus admin.');
  WA_ENABLED = false;
  return bot.sendMessage(msg.chat.id, '✅ WA dimatikan.');
});
bot.onText(/^\/wa_pair$/, (msg)=>{
  if (!WA_ENABLED) return bot.sendMessage(msg.chat.id, 'ℹ️ WA tidak aktif.');
  return bot.sendMessage(msg.chat.id, 'ℹ️ Pair WA belum diinisialisasi di build ini.');
});

/* ================== Error Notifier ================== */
async function sendToAdmins(text, opts = {}) {
  try {
    let ids = [];
    try { if (adminStore?.listAdmins) ids = adminStore.listAdmins().map(String); } catch {}
    if (!ids.length) {
      ids = String(process.env.ADMIN_IDS || '').split(',').map(v=>v.trim()).filter(Boolean);
    }
    if (!ids.length && typeof lastChatId !== 'undefined' && lastChatId) ids = [String(lastChatId)];
    for (const id of ids) { try { await bot.sendMessage(id, text, opts); } catch {} }
  } catch {}
}

function notifyAdmins(text){
  try {
    const admins = adminStore.listAdmins();
    const target = admins[0];
    if (target) bot.sendMessage(Number(target), text).catch(()=>{});
  } catch {}
}

process.on('unhandledRejection', async (err) => {
  try { await sendToAdmins('❗ *UnhandledRejection*\n' + (err?.stack || err)); } catch {}
});
process.on('uncaughtException', async (err) => {
  try { await sendToAdmins('❗ *UncaughtException*\n' + (err?.stack || err)); } catch {}
  setTimeout(() => process.exit(1), 500);
});
