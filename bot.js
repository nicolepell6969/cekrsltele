// bot.js — Telegram + WhatsApp (Baileys) in one, managed via Telegram
// Rules:
// - /cek => langsung eksekusi (tanpa tombol)
// - Parsing teks bebas => tampilkan tombol "▶️ Jalankan sekarang"
// - Admin-only WA controls: /wa_status, /wa_enable, /wa_disable, /wa_pair, /wa_logout
// - QR WA dikirim ke chat Telegram admin
// - State on/off WA disimpan ke app.config.json (persist restart)

const fs = require('fs');
require('dotenv').config();

const TelegramBot = require('node-telegram-bot-api');
const checkMetroStatus = require('./checkMetroStatus');
const { buildCekCommandFromText } = require('./textToCommand');

// WhatsApp (Baileys)
const makeWASocket = require("@adiwajshing/baileys").default;
const { useMultiFileAuthState, DisconnectReason, fetchLatestBaileysVersion } = require("@adiwajshing/baileys");
const pino = require("pino");
const QR = require('qrcode');

// ====== ENV ======
const token = process.env.TELEGRAM_BOT_TOKEN || '';
if (!token) { console.error('Missing TELEGRAM_BOT_TOKEN in .env'); process.exit(1); }
const ADMIN_IDS = String(process.env.ADMIN_IDS || '').split(',').map(s=>s.trim()).filter(Boolean);
const DEFAULT_WA_ENABLED = (process.env.WHATSAPP_ENABLED || 'false').toLowerCase() === 'true';

// ====== Files & persistence ======
const historyFilePath = './history.json';
const appStatePath = './app.config.json';
const waAuthDir = './wa_auth';

function loadAppState() {
  try {
    if (fs.existsSync(appStatePath)) {
      const j = JSON.parse(fs.readFileSync(appStatePath, 'utf8'));
      return { whatsappEnabled: !!j.whatsappEnabled };
    }
  } catch {}
  return { whatsappEnabled: DEFAULT_WA_ENABLED };
}
function saveAppState(st) {
  try { fs.writeFileSync(appStatePath, JSON.stringify({ whatsappEnabled: !!st.whatsappEnabled }, null, 2)); } catch {}
}
let APP = loadAppState();

let history = [];
try {
  if (fs.existsSync(historyFilePath)) {
    const raw = fs.readFileSync(historyFilePath);
    if (raw) history = JSON.parse(raw);
  }
} catch (e) { history = []; }
function saveHistory(){ try{ fs.writeFileSync(historyFilePath, JSON.stringify(history,null,2)); } catch(e){} }
function isDuplicate(ne1, ne2){
  return history.some(h => (h.ne1===ne1 && h.ne2===ne2) || (h.ne1===ne2 && h.ne2===ne1));
}
function addHistory(ne1, ne2, result, name, startTime, endTime){
  if (ne2 && isDuplicate(ne1, ne2)) return;
  const timestamp = new Date(startTime).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' });
  const shortNe1 = (ne1.split('-')[1]||ne1).slice(0,4);
  const shortNe2 = ne2 ? (ne2.split('-')[1]||ne2).slice(0,4) : '';
  const duration = (endTime - startTime) / 1000;
  history.push({ name, ne1, ne2: ne2||'', shortNe1, shortNe2, result, timestamp, duration });
  saveHistory();
}
function createHistoryButtons(){
  return history.map((entry, idx) => ([
    { text: `Ulangi ${entry.shortNe1}${entry.shortNe2?` ↔ ${entry.shortNe2}`:''}`, callback_data: `retry_${idx}` },
    { text: `Hapus ${entry.shortNe1}${entry.shortNe2?` ↔ ${entry.shortNe2}`:''}`, callback_data: `delete_${idx}` },
  ]));
}
function isAdmin(telegramUserId) {
  if (!ADMIN_IDS.length) return true; // kalau kosong, semua dianggap admin (opsional: ubah ke false)
  return ADMIN_IDS.includes(String(telegramUserId));
}

// ====== Telegram Boot ======
const bot = new TelegramBot(token, { polling: true });

// track admin chats (untuk kirim QR WA)
const adminChats = new Set();

// ====== WhatsApp Manager (in-process) ======
let waSock = null;
let waStarting = false;
let waConnected = false;
let waAuthLoaded = false;

async function startWhatsApp(notify=true) {
  if (!APP.whatsappEnabled) {
    if (notify) notifyAdmins('ℹ️ WhatsApp disabled. Gunakan /wa_enable untuk mengaktifkan.');
    return;
  }
  if (waStarting || waSock) {
    if (notify) notifyAdmins('ℹ️ WhatsApp sudah berjalan / starting.');
    return;
  }
  waStarting = true;
  try {
    if (!fs.existsSync(waAuthDir)) fs.mkdirSync(waAuthDir, { recursive: true });
    const { state, saveCreds } = await useMultiFileAuthState(waAuthDir);
    waAuthLoaded = true;
    const { version } = await fetchLatestBaileysVersion();

    waSock = makeWASocket({
      version,
      printQRInTerminal: false,
      auth: state,
      logger: pino({ level: "silent" }),
      browser: ["cekrsltele","Chrome","1.0"]
    });

    waSock.ev.on('creds.update', saveCreds);

    waSock.ev.on('connection.update', async ({ connection, lastDisconnect, qr }) => {
      if (qr) {
        try {
          const png = await QR.toBuffer(qr, { width: 320, errorCorrectionLevel: 'M' });
          await notifyAdminsPhoto(png, { caption: '🔐 Scan QR ini di WhatsApp untuk pairing.' });
        } catch (e) {
          await notifyAdmins('❌ Gagal membuat QR image: ' + e.message);
        }
      }
      if (connection === 'open') {
        waConnected = true;
        await notifyAdmins('✅ WhatsApp connected.');
      } else if (connection === 'close') {
        waConnected = false;
        const status = lastDisconnect?.error?.output?.statusCode;
        if (status !== DisconnectReason.loggedOut && APP.whatsappEnabled) {
          await notifyAdmins('⚠️ WhatsApp terputus, mencoba reconnect…');
          stopWhatsApp(false);
          setTimeout(()=>startWhatsApp(false), 2000);
        } else if (status === DisconnectReason.loggedOut) {
          await notifyAdmins('ℹ️ WhatsApp logged out. Jalankan /wa_pair untuk pairing ulang.');
          stopWhatsApp(false);
        }
      }
    });

    waSock.ev.on("messages.upsert", async () => { /* no-op for control */ });

  } catch (e) {
    await notifyAdmins('❌ Gagal start WhatsApp: ' + e.message);
    stopWhatsApp(false);
  } finally {
    waStarting = false;
  }
}

function stopWhatsApp(notify=true) {
  try { if (waSock) waSock.end?.(); } catch {}
  waSock = null;
  waConnected = false;
  if (notify) notifyAdmins('🛑 WhatsApp stopped.');
}

async function logoutWhatsApp() {
  try { if (waSock) { await waSock.logout(); stopWhatsApp(false); } } catch {}
  try { fs.rmSync(waAuthDir, { recursive: true, force: true }); } catch {}
  waAuthLoaded = false;
}

async function notifyAdmins(text) {
  for (const chatId of adminChats) { try{ await bot.sendMessage(chatId, text); }catch{} }
}
async function notifyAdminsPhoto(buffer, opts={}) {
  for (const chatId of adminChats) { try{ await bot.sendPhoto(chatId, buffer, opts); }catch{} }
}

// ====== Telegram Handlers ======
bot.on('message', async (msg) => {
  const chatId = msg.chat.id;
  const fromId = msg.from?.id;
  const text = (msg.text || '').trim();
  const low = text.toLowerCase();

  // catat chat admin untuk notifikasi
  if (isAdmin(fromId)) adminChats.add(chatId);

  // ---- Admin WA controls ----
  if (low === '/wa_status') {
    if (!isAdmin(fromId)) return bot.sendMessage(chatId, '🚫 🚫 Perintah ini khusus admin. Minta admin menambahkan ID kamu via /add_admin <telegram_id>.');
    const enabled = APP.whatsappEnabled;
    const status = enabled ? (waConnected ? 'CONNECTED' : (waStarting ? 'STARTING' : 'DISCONNECTED')) : 'DISABLED';
    return bot.sendMessage(chatId, `📟 WA Status: ${status}\nEnabled: ${enabled}\nAuth Loaded: ${waAuthLoaded}`);
  }

  if (low === '/wa_enable') {
    if (!isAdmin(fromId)) return bot.sendMessage(chatId, '🚫 🚫 Perintah ini khusus admin. Minta admin menambahkan ID kamu via /add_admin <telegram_id>.');
    APP.whatsappEnabled = true; saveAppState(APP);
    bot.sendMessage(chatId, '✅ WhatsApp ENABLED. Starting…');
    return startWhatsApp(false);
  }

  if (low === '/wa_disable') {
    if (!isAdmin(fromId)) return bot.sendMessage(chatId, '🚫 🚫 Perintah ini khusus admin. Minta admin menambahkan ID kamu via /add_admin <telegram_id>.');
    APP.whatsappEnabled = false; saveAppState(APP);
    stopWhatsApp(false);
    return bot.sendMessage(chatId, '🛑 WhatsApp DISABLED.');
  }

  if (low === '/wa_pair') {
    if (!isAdmin(fromId)) return bot.sendMessage(chatId, '🚫 🚫 Perintah ini khusus admin. Minta admin menambahkan ID kamu via /add_admin <telegram_id>.');
    APP.whatsappEnabled = true; saveAppState(APP);
    await bot.sendMessage(chatId, '🔐 Pairing WA dimulai. QR akan dikirim di chat ini.');
    return startWhatsApp(false);
  }

  if (low === '/wa_logout') {
    if (!isAdmin(fromId)) return bot.sendMessage(chatId, '🚫 🚫 Perintah ini khusus admin. Minta admin menambahkan ID kamu via /add_admin <telegram_id>.');
    await bot.sendMessage(chatId, '🔓 Logout WA & hapus kredensial…');
    await logoutWhatsApp();
    return bot.sendMessage(chatId, '✅ WA sudah logout. Jalankan /wa_pair untuk pairing ulang.');
  }

  // ---- /cek command ----
  if (low.startsWith('/cek ')) {
    const parts = text.split(' ').slice(1).map(s => s.trim()).filter(Boolean);

    // 1 NE — langsung jalan, tanpa tombol
    if (parts.length === 1) {
      const ne = parts[0];
      bot.sendMessage(chatId, `🔄 Cek satu NE: ${ne}…`);
      const start = Date.now();
      const result = await checkMetroStatus.checkSingleNE(ne);
      const end = Date.now();
      addHistory(ne, null, result, ne, start, end);
      return bot.sendMessage(chatId, `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${result}`);
    }

    // 2 NE — langsung jalan, tanpa tombol
    if (parts.length === 2) {
      const [ne1, ne2] = parts;
      const name = text.split(' ').slice(1).join(' ');
      bot.sendMessage(chatId, `🔄 ONCEK, DITUNGGU`);
      const start = Date.now();
      const r1 = await checkMetroStatus(ne1, ne2, { mode: 'normal' });
      const r2 = await checkMetroStatus(ne2, ne1, { mode: 'normal' });
      const end = Date.now();
      const combined = `${r1}\n────────────\n${r2}`;
      addHistory(ne1, ne2, combined, name, start, end);
      return bot.sendMessage(chatId, `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${combined}`, {
        reply_markup: { inline_keyboard: [[{ text: '🔁 CEK ULANG', callback_data: `retry_last_${history.length-1}` }]] }
      });
    }

    return bot.sendMessage(chatId, '❗ Format: /cek <NE1> [NE2]');
  }

  // ---- /history ----
  if (low === '/history') {
    if (!history.length) return bot.sendMessage(chatId, '❌ Belum ada riwayat pengecekan.');
    return bot.sendMessage(chatId, '👉 Klik di bawah untuk cek ulang atau hapus riwayat:', {
      reply_markup: { inline_keyboard: createHistoryButtons() }
    });
  }

  // ---- Teks bebas => parse NE => tampil tombol (tanpa auto-run) ----
  if (text) {
    const { list } = buildCekCommandFromText(text);
    if (list && list.length === 1) {
      const ne = list[0];
      return bot.sendMessage(chatId, `ℹ️ Hanya menemukan 1 NE dari teks.\nNE terdeteksi: ${ne}\n\nGunakan perintah ini:\n/cek ${ne}`, {
        reply_markup: { inline_keyboard: [[{ text: '▶️ Jalankan sekarang', callback_data: `runcek1_${ne}` }]] }
      });
    }
    if (list && list.length >= 2) {
      const a = list[0], b = list.find(x => x !== a) || list[1];
      return bot.sendMessage(chatId, `NE terdeteksi: ${list.join(', ')}\n\nGunakan perintah ini:\n/cek ${a} ${b}`, {
        reply_markup: { inline_keyboard: [[{ text: '▶️ Jalankan sekarang', callback_data: `runcek_${a}_${b}` }]] }
      });
    }
  }

  return bot.sendMessage(chatId, 'ℹ️ Perintah tidak dikenali.\nKetik /help untuk daftar perintah.');
});

// ===== Callback tombol (run & riwayat) =====
bot.on('callback_query', async (query) => {
  const { data, message } = query;
  const chatId = message.chat.id;
  try {
    await bot.answerCallbackQuery(query.id);

    // run 2 sisi
    if (data.startsWith('runcek_')) {
      const [, ne1, ne2] = data.split('_');
      await bot.sendMessage(chatId, `🔄 Checking: ${ne1} ↔ ${ne2}...`);
      const r1 = await checkMetroStatus(ne1, ne2, { mode: 'normal' });
      const r2 = await checkMetroStatus(ne2, ne1, { mode: 'normal' });
      const end = Date.now();
      return bot.sendMessage(chatId, `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${r1}\n────────────\n${r2}`, {
        reply_markup: { inline_keyboard: [[{ text: '🔁 Cek ulang', callback_data: `runcek_${ne1}_${ne2}` }]] }
      });
    }

    // run 1 sisi
    if (data.startsWith('runcek1_')) {
      const ne = data.substring('runcek1_'.length);
      await bot.sendMessage(chatId, `🔄 Checking: ${ne}...`);
      const result = await checkMetroStatus.checkSingleNE(ne);
      const end = Date.now();
      return bot.sendMessage(chatId, `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${result}`, {
        reply_markup: { inline_keyboard: [[{ text: '🔁 Cek ulang', callback_data: `runcek1_${ne}` }]] }
      });
    }

    // retry/hapus
    if (data.startsWith('retry_')) {
      let index = null;
      if (data.startsWith('retry_last_')) index = parseInt(data.split('_').pop(), 10);
      else index = parseInt(data.split('_')[1], 10);
      const entry = history[index];
      if (entry) {
        if (!entry.ne2) {
          bot.sendMessage(chatId, `🔄 Checking: ${entry.ne1}...`);
          const result = await checkMetroStatus.checkSingleNE(entry.ne1);
          const end = Date.now();
          return bot.sendMessage(chatId, `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${result}`);
        } else {
          bot.sendMessage(chatId, `🔄 Checking: ${entry.ne1} ↔ ${entry.ne2}...`);
          const r1 = await checkMetroStatus(entry.ne1, entry.ne2, { mode: 'normal' });
          const r2 = await checkMetroStatus(entry.ne2, entry.ne1, { mode: 'normal' });
          const end = Date.now();
          return bot.sendMessage(chatId, `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${r1}\n────────────\n${r2}`);
        }
      }
    }

    if (data.startsWith('delete_')) {
      const index = parseInt(data.split('_')[1], 10);
      const entry = history[index];
      if (entry) {
        history.splice(index, 1);
        saveHistory();
        return bot.sendMessage(chatId, `✅ Riwayat ${entry.ne1}${entry.ne2?` ↔ ${entry.ne2}`:''} dihapus.`);
      }
    }
  } catch (e) {
    console.error('callback error:', e);
    bot.answerCallbackQuery(query.id, { text: '❌ Terjadi kesalahan. Coba lagi!', show_alert: true });
  }
});

// start WA jika enabled
if (APP.whatsappEnabled) startWhatsApp(false);

// graceful shutdown
function quit(){ try{bot.stopPolling();}catch{} try{stopWhatsApp(false);}catch{} setTimeout(()=>process.exit(0),500); }
process.on("SIGTERM", quit);
process.on("SIGINT", quit);

// ===== Admin features (help, list, add/remove) =====
const adminStore = require('./adminStore');
adminStore.seedFromEnv();

function isAdmin(chat) {
  // chat bisa berupa objek msg.chat atau angka
  const id = typeof chat === 'object' ? (chat.id || chat.from?.id) : chat;
  return adminStore.isAdmin(id);
}

function requireAdmin(ctx, fn) {
  if (!isAdmin(ctx.chat)) {
    return bot.sendMessage(ctx.chat.id, '🚫 Perintah ini khusus admin. Minta admin menambahkan ID kamu via /add_admin <telegram_id>.');
  }
  return fn();
}

// /help — daftar perintah
bot.on('message', async (msg) => {
  const text = String(msg.text || '').trim();
  if (!text) return;

  if (text === '/help' || text === '/start') {
    const lines = [
      '🧭 *Daftar Perintah*',
      '',
      '• `/cek NE_A NE_B` – cek dua sisi',
      '• `/cek NE_A` – cek satu NE (gabungan RX & Port)',
      '• `/history` – riwayat pengecekan',
      '• `/help` – menampilkan bantuan',
      '',
      '*Khusus Admin:*',
      '• `/admins` – lihat daftar admin',
      '• `/add_admin <telegram_id>` – tambah admin',
      '• `/remove_admin <telegram_id>` – hapus admin',
      '• `/wa_status` – status WhatsApp bot',
      '• `/wa_enable` – aktifkan WhatsApp bot',
      '• `/wa_disable` – nonaktifkan WhatsApp bot',
      '• `/wa_pair` – kirim QR login WhatsApp ke Telegram',
    ].join('\n');
    return bot.sendMessage(msg.chat.id, lines, { parse_mode: 'Markdown' });
  }

  if (text === '/admins') {
    return requireAdmin(msg, () => {
      const list = adminStore.listAdmins();
      const pretty = list.length ? list.map(x => `• ${x}`).join('\n') : '(kosong)';
      return bot.sendMessage(msg.chat.id, `👮 *Admin terdaftar:*\n${pretty}`, { parse_mode: 'Markdown' });
    });
  }

  if (text.startsWith('/add_admin')) {
    return requireAdmin(msg, () => {
      const id = text.split(/\s+/)[1];
      if (!id) return bot.sendMessage(msg.chat.id, '❗ Format: `/add_admin <telegram_id>`', { parse_mode: 'Markdown' });
      try {
        adminStore.addAdmin(id);
        return bot.sendMessage(msg.chat.id, `✅ Admin *${id}* ditambahkan.`, { parse_mode: 'Markdown' });
      } catch (e) {
        return bot.sendMessage(msg.chat.id, `❌ Gagal menambah admin: ${e.message}`);
      }
    });
  }

  if (text.startsWith('/remove_admin')) {
    return requireAdmin(msg, () => {
      const id = text.split(/\s+/)[1];
      if (!id) return bot.sendMessage(msg.chat.id, '❗ Format: `/remove_admin <telegram_id>`', { parse_mode: 'Markdown' });
      adminStore.removeAdmin(id);
      return bot.sendMessage(msg.chat.id, `🗑️ Admin *${id}* dihapus.`, { parse_mode: 'Markdown' });
    });
  }
});
