const TelegramBot = require('node-telegram-bot-api');
const fs = require('fs');
const checkMetroStatus = require('./checkMetroStatus');
const { buildCekCommandFromText } = require('./textToCommand');

const token = process.env.TELEGRAM_BOT_TOKEN || '';
const bot = new TelegramBot(token, { polling: true });

const historyFilePath = './history.json';
let history = [];
try { if (fs.existsSync(historyFilePath)) { const raw = fs.readFileSync(historyFilePath); if (raw) history = JSON.parse(raw); } } catch(e){ history = []; }

function saveHistory(){ try{ fs.writeFileSync(historyFilePath, JSON.stringify(history,null,2)); } catch(e){} }
function isDuplicate(ne1, ne2){ return history.some(h => (h.ne1===ne1 && h.ne2===ne2) || (h.ne1===ne2 && h.ne2===ne1)); }
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

bot.on('message', async (msg) => {
  const chatId = msg.chat.id;
  const text = (msg.text || '').trim();
  const low = text.toLowerCase();

  // ===== /cek =====
  if (low.startsWith('/cek ')) {
    const parts = text.split(' ').slice(1).map(s => s.trim()).filter(Boolean);

    // Mode 1 NE
    if (parts.length === 1) {
      const ne = parts[0];
      // tampilkan tombol jalankan sekarang
      await bot.sendMessage(chatId, `Perintah terdeteksi: /cek ${ne}`, {
        reply_markup: { inline_keyboard: [[{ text: '▶️ Jalankan sekarang', callback_data: `runcek1_${ne}` }]] }
      });
      // tetap auto-run seperti sebelumnya
      const start = Date.now();
      const result = await checkMetroStatus.checkSingleNE(ne);
      const end = Date.now();
      addHistory(ne, null, result, ne, start, end);
      return bot.sendMessage(chatId, `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${result}`, {
        reply_markup: { inline_keyboard: [[{ text: '🔁 Cek ulang', callback_data: `runcek1_${ne}` }]] }
      });
    }

    // Mode 2 NE
    if (parts.length === 2) {
      const [ne1, ne2] = parts;
      // tombol jalankan sekarang
      await bot.sendMessage(chatId, `Perintah terdeteksi: /cek ${ne1} ${ne2}`, {
        reply_markup: { inline_keyboard: [[{ text: '▶️ Jalankan sekarang', callback_data: `runcek_${ne1}_${ne2}` }]] }
      });
      // tetap auto-run seperti sebelumnya
      const start = Date.now();
      const r1 = await checkMetroStatus(ne1, ne2, { mode: 'normal' });
      const r2 = await checkMetroStatus(ne2, ne1, { mode: 'normal' });
      const end = Date.now();
      const combined = `${r1}\n────────────\n${r2}`;
      addHistory(ne1, ne2, combined, `${ne1} ${ne2}`, start, end);
      return bot.sendMessage(chatId, `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${combined}`, {
        reply_markup: { inline_keyboard: [[{ text: '🔁 Cek ulang', callback_data: `runcek_${ne1}_${ne2}` }]] }
      });
    }

    return bot.sendMessage(chatId, '❗ Format: /cek <NE1> [NE2]');
  }

  // ===== /history =====
  if (low === '/history') {
    if (!history.length) return bot.sendMessage(chatId, '❌ Belum ada riwayat pengecekan.');
    return bot.sendMessage(chatId, '👉 Klik di bawah untuk cek ulang atau hapus riwayat:', {
      reply_markup: { inline_keyboard: createHistoryButtons() }
    });
  }

  // ===== Teks bebas -> ekstrak NE =====
  if (text) {
    const { cmd, list, note } = buildCekCommandFromText(text);

    // 1 NE terdeteksi: tampilkan tombol + auto-run
    if (list && list.length === 1) {
      const ne = list[0];
      await bot.sendMessage(chatId, `ℹ️ Hanya menemukan 1 NE dari teks.\nNE terdeteksi: ${ne}\n\nGunakan perintah ini:\n/cek ${ne}`, {
        reply_markup: { inline_keyboard: [[{ text: '▶️ Jalankan sekarang', callback_data: `runcek1_${ne}` }]] }
      });
      const start = Date.now();
      const result = await checkMetroStatus.checkSingleNE(ne);
      const end = Date.now();
      addHistory(ne, null, result, ne, start, end);
      return bot.sendMessage(chatId, `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${result}`, {
        reply_markup: { inline_keyboard: [[{ text: '🔁 Cek ulang', callback_data: `runcek1_${ne}` }]] }
      });
    }

    // ≥ 2 NE terdeteksi: tampilkan tombol jalankan sekarang
    if (list && list.length >= 2) {
      const a = list[0], b = list.find(x => x !== a) || list[1];
      return bot.sendMessage(chatId, `NE terdeteksi: ${list.join(', ')}\n\nGunakan perintah ini:\n/cek ${a} ${b}`, {
        reply_markup: { inline_keyboard: [[{ text: '▶️ Jalankan sekarang', callback_data: `runcek_${a}_${b}` }]] }
      });
    }
  }

  return bot.sendMessage(chatId, '👍');
});

// ===== Callback (jalankan sekarang / cek ulang / hapus / retry riwayat) =====
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

    // retry/hapus riwayat lama
    if (data.startsWith('retry_')) {
      let index = null;
      if (data.startsWith('retry_last_')) index = parseInt(data.split('_').pop(), 10);
      else index = parseInt(data.split('_')[1], 10);
      const entry = history[index];
      if (entry) {
        if (!entry.ne2) {
          await bot.sendMessage(chatId, `🔄 Checking: ${entry.ne1}...`);
          const result = await checkMetroStatus.checkSingleNE(entry.ne1);
          const end = Date.now();
          return bot.sendMessage(chatId, `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${result}`, {
            reply_markup: { inline_keyboard: [[{ text: '🔁 Cek ulang', callback_data: `runcek1_${entry.ne1}` }]] }
          });
        } else {
          await bot.sendMessage(chatId, `🔄 Checking: ${entry.ne1} ↔ ${entry.ne2}...`);
          const r1 = await checkMetroStatus(entry.ne1, entry.ne2, { mode: 'normal' });
          const r2 = await checkMetroStatus(entry.ne2, entry.ne1, { mode: 'normal' });
          const end = Date.now();
          return bot.sendMessage(chatId, `🕛Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${r1}\n────────────\n${r2}`, {
            reply_markup: { inline_keyboard: [[{ text: '🔁 Cek ulang', callback_data: `runcek_${entry.ne1}_${entry.ne2}` }]] }
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
        return bot.sendMessage(chatId, `✅ Riwayat ${entry.ne1}${entry.ne2?` ↔ ${entry.ne2}`:''} dihapus.`);
      }
    }
  } catch (e) {
    console.error('callback error:', e);
    bot.answerCallbackQuery(query.id, { text: '❌ Terjadi kesalahan. Coba lagi!', show_alert: true });
  }
});
