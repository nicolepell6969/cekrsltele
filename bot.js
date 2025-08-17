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

// === Modules we use ===
const QR = require('qrcode');

let checkMetroStatus = null;
try { checkMetroStatus = require('./checkMetroStatus'); }
catch { console.error('WARN: checkMetroStatus.js tidak ditemukan'); }

let { buildCekCommandFromText } = (() => {
  try { return require('./textToCommand'); }
  catch { return { buildCekCommandFromText: (t)=>({cmd:null,list:[],note:'modul textToCommand.js tidak ada'}) }; }
})();

// === Admin store (persisten) ===
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

// === Telegram init ===
const token = process.env.TELEGRAM_BOT_TOKEN || '';
if (!token) { console.error('ERROR: TELEGRAM_BOT_TOKEN kosong di .env'); process.exit(1); }
const bot = new TelegramBot(token, { polling: { interval: 800, autoStart: true } });

// === Safe long message sender (single, clean implementation) ===
function splitSmart(text, max=3900){
  const t = String(text ?? '');
  if (t.length <= max) return [t];
  const chunks = [];
  let rest = t;
  while (rest.length){
    if (rest.length <= max) { chunks.push(rest); break; }
    // prefer cut at newline/space
    let cut = rest.lastIndexOf('\n', max);
    if (cut < 0) cut = rest.lastIndexOf(' ', max);
    if (cut < 0 || cut < max*0.6) cut = max; // hard cut if no good boundary
    chunks.push(rest.slice(0, cut));
    rest = rest.slice(cut);
  }
  return chunks;
}

const origSend = bot.sendMessage.bind(bot);
bot.sendMessage = async (chatId, text, extra={}) => {
  if (typeof text !== 'string') return origSend(chatId, text, extra);
  const parts = splitSmart(text, 3900);
  let last;
  for (const p of parts){
    const safeExtra = { ...extra };
    // never set parse_mode automatically; we keep plain text to avoid mangling
    if (safeExtra.parse_mode) delete safeExtra.parse_mode;
    last = await origSend(chatId, p, safeExtra);
  }
  return last;
};
bot.sendLong = async (chatId, text, extra={}) => bot.sendMessage(chatId, text, extra);

// === Small utils ===
async function runWithTimeout(promise, ms){
  let to;
  const timeout = new Promise((_, rej)=> to = setTimeout(()=>rej(new Error('Timeout')), ms));
  try { return await Promise.race([promise, timeout]); }
  finally { clearTimeout(to); }
}

// === History (persisten) ===
const HIST_FILE = path.join(__dirname, 'history.json');
let history = [];
function loadHistory(){
  try { if (fs.existsSync(HIST_FILE)) history = JSON.parse(fs.readFileSync(HIST_FILE,'utf8')||'[]'); }
  catch { history = []; }
}
function saveHistory(){
  try { fs.writeFileSync(HIST_FILE, JSON.stringify(history,null,2)); } catch {}
}
function addHistory(ne1, ne2, combinedText, label, start, end){
  history.push({ ne1, ne2, text: combinedText, label, tsStart: start, tsEnd: end });
  if (history.length > 30) history = history.slice(-30);
  saveHistory();
}
function createHistoryButtons(){
  // latest first
  const rows = history.map((h,i)=>({h, i}))
    .slice().reverse()
    .map(({h,i})=>{
      const idx = history.length - 1 - i;
      const title = h.ne2 ? `${h.ne1} ↔ ${h.ne2}` : h.ne1;
      return [
        { text: `▶️ ${title}`, callback_data: `retry_${idx}` },
        { text: '🗑 Hapus', callback_data: `delete_${idx}` }
      ];
    });
  return rows.length ? rows : [[{ text:'(kosong)', callback_data:'noop' }]];
}
loadHistory();

// === WhatsApp (opsional, aman bila tidak dipakai) ===
let WA_ENABLED = (String(process.env.WA_ENABLED||'false').toLowerCase()==='true');
let waClient=null;
try {
  const { default: makeWASocket, useMultiFileAuthState, fetchLatestBaileysVersion } = require('@whiskeysockets/baileys');
  async function waStart(notifyChatId){
    if (!WA_ENABLED) return;
    if (waClient) return;
    const { state, saveCreds } = await useMultiFileAuthState(path.join(__dirname,'wa_auth'));
    let version = [2,3000,0]; try { ({ version } = await fetchLatestBaileysVersion()); } catch {}
    const sock = makeWASocket({ version, auth: state, printQRInTerminal:false, syncFullHistory:false, browser:['cekrsltele','Chrome','1.0'] });
    sock.ev.on('connection.update', async ({ qr, connection, lastDisconnect })=>{
      if (qr && notifyChatId){
        try {
          const buf = await QR.toBuffer(qr, { type: 'png', scale: 8, margin: 1 });
          await bot.sendPhoto(notifyChatId, buf, { caption: '📲 Scan QR WhatsApp berikut (±60 detik). Jika kadaluarsa, kirim /wa_pair lagi.' });
        } catch (e) {
          // ignore
        }
      }
      if (connection === 'open') { if (notifyChatId) bot.sendMessage(notifyChatId, '✅ WhatsApp tersambung.'); }
      else if (connection === 'close') { if (notifyChatId) bot.sendMessage(notifyChatId, '⚠️ WhatsApp terputus.'); waClient = null; }
    });
    sock.ev.on('creds.update', saveCreds);
    waClient = sock;
  }
  globalThis.waStart = waStart;
} catch { /* Baileys not installed — ignore */ }

// === Bot info / errors ===
bot.getMe().then(me=>console.log(`Telegram bot: @${me.username} (id:${me.id})`)).catch(e=>console.error('getMe error:', e?.message));
bot.on('polling_error', (err)=> console.error('polling_error:', err?.response?.body || err?.message || err));

// ========================= COMMAND HANDLERS =========================
let lastChatId = null;

bot.on('message', async (msg)=>{
  const chatId = msg.chat.id;
  lastChatId = chatId;
  const text = (msg.text || '').trim();
  const low = text.toLowerCase();

  // ===== /help (plain text, stabil) =====
  if (low === '/help') {
    const help = [
      'Perintah Utama:',
      '• /cek <NE1> [NE2] — cek Metro-e (RX Level only)',
      '• /history — riwayat cek (bisa cek ulang / hapus)',
      '• /admin — lihat admin terdaftar',
      '',
      'Admin:',
      '• /add_admin <id>',
      '• /remove_admin <id>',
      '• /admins — list admin',
      '',
      'WhatsApp (opsional):',
      '• /wa_status',
      '• /wa_enable',
      '• /wa_disable',
      '• /wa_pair — kirim QR ke sini'
    ].join('\n');
    return bot.sendMessage(chatId, help);
  }

  // ===== /admin (lihat admin) =====
  if (low === '/admin' || low === '/admins') {
    const ids = adminStore.listAdmins();
    return bot.sendMessage(chatId, 'Admin IDs: ' + (ids.join(', ') || '(kosong)'));
  }

  // ===== /add_admin /remove_admin =====
  if (low.startsWith('/add_admin')) {
    const id = text.split(/\s+/)[1];
    try { adminStore.addAdmin(id); return bot.sendMessage(chatId, '✅ Admin ditambah: '+id); }
    catch(e){ return bot.sendMessage(chatId, '❌ Gagal: '+(e?.message||e)); }
  }
  if (low.startsWith('/remove_admin')) {
    const id = text.split(/\s+/)[1];
    try { adminStore.removeAdmin(id); return bot.sendMessage(chatId, '✅ Admin dihapus: '+id); }
    catch(e){ return bot.sendMessage(chatId, '❌ Gagal: '+(e?.message||e)); }
  }

  // ===== /cek =====
  if (low.startsWith('/cek')) {
    const parts = text.split(/\s+/).slice(1).filter(Boolean);
    if (!parts.length) return bot.sendMessage(chatId, '❗ Format: /cek <NE1> [NE2]');
    // 1 NE
    if (parts.length === 1) {
      const ne = parts[0];
      await bot.sendMessage(chatId, `🔄 Checking: ${ne}...`);
      try {
        const start = Date.now();
        const result = await runWithTimeout(checkMetroStatus.checkSingleNE(ne), Number(process.env.CEK_TIMEOUT_MS || 120000));
        const end = Date.now();
        addHistory(ne, null, result, ne, start, end);
        return bot.sendMessage(chatId, `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${result}`);
      } catch(e){
        return bot.sendMessage(chatId, '❌ Gagal cek 1 NE: '+(e?.message||e));
      }
    }
    // 2 NE (HANYA SEKALI panggil untuk hindari dobel)
    if (parts.length >= 2) {
      const ne1 = parts[0], ne2 = parts[1];
      await bot.sendMessage(chatId, `🔄 Checking: ${ne1} ↔ ${ne2}...`);
      try {
        const start = Date.now();
        const combined = await runWithTimeout(checkMetroStatus(ne1, ne2, { mode: 'normal' }), Number(process.env.CEK_TIMEOUT_MS || 180000));
        const end = Date.now();
        addHistory(ne1, ne2, combined, `${ne1} ${ne2}`, start, end);
        return bot.sendMessage(chatId, `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${combined}`, {
          reply_markup: { inline_keyboard: [[{ text: '🔁 CEK ULANG', callback_data: `retry_last_${history.length-1}` }]] }
        });
      } catch(e){
        return bot.sendMessage(chatId, '❌ Gagal cek 2 sisi: '+(e?.message||e));
      }
    }
  }

  // ===== /history =====
  if (low === '/history') {
    if (!history.length) return bot.sendMessage(chatId, '❌ Belum ada riwayat pengecekan.');
    return bot.sendMessage(chatId, '👉 Klik di bawah untuk cek ulang atau hapus riwayat:', {
      reply_markup: { inline_keyboard: createHistoryButtons() }
    });
  }

  // ===== Teks bebas -> parsing NE =====
  if (text && !text.startsWith('/')) {
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

// ===== Callback (cek ulang, run now, hapus) =====
bot.on('callback_query', async (q)=>{
  const { data, message } = q;
  const chatId = message.chat.id;
  try {
    await bot.answerCallbackQuery(q.id);

    if (data.startsWith('runcek_')) {
      const [, ne1, ne2] = data.split('_');
      await bot.sendMessage(chatId, `🔄 Checking: ${ne1} ↔ ${ne2}...`);
      const combined = await runWithTimeout(checkMetroStatus(ne1, ne2, { mode: 'normal' }), Number(process.env.CEK_TIMEOUT_MS || 180000));
      const end = Date.now();
      return bot.sendMessage(chatId, `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${combined}`, {
        reply_markup: { inline_keyboard: [[{ text: '🔁 Cek ulang', callback_data: `runcek_${ne1}_${ne2}` }]] }
      });
    }

    if (data.startsWith('runcek1_')) {
      const ne = data.substring('runcek1_'.length);
      await bot.sendMessage(chatId, `🔄 Checking: ${ne}...`);
      const result = await runWithTimeout(checkMetroStatus.checkSingleNE(ne), Number(process.env.CEK_TIMEOUT_MS || 120000));
      const end = Date.now();
      return bot.sendMessage(chatId, `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${result}`, {
        reply_markup: { inline_keyboard: [[{ text: '🔁 Cek ulang', callback_data: `runcek1_${ne}` }]] }
      });
    }

    if (data.startsWith('retry_')) {
      let index = null;
      if (data.startsWith('retry_last_')) index = parseInt(data.split('_').pop(), 10);
      else index = parseInt(data.split('_')[1], 10);
      const e = history[index];
      if (e) {
        if (!e.ne2) {
          await bot.sendMessage(chatId, `🔄 Checking: ${e.ne1}...`);
          const result = await runWithTimeout(checkMetroStatus.checkSingleNE(e.ne1), Number(process.env.CEK_TIMEOUT_MS || 120000));
          const end = Date.now();
          return bot.sendMessage(chatId, `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${result}`, {
            reply_markup: { inline_keyboard: [[{ text: '🔁 Cek ulang', callback_data: `runcek1_${e.ne1}` }]] }
          });
        } else {
          await bot.sendMessage(chatId, `🔄 Checking: ${e.ne1} ↔ ${e.ne2}...`);
          const combined = await runWithTimeout(checkMetroStatus(e.ne1, e.ne2, { mode: 'normal' }), Number(process.env.CEK_TIMEOUT_MS || 180000));
          const end = Date.now();
          return bot.sendMessage(chatId, `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${combined}`, {
            reply_markup: { inline_keyboard: [[{ text: '🔁 Cek ulang', callback_data: `runcek_${e.ne1}_${e.ne2}` }]] }
          });
        }
      }
    }

    if (data.startsWith('delete_')) {
      const index = parseInt(data.split('_')[1], 10);
      const e = history[index];
      if (!e) return;
      history.splice(index,1); saveHistory();

      // Auto-refresh the /history message that showed the buttons
      const newKeyboard = { inline_keyboard: createHistoryButtons() };
      try {
        await bot.editMessageReplyMarkup(newKeyboard, {
          chat_id: message.chat.id,
          message_id: message.message_id
        });
        await bot.editMessageText('👉 Klik di bawah untuk cek ulang atau hapus riwayat:', {
          chat_id: message.chat.id,
          message_id: message.message_id,
          reply_markup: newKeyboard
        });
      } catch(_) {}
      return bot.sendMessage(chatId, `✅ Riwayat ${e.ne1}${e.ne2?` ↔ ${e.ne2}`:''} dihapus.`);
    }
  } catch(err){
    console.error('callback error:', err);
    bot.answerCallbackQuery(q.id, { text: '❌ Terjadi kesalahan. Coba lagi!', show_alert: true }).catch(()=>{});
  }
});

// === OPTIONAL: kirim error penting ke admin pertama ===
function notifyAdmins(text){
  try {
    const admins = adminStore.listAdmins();
    const target = admins[0];
    if (target) bot.sendMessage(Number(target), text).catch(()=>{});
  } catch {}
}
process.on('unhandledRejection', err=> notifyAdmins('⚠️ unhandledRejection: '+(err?.message||err)));
process.on('uncaughtException', err=> { notifyAdmins('⚠️ uncaughtException: '+(err?.message||err)); setTimeout(()=>process.exit(1), 500); });

// === global error handlers (non-fatal for unhandledRejection) ===
process.on('unhandledRejection', async (err) => {
  try { /* no-op */ } catch {}
});
process.on('uncaughtException', async (err) => {
  try { /* already handled above */ } catch {}
  setTimeout(() => process.exit(1), 500);
});
