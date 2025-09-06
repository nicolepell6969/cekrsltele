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








const applySendSafe=require('./sendSafe');
try{applySendSafe(bot);}catch(e){console.error('WARN sendSafe:',e?.message||e)}
// === Force-safe long message sender ===
(function attachSafeSender(){
  try{
    const origSend = bot.sendMessage.bind(bot);

    function splitSmart(text, max=3900){
      const t = String(text ?? '');
      if (t.length <= max) return [t];

      // coba pecah di 


      const chunks = [];
      let rest = t;
      const push = (str)=>{ if (str && str.length) chunks.push(str); };

      function takeUntil(boundaryRegex){
        let out = '';
        while (rest.length){
          if (out.length + rest.length <= max){ out += rest; rest = ''; break; }
          // cari boundary terdekat sebelum max
          const slice = rest.slice(0, max - out.length);
          let cut = slice.search(boundaryRegex);
          if (cut === -1){ // tidak ketemu boundary; coba cari last newline/space
            const lastNl = slice.lastIndexOf('\n');
            const lastSp = slice.lastIndexOf(' ');
            cut = Math.max(lastNl, lastSp);
            if (cut <= 0) cut = slice.length; // terpaksa hard-cut
          }
          out += slice.slice(0, cut);
          rest = rest.slice(cut);
          break;
        }
        return out;
      }

      // strategi: ambil blok demi blok dengan preferensi 

      while (rest.length){
        let part = '';
        // 1) coba 


// [HOTFIX] stripped: // [HOTFIX] removed:         part = takeUntil(/

part = rest.slice(0, Math.min(max, rest.length));
        rest = rest.slice(part.length);
        if (part.length === 0) part = rest.slice(0, Math.min(max, rest.length)), rest = rest.slice(part.length);

        // kalau masih terlalu panjang, pecah lagi di 
 // atau spasi
        if (part.length > max){
          let p = part.slice(0, max);
          const lastNl = p.lastIndexOf('\n');
          const lastSp = p.lastIndexOf(' ');
          const cut = Math.max(lastNl, lastSp, 0) || p.length;
          push(p.slice(0, cut));
          rest = part.slice(cut) + rest;
        } else {
          push(part);
        }
      }
      // bersihkan potongan kosong
      return chunks.map(c => c).filter(Boolean);
    }

    // expose helper opsional
    bot.sendLong = async (chatId, text, extra={}) => {
      const parts = splitSmart(text, 3900);
      let last;
      for (const p of parts){
        // hindari error parse_mode karena potongan tidak sinkron
        const safeExtra = { ...extra };
        if (safeExtra.parse_mode) delete safeExtra.parse_mode;
        last = await origSend(chatId, p, safeExtra);
      }
      return last;
    };

    // Monkey-patch: semua pemanggilan sendMessage lewat pemecah
    bot.sendMessage = async (chatId, text, extra={}) => {
      if (typeof text !== 'string') return origSend(chatId, text, extra);
      const parts = splitSmart(text, 3900);
      if (parts.length === 1){
        // kirim biasa (hapus parse_mode bila mendekati limit)
        const safeExtra = { ...extra };
        if (text.length > 3800 && safeExtra.parse_mode) delete safeExtra.parse_mode;
        return origSend(chatId, text, safeExtra);
      }
      let last;
      for (const p of parts){
        const safeExtra = { ...extra };
        if (safeExtra.parse_mode) delete safeExtra.parse_mode;
        last = await origSend(chatId, p, safeExtra);
      }
      return last;
    };
  }catch(e){
    console.error('WARN attachSafeSender:', e && e.message ? e.message : e);
  }
})();
// === Force-safe long message sender ===
(function attachSafeSender(){
  try{
    const origSend = bot.sendMessage.bind(bot);

    function splitSmart(text, max=3900){
      const t = String(text ?? '');
      if (t.length <= max) return [t];

      // coba pecah di 


      const chunks = [];
      let rest = t;
      const push = (str)=>{ if (str && str.length) chunks.push(str); };

      function takeUntil(boundaryRegex){
        let out = '';
        while (rest.length){
          if (out.length + rest.length <= max){ out += rest; rest = ''; break; }
          // cari boundary terdekat sebelum max
          const slice = rest.slice(0, max - out.length);
          let cut = slice.search(boundaryRegex);
          if (cut === -1){ // tidak ketemu boundary; coba cari last newline/space
            const lastNl = slice.lastIndexOf('\n');
            const lastSp = slice.lastIndexOf(' ');
            cut = Math.max(lastNl, lastSp);
            if (cut <= 0) cut = slice.length; // terpaksa hard-cut
          }
          out += slice.slice(0, cut);
          rest = rest.slice(cut);
          break;
        }
        return out;
      }

      // strategi: ambil blok demi blok dengan preferensi 

      while (rest.length){
        let part = '';
        // 1) coba 


// [HOTFIX] stripped: // [HOTFIX] removed:         part = takeUntil(/

part = rest.slice(0, Math.min(max, rest.length));
        rest = rest.slice(part.length);
        if (part.length === 0) part = rest.slice(0, Math.min(max, rest.length)), rest = rest.slice(part.length);

        // kalau masih terlalu panjang, pecah lagi di 
 // atau spasi
        if (part.length > max){
          let p = part.slice(0, max);
          const lastNl = p.lastIndexOf('\n');
          const lastSp = p.lastIndexOf(' ');
          const cut = Math.max(lastNl, lastSp, 0) || p.length;
          push(p.slice(0, cut));
          rest = part.slice(cut) + rest;
        } else {
          push(part);
        }
      }
      // bersihkan potongan kosong
      return chunks.map(c => c).filter(Boolean);
    }

    // expose helper opsional
    bot.sendLong = async (chatId, text, extra={}) => {
      const parts = splitSmart(text, 3900);
      let last;
      for (const p of parts){
        // hindari error parse_mode karena potongan tidak sinkron
        const safeExtra = { ...extra };
        if (safeExtra.parse_mode) delete safeExtra.parse_mode;
        last = await origSend(chatId, p, safeExtra);
      }
      return last;
    };

    // Monkey-patch: semua pemanggilan sendMessage lewat pemecah
    bot.sendMessage = async (chatId, text, extra={}) => {
      if (typeof text !== 'string') return origSend(chatId, text, extra);
      const parts = splitSmart(text, 3900);
      if (parts.length === 1){
        // kirim biasa (hapus parse_mode bila mendekati limit)
        const safeExtra = { ...extra };
        if (text.length > 3800 && safeExtra.parse_mode) delete safeExtra.parse_mode;
        return origSend(chatId, text, safeExtra);
      }
      let last;
      for (const p of parts){
        const safeExtra = { ...extra };
        if (safeExtra.parse_mode) delete safeExtra.parse_mode;
        last = await origSend(chatId, p, safeExtra);
      }
      return last;
    };
  }catch(e){
    console.error('WARN attachSafeSender:', e && e.message ? e.message : e);
  }
})();
// === Force-safe long message sender ===
(function attachSafeSender(){
  try{
    const origSend = bot.sendMessage.bind(bot);

    function splitSmart(text, max=3900){
      const t = String(text ?? '');
      if (t.length <= max) return [t];

      // coba pecah di 


      const chunks = [];
      let rest = t;
      const push = (str)=>{ if (str && str.length) chunks.push(str); };

      function takeUntil(boundaryRegex){
        let out = '';
        while (rest.length){
          if (out.length + rest.length <= max){ out += rest; rest = ''; break; }
          // cari boundary terdekat sebelum max
          const slice = rest.slice(0, max - out.length);
          let cut = slice.search(boundaryRegex);
          if (cut === -1){ // tidak ketemu boundary; coba cari last newline/space
            const lastNl = slice.lastIndexOf('\n');
            const lastSp = slice.lastIndexOf(' ');
            cut = Math.max(lastNl, lastSp);
            if (cut <= 0) cut = slice.length; // terpaksa hard-cut
          }
          out += slice.slice(0, cut);
          rest = rest.slice(cut);
          break;
        }
        return out;
      }

      // strategi: ambil blok demi blok dengan preferensi 

      while (rest.length){
        let part = '';
        // 1) coba 


// [HOTFIX] stripped: // [HOTFIX] removed:         part = takeUntil(/

part = rest.slice(0, Math.min(max, rest.length));
        rest = rest.slice(part.length);
        if (part.length === 0) part = rest.slice(0, Math.min(max, rest.length)), rest = rest.slice(part.length);

        // kalau masih terlalu panjang, pecah lagi di 
 // atau spasi
        if (part.length > max){
          let p = part.slice(0, max);
          const lastNl = p.lastIndexOf('\n');
          const lastSp = p.lastIndexOf(' ');
          const cut = Math.max(lastNl, lastSp, 0) || p.length;
          push(p.slice(0, cut));
          rest = part.slice(cut) + rest;
        } else {
          push(part);
        }
      }
      // bersihkan potongan kosong
      return chunks.map(c => c).filter(Boolean);
    }

    // expose helper opsional
    bot.sendLong = async (chatId, text, extra={}) => {
      const parts = splitSmart(text, 3900);
      let last;
      for (const p of parts){
        // hindari error parse_mode karena potongan tidak sinkron
        const safeExtra = { ...extra };
        if (safeExtra.parse_mode) delete safeExtra.parse_mode;
        last = await origSend(chatId, p, safeExtra);
      }
      return last;
    };

    // Monkey-patch: semua pemanggilan sendMessage lewat pemecah
    bot.sendMessage = async (chatId, text, extra={}) => {
      if (typeof text !== 'string') return origSend(chatId, text, extra);
      const parts = splitSmart(text, 3900);
      if (parts.length === 1){
        // kirim biasa (hapus parse_mode bila mendekati limit)
        const safeExtra = { ...extra };
        if (text.length > 3800 && safeExtra.parse_mode) delete safeExtra.parse_mode;
        return origSend(chatId, text, safeExtra);
      }
      let last;
      for (const p of parts){
        const safeExtra = { ...extra };
        if (safeExtra.parse_mode) delete safeExtra.parse_mode;
        last = await origSend(chatId, p, safeExtra);
      }
      return last;
    };
  }catch(e){
    console.error('WARN attachSafeSender:', e && e.message ? e.message : e);
  }
})();
/** kirim pesan panjang aman untuk Telegram (tanpa kirim .txt) */
async function sendLong(chatId, text, extra = {}) {
  const MAX = 3900; // <4096, beri buffer
  const t = String(text ?? '');
  if (t.length <= MAX) return bot.sendMessage(chatId, t, extra);

  const lines = t.split('\n');
  let buf = '';
  for (const line of lines) {
    const would = buf ? (buf + '\n' + line) : line;
    if (would.length > MAX) {
      await bot.sendMessage(chatId, buf, extra);
      buf = line;
    } else {
      buf = would;
    }
  }
  if (buf) await bot.sendMessage(chatId, buf, extra);
}



// === Helper: kirim pesan ke semua admin dari ENV ADMIN_IDS atau adminStore ===
async function sendToAdmins(text, opts = {}) {
  try {
    let ids = [];
    try {
      if (adminStore?.listAdmins) ids = adminStore.listAdmins().map(String);
    } catch {}
    if (!ids.length) {
      ids = String(process.env.ADMIN_IDS || '')
        .split(',')
        .map(v => v.trim())
        .filter(Boolean);
    }
    // fallback: kirim ke chat terakhir yang memulai bot (jika ada) â abaikan jika tidak ada.
    if (!ids.length && typeof lastChatId !== 'undefined' && lastChatId) {
      ids = [String(lastChatId)];
    }
    for (const id of ids) {
      try { await bot.sendMessage(id, text, opts); } catch {}
    }
  } catch {}
}
bot.getMe().then(me=>console.log(`Telegram bot: @${me.username} (id:${me.id})`)).catch(e=>console.error('getMe error:', e?.message));
bot.on('polling_error', (err)=> console.error('polling_error:', err?.response?.body || err?.message || err));

// === WhatsApp (opsional) ===
let WA_ENABLED = (String(process.env.WA_ENABLED||'false').toLowerCase()==='true');
let waClient=null, makeWASocket, useMultiFileAuthState, fetchLatestBaileysVersion;
try { ({ default: makeWASocket, useMultiFileAuthState, fetchLatestBaileysVersion } = require('@whiskeysockets/baileys')); } catch {}

async function waStart(notifyChatId){
  if (!WA_ENABLED) return;
  if (waClient || !makeWASocket) return;
  const { state, saveCreds } = await useMultiFileAuthState(path.join(__dirname,'wa_auth'));
  let version = [2,3000,0]; try { ({ version } = await fetchLatestBaileysVersion()); } catch {}

  const sock = makeWASocket({ version, auth: state, printQRInTerminal:false, syncFullHistory:false, browser:['cekrsltele','Chrome','1.0'] });
  
  // === WA connection.update (QR sebagai foto dengan fallback ASCII) ===
            const buf = await QR.toBuffer(qr, { type: 'png', scale: 8, margin: 1 });
          await bot.sendPhoto(notifyChatId, buf, {
            caption: 'ð² Scan QR WhatsApp berikut (Â±60 detik). Jika kadaluarsa, kirim /wa_pair lagi.'
          });
        } catch (e) {
          try {
            const qrt = require('qrcode-terminal');
            let ascii = '';
            qrt.generate(qr, { small: true }, c => ascii = c);
            await bot.sendMessage(notifyChatId, 'QR WhatsApp (fallback ASCII):\n\n' + ascii);
          } catch (e2) {
            await bot.sendMessage(notifyChatId, 'Gagal membuat QR image: ' + (e && e.message ? e.message : e));
          }
        }
      })();
    }
    if (connection === 'open') {
      if (notifyChatId) bot.sendMessage(notifyChatId, 'â WhatsApp tersambung.');
    } else if (connection === 'close') {
      const reason = (lastDisconnect && lastDisconnect.error && lastDisconnect.error.message) || 'Terputus';
      if (notifyChatId) bot.sendMessage(notifyChatId, 'â ï¸ WhatsApp terputus: ' + reason);
      try { if (globalThis.waClient) globalThis.waClient = null; } catch {}
    }
  });

waClient = sock;
  sock.ev.on('creds.update', saveCreds);
          const end = Date.now();
        addHistory(ne, null, result, ne, start, end);
        return bot.sendMessage(chatId, `ðChecked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${result}`);
      } catch(e){
        return bot.sendMessage(chatId, 'â Gagal cek 1 NE: '+(e?.message||e));
      }
    }

    // 2 NE
    if (parts.length >= 2) {
      const ne1 = parts[0], ne2 = parts[1];
      await bot.sendMessage(chatId, `ð ONCEK, DITUNGGU`);
      try {
        const start = Date.now();
        const r1 = await runWithTimeout(checkMetroStatus(ne1, ne2, { mode: 'normal' }), Number(process.env.CEK_TIMEOUT_MS || 180000));
        const r2 = await runWithTimeout(checkMetroStatus(ne2, ne1, { mode: 'normal' }), Number(process.env.CEK_TIMEOUT_MS || 180000));
        const end = Date.now();
        const combined = `${r1}\nââââââââââââ\n${r2}`;
        addHistory(ne1, ne2, combined, `${ne1} ${ne2}`, start, end);
        return bot.sendMessage(chatId, `ðChecked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${combined}`, {
          reply_markup: { inline_keyboard: [[{ text: 'ð CEK ULANG', callback_data: `retry_last_${history.length-1}` }]] }
        });
      } catch(e){
        return bot.sendMessage(chatId, 'â Gagal cek 2 sisi: '+(e?.message||e));
      }
    }

    // salah format
    return bot.sendMessage(chatId, 'â Format: /cek <NE1> [NE2]');
  }

  // ===== /history =====
  if (low === '/history') {
    if (!history.length) return bot.sendMessage(chatId, 'â Belum ada riwayat pengecekan.');
    return bot.sendMessage(chatId, 'ð Klik di bawah untuk cek ulang atau hapus riwayat:', {
      reply_markup: { inline_keyboard: createHistoryButtons() }
    });
  }

  // ===== Teks bebas -> parsing NE =====
  if (text) {
    const { cmd, list, note } = buildCekCommandFromText(text);
    if (list && list.length === 1) {
      const ne = list[0];
      return bot.sendMessage(chatId, `â¹ï¸ Hanya menemukan 1 NE dari teks.\nNE terdeteksi: ${ne}\n\nGunakan perintah ini:\n/cek ${ne}`, {
        reply_markup: { inline_keyboard: [[{ text: 'â¶ï¸ Jalankan sekarang', callback_data: `runcek1_${ne}` }]] }
      });
    }
    if (list && list.length >= 2) {
      const a = list[0], b = list.find(x=>x!==a) || list[1];
      return bot.sendMessage(chatId, `NE terdeteksi: ${list.join(', ')}\n\nGunakan perintah ini:\n/cek ${a} ${b}`, {
        reply_markup: { inline_keyboard: [[{ text: 'â¶ï¸ Jalankan sekarang', callback_data: `runcek_${a}_${b}` }]] }
      });
    }
  }

  // BUKAN perintah & bukan teks yang bisa diparse â jangan spam warning
});

// ===== Callback (cek ulang, run now, hapus) =====
bot.on('callback_query', async (q)=>{
  const { data, message } = q;
  const chatId = message.chat.id;
  try {
    await bot.answerCallbackQuery(q.id);

    if (data.startsWith('runcek_')) {
      const [, ne1, ne2] = data.split('_');
      await bot.sendMessage(chatId, `ð Checking: ${ne1} â ${ne2}...`);
      const r1 = await runWithTimeout(checkMetroStatus(ne1, ne2, { mode: 'normal' }), Number(process.env.CEK_TIMEOUT_MS || 180000));
      const r2 = await runWithTimeout(checkMetroStatus(ne2, ne1, { mode: 'normal' }), Number(process.env.CEK_TIMEOUT_MS || 180000));
      const end = Date.now();
      return bot.sendMessage(chatId, `ðChecked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${r1}\nââââââââââââ\n${r2}`, {
        reply_markup: { inline_keyboard: [[{ text: 'ð Cek ulang', callback_data: `runcek_${ne1}_${ne2}` }]] }
      });
    }

    if (data.startsWith('runcek1_')) {
      const ne = data.substring('runcek1_'.length);
      await bot.sendMessage(chatId, `ð Checking: ${ne}...`);
      const result = await runWithTimeout(checkMetroStatus.checkSingleNE(ne), Number(process.env.CEK_TIMEOUT_MS || 120000));
      const end = Date.now();
      return bot.sendMessage(chatId, `ðChecked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${result}`, {
        reply_markup: { inline_keyboard: [[{ text: 'ð Cek ulang', callback_data: `runcek1_${ne}` }]] }
      });
    }

    if (data.startsWith('retry_')) {
      let index = null;
      if (data.startsWith('retry_last_')) index = parseInt(data.split('_').pop(), 10);
      else index = parseInt(data.split('_')[1], 10);
      const e = history[index];
      if (e) {
        if (!e.ne2) {
          await bot.sendMessage(chatId, `ð Checking: ${e.ne1}...`);
          const result = await runWithTimeout(checkMetroStatus.checkSingleNE(e.ne1), Number(process.env.CEK_TIMEOUT_MS || 120000));
          const end = Date.now();
          return bot.sendMessage(chatId, `ðChecked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${result}`, {
            reply_markup: { inline_keyboard: [[{ text: 'ð Cek ulang', callback_data: `runcek1_${e.ne1}` }]] }
          });
        } else {
          await bot.sendMessage(chatId, `ð Checking: ${e.ne1} â ${e.ne2}...`);
          const r1 = await runWithTimeout(checkMetroStatus(e.ne1, e.ne2, { mode: 'normal' }), Number(process.env.CEK_TIMEOUT_MS || 180000));
          const r2 = await runWithTimeout(checkMetroStatus(e.ne2, e.ne1, { mode: 'normal' }), Number(process.env.CEK_TIMEOUT_MS || 180000));
          const end = Date.now();
          return bot.sendMessage(chatId, `ðChecked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${r1}\nââââââââââââ\n${r2}`, {
            reply_markup: { inline_keyboard: [[{ text: 'ð Cek ulang', callback_data: `runcek_${e.ne1}_${e.ne2}` }]] }
          });
        }
      }
    }

    if (data.startsWith('delete_')) {
      const index = parseInt(data.split('_')[1], 10);
      const e = history[index];
      if (e) {
        history.splice(index, 1);
        saveHistory();

        // Auto-refresh UI /history pada pesan yang sama
        const kb = createHistoryButtons();
        try {
          await bot.editMessageText('👉 Klik di bawah untuk cek ulang atau hapus riwayat:', {
            chat_id: chatId,
            message_id: message.message_id,
            reply_markup: { inline_keyboard: kb }
          });
        } catch (err1) {
          // Fallback: minimal refresh keyboard
          try {
            await bot.editMessageReplyMarkup({ inline_keyboard: kb }, {
              chat_id: chatId,
              message_id: message.message_id
            });
          } catch (err2) {}
        }
      }
      return;
    }
    }
  } catch(err){
    console.error('callback error:', err);
    bot.answerCallbackQuery(q.id, { text: 'â Terjadi kesalahan. Coba lagi!', show_alert: true }).catch(()=>{});
  }
});

// === OPTIONAL: kirim error penting ke admin pertama ===
function notifyAdmins(text){
  const admins = adminStore.listAdmins();
  const target = admins[0];
  if (target) bot.sendMessage(Number(target), text).catch(()=>{});
}
process.on('unhandledRejection', err=> notifyAdmins('â ï¸ unhandledRejection: '+(err?.message||err)));
process.on('uncaughtException', err=> { notifyAdmins('â ï¸ uncaughtException: '+(err?.message||err)); setTimeout(()=>process.exit(1), 500); });


// === global error handlers: kirim error ke admin & exit agar systemd restart ===
process.on('unhandledRejection', async (err) => {
  try { await sendToAdmins('â *UnhandledRejection*\n' + (err?.stack || err)); } catch {}
  // tidak exit, biar lanjut jalan
});
process.on('uncaughtException', async (err) => {
  try { await sendToAdmins('â *UncaughtException*\n' + (err?.stack || err)); } catch {}
  // exit biar systemd auto-restart
  setTimeout(() => process.exit(1), 500);
});
