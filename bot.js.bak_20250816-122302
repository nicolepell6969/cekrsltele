require('dotenv').config();
const TelegramBot = require('node-telegram-bot-api');
const fs = require('fs');
const checkMetroStatus = require('./checkMetroStatus');
const { launchBrowser } = require('./checkMetroStatus');

const token = process.env.TELEGRAM_BOT_TOKEN;
if (!token) { console.error('ENV TELEGRAM_BOT_TOKEN belum diset.'); process.exit(1); }

const bot = new TelegramBot(token, { polling: true });
const historyFilePath = './history.json';
const MAX_HISTORY = 50;

/* ===================== HISTORY ===================== */
let history = [];
try {
  if (fs.existsSync(historyFilePath)) {
    const buf = fs.readFileSync(historyFilePath, 'utf8');
    history = JSON.parse(buf || '[]');
    if (!Array.isArray(history)) history = [];
  }
} catch { history = []; }

function writeHistory() {
  try { fs.writeFileSync(historyFilePath, JSON.stringify(history, null, 2), 'utf8'); }
  catch (e) { console.error('Gagal simpan history:', e.message); }
}
function safeShort(ne) {
  const parts = String(ne).split('-'); const mid = parts.length > 1 ? parts[1] : parts[0];
  return (mid || '').slice(0, 4) || ne.slice(0, 4);
}
function isDuplicate(ne1, ne2) {
  return history.some(h => (h.ne1 === ne1 && h.ne2 === ne2) || (h.ne1 === ne2 && h.ne2 === ne1));
}
function addHistory(ne1, ne2, result, name, startTime, endTime) {
  if (isDuplicate(ne1, ne2)) return;
  const duration = ((endTime || Date.now()) - startTime) / 1000;
  const timestamp = new Date(endTime || Date.now()).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' });
  history.push({ name, ne1, ne2, shortNe1: safeShort(ne1), shortNe2: safeShort(ne2), result, timestamp, duration });
  if (history.length > MAX_HISTORY) history = history.slice(-MAX_HISTORY);
  writeHistory();
}
function buildHistoryKeyboard() {
  return history.map((e, i) => ([
    { text: `🔄 Cek ulang ${e.shortNe1} ↔ ${e.shortNe2}`, callback_data: `retry_${i}` },
    { text: `🗑️ Hapus ${e.shortNe1} ↔ ${e.shortNe2}`, callback_data: `delete_${i}` }
  ]));
}

/* =========== Auto-extract NE dari teks bebas =========== */
/* Pola NE: huruf/angka dengan dash, >= 3 segmen — contoh: SBY-PRDU-OPT-H910D */
const NE_REGEX = /\b([A-Z]{2,}-[A-Z0-9]{2,}(?:-[A-Z0-9]{2,}){1,})\b/g;

function extractNEs(raw) {
  if (!raw) return [];
  const text = String(raw).toUpperCase();

  // Utamakan yang muncul sebagai NE[...]
  const inBracket = Array.from(text.matchAll(/NE\[(.*?)\]/g))
    .map(m => m[1].trim().toUpperCase())
    .filter(Boolean);

  // Tangkap pola umum di seluruh teks
  const all = Array.from(text.matchAll(NE_REGEX))
    .map(m => m[1].trim().toUpperCase());

  // Gabungkan (prioritas inBracket), lalu unik
  const merged = [...inBracket, ...all];
  const unique = [];
  for (const s of merged) if (!unique.includes(s)) unique.push(s);
  return unique;
}
function baseKey(ne) {
  const parts = ne.split('-'); return parts[1] || ne;
}
function sortNEPair([a, b]) {
  if (!a || !b) return [a, b];
  return baseKey(a) <= baseKey(b) ? [a, b] : [b, a];
}

/* ===================== UI helpers ===================== */
function makeRerunButtons(ne1, ne2) {
  return {
    reply_markup: {
      inline_keyboard: [[{ text: '🔄 Cek ulang', callback_data: `rerun_${ne1}__${ne2}` }]]
    }
  };
}

/* ===================== Message Handler ===================== */
bot.on('message', async (msg) => {
  if (!msg.text) return;
  const text = msg.text.trim();
  const lower = text.toLowerCase();

  // /cek NE1 NE2
  if (lower.startsWith('/cek ')) {
    const args = text.split(' ').slice(1).map(s => s.trim()).filter(Boolean);
    if (args.length !== 2) {
      return bot.sendMessage(msg.chat.id, '❗ Format salah.\nContoh: /cek SBY-GDK-EN1-H8M14 SBY-BDKL-OPT-H910C');
    }
    const [ne1, ne2] = args;
    const name = `${ne1} ${ne2}`;
    await bot.sendMessage(msg.chat.id, '🔄 Mengecek dua sisi, mohon tunggu…');

    const start = Date.now();
    const browser = await launchBrowser();
    try {
      const textOut = await checkMetroStatus(ne1, ne2, { browser, returnStructured: false });
      const end = Date.now();
      addHistory(ne1, ne2, textOut, name, start, end);
      await bot.sendMessage(
        msg.chat.id,
        `🕛 Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${textOut}`,
        makeRerunButtons(ne1, ne2)
      );
    } catch (e) {
      console.error(e);
      await bot.sendMessage(msg.chat.id, `❌ Gagal melakukan pengecekan: ${e.message || e}`);
    } finally {
      await browser.close().catch(() => {});
    }
    return;
  }

  // /history
  if (lower === '/history') {
    if (!history.length) return bot.sendMessage(msg.chat.id, '❌ Belum ada riwayat pengecekan.');
    return bot.sendMessage(msg.chat.id, '👉 Pilih aksi untuk riwayat:', {
      reply_markup: { inline_keyboard: buildHistoryKeyboard() }
    });
  }

  // /start | /help
  if (lower === '/start' || lower === '/help') {
    return bot.sendMessage(msg.chat.id, [
      'Hai! 👋',
      'Perintah:',
      '• /cek NE1 NE2  → cek dua arah (Description mengandung base lawan) + tombol Cek ulang',
      '• /history      → cek ulang / hapus riwayat',
      '• Kirim teks bebas dengan dua NE (mis. hasil diagnosis) → bot akan kasih command /cek + tombol Jalankan'
    ].join('\n'));
  }

  // Teks bebas → auto deteksi 2 NE → saran command /cek + tombol Jalankan
  const candidates = extractNEs(text);
  if (candidates.length >= 2) {
    const [ne1, ne2] = sortNEPair([candidates[0], candidates[1]]);
    const cmd = `/cek ${ne1} ${ne2}`;
    return bot.sendMessage(msg.chat.id, [
      '🔗 Terdeteksi 2 NE dari teks kamu.',
      'Command siap copy‑paste:',
      cmd
    ].join('\n'), {
      reply_markup: {
        inline_keyboard: [[{ text: '🚀 Jalankan sekarang', callback_data: `run_${ne1}__${ne2}` }]]
      }
    });
  }

  // default
  return bot.sendMessage(msg.chat.id, '👍');
});

/* ===================== Callback Buttons ===================== */
bot.on('callback_query', async (q) => {
  const { data, message } = q;
  await bot.answerCallbackQuery(q.id, { show_alert: false }).catch(() => {});
  try {
    // Jalankan sekarang dari saran teks bebas
    if (data.startsWith('run_')) {
      const payload = data.slice(4);
      const [ne1, ne2] = payload.split('__');
      if (!ne1 || !ne2) return bot.sendMessage(message.chat.id, '⚠️ Format NE tidak valid.');
      await bot.sendMessage(message.chat.id, `🔄 Menjalankan: ${ne1} ↔ ${ne2}…`);
      const browser = await launchBrowser();
      try {
        const textOut = await checkMetroStatus(ne1, ne2, { browser, returnStructured: false });
        const end = Date.now();
        await bot.sendMessage(
          message.chat.id,
          `🕛 Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${textOut}`,
          makeRerunButtons(ne1, ne2)
        );
      } finally {
        await browser.close().catch(() => {});
      }
      return;
    }

    // Cek ulang dari hasil /cek
    if (data.startsWith('rerun_')) {
      const payload = data.slice(6);
      const [ne1, ne2] = payload.split('__');
      if (!ne1 || !ne2) return;
      await bot.sendMessage(message.chat.id, `🔄 Cek ulang: ${ne1} ↔ ${ne2}…`);
      const browser = await launchBrowser();
      try {
        const textOut = await checkMetroStatus(ne1, ne2, { browser, returnStructured: false });
        const end = Date.now();
        await bot.sendMessage(
          message.chat.id,
          `🕛 Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${textOut}`,
          makeRerunButtons(ne1, ne2)
        );
      } finally {
        await browser.close().catch(() => {});
      }
      return;
    }

    // Dari menu history
    if (data.startsWith('retry_')) {
      const i = Number(data.split('_')[1]);
      const e = history[i];
      if (!e) return;
      await bot.sendMessage(message.chat.id, `🔄 Cek ulang: ${e.ne1} ↔ ${e.ne2}…`);
      const browser = await launchBrowser();
      try {
        const textOut = await checkMetroStatus(e.ne1, e.ne2, { browser, returnStructured: false });
        const end = Date.now();
        await bot.sendMessage(
          message.chat.id,
          `🕛 Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${textOut}`,
          makeRerunButtons(e.ne1, e.ne2)
        );
      } finally {
        await browser.close().catch(() => {});
      }
      return;
    }

    if (data.startsWith('delete_')) {
      const i = Number(data.split('_')[1]);
      const e = history[i];
      if (!e) return;
      history.splice(i, 1);
      writeHistory();
      await bot.sendMessage(message.chat.id, `✅ Riwayat ${e.shortNe1} ↔ ${e.shortNe2} dihapus.`);
      return;
    }
  } catch (e) {
    await bot.answerCallbackQuery(q.id, { text: '❌ Terjadi kesalahan. Coba lagi.', show_alert: true });
  }
});
