const TelegramBot = require('node-telegram-bot-api');
const fs = require('fs');
const checkMetroStatus = require('./checkMetroStatus');
const { buildCekCommandFromText } = require('./textToCommand');

const token = process.env.TELEGRAM_BOT_TOKEN || '';
const bot = new TelegramBot(token, { polling: true });

/* ===== util kirim aman (chunking) ===== */
async function safeSend(chatId, text, extra = {}) {
  const MAX = 3500; // < limit Telegram
  try {
    if (!text || text.length <= MAX) return await bot.sendMessage(chatId, text || '(kosong)', extra);
    const lines = text.split('\n');
    let buf = '';
    for (const ln of lines) {
      if ((buf + ln + '\n').length > MAX) { await bot.sendMessage(chatId, buf, extra); buf = ''; }
      buf += ln + '\n';
    }
    if (buf.trim().length) await bot.sendMessage(chatId, buf, extra);
  } catch (e) {
    console.error('safeSend error:', e?.response?.body || e);
    await bot.sendMessage(chatId, '❌ Gagal mengirim pesan (mungkin terlalu panjang).');
  }
}

/* ===== history ===== */
const historyFilePath = './history.json';
let history = [];
try { if (fs.existsSync(historyFilePath)) { const raw = fs.readFileSync(historyFilePath); if (raw) history = JSON.parse(raw); } }
catch { history = []; }
function saveHistory(){ try{ fs.writeFileSync(historyFilePath, JSON.stringify(history,null,2)); } catch{} }
function addHistory(ne1, ne2, start, end){
  history.push({ ne1, ne2: ne2||'', timestamp: new Date(end).toLocaleString('id-ID',{timeZone:'Asia/Jakarta'}), duration: ((end-start)/1000)||0 });
  saveHistory();
}
function createHistoryButtons(){
  return history.map((e,i)=> ([
    { text:`Ulangi ${e.ne1}${e.ne2?` ↔ ${e.ne2}`:''}`, callback_data:`retry_${i}` },
    { text:`Hapus ${e.ne1}${e.ne2?` ↔ ${e.ne2}`:''}`, callback_data:`delete_${i}` },
  ]));
}

const btnRun1 = (ne) => ({ reply_markup:{ inline_keyboard:[[ {text:'▶️ Jalankan sekarang', callback_data:`runcek1_${ne}`} ]] }});
const btnRun2 = (a,b)=> ({ reply_markup:{ inline_keyboard:[[ {text:'▶️ Jalankan sekarang', callback_data:`runcek_${a}_${b}`} ]] }});

/* ===== helper timeout ===== */
function withTimeout(promise, ms){
  let t; const killer = new Promise((_,rej)=>{ t=setTimeout(()=>rej(new Error(`Timeout ${ms}ms`)), ms); });
  return Promise.race([promise.finally(()=>clearTimeout(t)), killer]);
}

/* ===== /cek & parsing teks: TAMPILKAN TOMBOL SAJA (tanpa auto-run) ===== */
bot.on('message', async (msg) => {
  const chatId = msg.chat.id;
  const text = (msg.text||'').trim().toLowerCase();

  if (text.startsWith('/cek ')) {
    const parts = (msg.text||'').split(' ').slice(1).map(s=>s.trim()).filter(Boolean);
    if (parts.length === 1) return safeSend(chatId, `Perintah terdeteksi: /cek ${parts[0]}`, btnRun1(parts[0]));
    if (parts.length === 2) return safeSend(chatId, `Perintah terdeteksi: /cek ${parts[0]} ${parts[1]}`, btnRun2(parts[0],parts[1]));
    return safeSend(chatId, '❗ Format: /cek <NE1> [NE2]');
  }

  if (text === '/history') {
    if (!history.length) return safeSend(chatId, '❌ Belum ada riwayat pengecekan.');
    return safeSend(chatId, '👉 Klik di bawah untuk cek ulang atau hapus riwayat:', { reply_markup:{ inline_keyboard: createHistoryButtons() } });
  }

  if (msg.text) {
    const { list } = buildCekCommandFromText(msg.text);
    if (list && list.length === 1) {
      const ne = list[0];
      return safeSend(chatId, `ℹ️ Hanya menemukan 1 NE dari teks.\nNE terdeteksi: ${ne}\n\nGunakan perintah ini:\n/cek ${ne}`, btnRun1(ne));
    }
    if (list && list.length >= 2) {
      const a=list[0], b=list.find(x=>x!==a)||list[1];
      return safeSend(chatId, `NE terdeteksi: ${list.join(', ')}\n\nGunakan perintah ini:\n/cek ${a} ${b}`, btnRun2(a,b));
    }
  }

  return safeSend(chatId, '👍');
});

/* ===== callback tombol (debounce + timeout + 1× cek) ===== */
const inflight = new Map();

bot.on('callback_query', async (q) => {
  const { data, message } = q;
  const chatId = message.chat.id;
  try { await bot.answerCallbackQuery(q.id); } catch {}

  if (!/^runcek(1)?_/.test(data)) return;
  if (inflight.has(data)) return safeSend(chatId, '⏳ Masih memproses permintaan sebelumnya. Tunggu ya…');
  inflight.set(data, true);

  try {
    if (data.startsWith('runcek1_')) {
      const ne = data.substring('runcek1_'.length);
      await safeSend(chatId, `🔄 Checking: ${ne}…`);
      const start = Date.now();
      const out   = await withTimeout(checkMetroStatus.checkSingleNE(ne), 90_000);
      const end   = Date.now();
      addHistory(ne, null, start, end);
      return safeSend(chatId, `🕛Checked Time: ${new Date(end).toLocaleString('id-ID',{timeZone:'Asia/Jakarta'})}\n\n${out}`, {
        reply_markup:{ inline_keyboard:[[ {text:'🔁 Cek ulang', callback_data:data} ]] }
      });
    }

    if (data.startsWith('runcek_')) {
      const [, ne1, ne2] = data.split('_');
      await safeSend(chatId, `🔄 Checking: ${ne1} ↔ ${ne2}…`);
      const start = Date.now();

      // PENTING: cek SEKALI SAJA (fungsi sudah mengembalikan 2 sisi)
      const out = await withTimeout(checkMetroStatus(ne1, ne2, { mode:'normal' }), 90_000);

      const end = Date.now();
      addHistory(ne1, ne2, start, end);
      return safeSend(chatId, `🕛Checked Time: ${new Date(end).toLocaleString('id-ID',{timeZone:'Asia/Jakarta'})}\n\n${out}`, {
        reply_markup:{ inline_keyboard:[[ {text:'🔁 Cek ulang', callback_data:data} ]] }
      });
    }
  } catch (e) {
    console.error('callback error:', e);
    await safeSend(chatId, `❌ Error: ${e.message || e}`);
  } finally {
    inflight.delete(data);
  }
});

/* ===== graceful shutdown ===== */
function quit(){ try{bot.stopPolling();}catch{} setTimeout(()=>process.exit(0),500); }
process.on('SIGTERM', quit); process.on('SIGINT', quit);
