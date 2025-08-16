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

// ====== cache untuk tombol "Cek ulang" ======
const retryCache = new Map(); // key -> { ne1, ne2, ts }
const RETRY_TTL_MS = 10 * 60 * 1000; // 10 menit

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

function cleanupRetryCache() {
  const now = Date.now();
  for (const [k, v] of retryCache.entries()) {
    if (now - (v.ts || 0) > RETRY_TTL_MS) retryCache.delete(k);
  }
}

function buildRetryButtons(tokenKey) {
  return {
    reply_markup: {
      inline_keyboard: [
        [{ text: '🔄 Cek ulang', callback_data: `rerun_${tokenKey}` }]
      ]
    }
  };
}

bot.on('message', async (msg) => {
  if (!msg.text) return;
  const text = msg.text.trim();
  const lower = text.toLowerCase();

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

      // simpan pair NE untuk tombol "Cek ulang"
      cleanupRetryCache();
      const tokenKey = `${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
      retryCache.set(tokenKey, { ne1, ne2, ts: Date.now() });

      await bot.sendMessage(
        msg.chat.id,
        `🕛 Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${textOut}`,
        buildRetryButtons(tokenKey)
      );
    } catch (e) {
      console.error(e);
      await bot.sendMessage(msg.chat.id, `❌ Gagal melakukan pengecekan: ${e.message || e}`);
    } finally {
      await browser.close().catch(() => {});
    }
    return;
  }

  if (lower === '/history') {
    if (!history.length) return bot.sendMessage(msg.chat.id, '❌ Belum ada riwayat pengecekan.');
    return bot.sendMessage(msg.chat.id, '👉 Pilih aksi untuk riwayat:', {
      reply_markup: {
        inline_keyboard: history.map((e, i) => ([
          { text: `🔄 Cek ulang ${e.shortNe1} ↔ ${e.shortNe2}`, callback_data: `retry_${i}` },
          { text: `🗑️ Hapus ${e.shortNe1} ↔ ${e.shortNe2}`, callback_data: `delete_${i}` }
        ]))
      }
    });
  }

  if (lower === '/start' || lower === '/help') {
    return bot.sendMessage(msg.chat.id, [
      'Hai! 👋',
      'Perintah:',
      '• /cek NE1 NE2  → cek dua arah (filter Description = base lawan) + tombol Cek ulang',
      '• /history      → cek ulang / hapus riwayat'
    ].join('\n'));
  }

  return bot.sendMessage(msg.chat.id, '👍');
});

bot.on('callback_query', async (q) => {
  const { data, message } = q;
  await bot.answerCallbackQuery(q.id, { show_alert: false }).catch(() => {});
  try {
    // Tombol "Cek ulang" yang ada di bawah hasil /cek
    if (data.startsWith('rerun_')) {
      const tokenKey = data.slice('rerun_'.length);
      const entry = retryCache.get(tokenKey);
      if (!entry) return bot.sendMessage(message.chat.id, '⚠️ Data tombol sudah kedaluwarsa. Jalankan /cek lagi.');

      const { ne1, ne2 } = entry;
      await bot.sendMessage(message.chat.id, `🔄 Cek ulang: ${ne1} ↔ ${ne2}…`);
      const browser = await launchBrowser();
      try {
        const textOut = await checkMetroStatus(ne1, ne2, { browser, returnStructured: false });
        const end = Date.now();

        // buat token baru untuk tombol berikutnya
        cleanupRetryCache();
        const newToken = `${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
        retryCache.set(newToken, { ne1, ne2, ts: Date.now() });

        await bot.sendMessage(
          message.chat.id,
          `🕛 Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${textOut}`,
          buildRetryButtons(newToken)
        );
      } finally {
        await browser.close().catch(() => {});
      }
      return;
    }

    // Tombol dari menu /history
    if (data.startsWith('retry_')) {
      const i = Number(data.split('_')[1]);
      const e = history[i];
      if (!e) return;
      await bot.sendMessage(message.chat.id, `🔄 Cek ulang: ${e.ne1} ↔ ${e.ne2}…`);
      const browser = await launchBrowser();
      try {
        const textOut = await checkMetroStatus(e.ne1, e.ne2, { browser, returnStructured: false });
        const end = Date.now();
        // siapkan tombol "cek ulang" langsung di hasil ini juga
        cleanupRetryCache();
        const tokenKey = `${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
        retryCache.set(tokenKey, { ne1: e.ne1, ne2: e.ne2, ts: Date.now() });

        await bot.sendMessage(
          message.chat.id,
          `🕛 Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${textOut}`,
          buildRetryButtons(tokenKey)
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
