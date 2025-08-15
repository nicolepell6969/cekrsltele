require('dotenv').config();
const TelegramBot = require('node-telegram-bot-api');
const fs = require('fs');
const checkMetroStatus = require('./checkMetroStatus');
const { launchBrowser, _formatSideHTML } = require('./checkMetroStatus');

const token = process.env.TELEGRAM_BOT_TOKEN;
if (!token) { console.error('ENV TELEGRAM_BOT_TOKEN belum diset.'); process.exit(1); }

const bot = new TelegramBot(token, { polling: true });
const historyFilePath = './history.json';
const MAX_HISTORY = 50;

const previewCache = new Map(); // token -> {sideA, sideB, labelA, labelB, chatId, ts}
const CACHE_TTL_MS = 10 * 60 * 1000; // 10 menit

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

function makePreviewHTML(sideRows, labelA, labelB, limit = 5) {
  const rows = (sideRows || []).slice(0, limit);
  if (!rows.length) return `<b>▶️ ${labelA} → ${labelB}</b>\n(i) tidak ada data relevan`;
  const head = `<b>▶️ ${labelA} → ${labelB}</b>`;
  const body = rows.map(r => {
    const iface = r['Interface'] || 'N/A';
    const rx = r['RX Level'] || 'N/A';
    const thr = r['RX Threshold'] || 'N/A';
    const oper = r['Oper Status'] || 'N/A';
    const ip = r['NE IP'] || '';
    const link = ip ? `<a href="http://${ip}">${ip}</a>` : 'N/A';
    const rxNum = Number(rx), thrNum = Number(thr);
    const higherIsBetter = process.env.RX_HIGHER_IS_BETTER !== 'false';
    const emoji = (r['RX Level'] === '-40.00') ? '❌'
      : (Number.isNaN(rxNum) || Number.isNaN(thrNum)) ? '❓'
      : (higherIsBetter ? (rxNum > thrNum) : (rxNum < thrNum)) ? '✅' : '⚠️';
    return `• <b>${iface}</b> | RX <code>${rx}</code> | Thr <code>${thr}</code> | <i>${oper}</i> | ${link} ${emoji}`;
  }).join('\n');
  return `${head}\n${body}`;
}

function buildMoreButtons(tokenKey, labelA, labelB) {
  return {
    reply_markup: {
      inline_keyboard: [
        [{ text: `Tampilkan semua ${labelA}→${labelB}`, callback_data: `more_${tokenKey}_A` }],
        [{ text: `Tampilkan semua ${labelB}→${labelA}`, callback_data: `more_${tokenKey}_B` }]
      ]
    },
    parse_mode: 'HTML',
    disable_web_page_preview: true
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
    await bot.sendMessage(msg.chat.id, '🔄 Mengecek, mohon tunggu…');

    const start = Date.now();
    const browser = await launchBrowser();
    try {
      const { sideA, sideB, labelA, labelB } = await checkMetroStatus(ne1, ne2, { browser, returnStructured: true });
      const end = Date.now();

      const tokenKey = `${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
      previewCache.set(tokenKey, { sideA, sideB, labelA, labelB, chatId: msg.chat.id, ts: Date.now() });

      // bersihkan cache lama
      for (const [k, v] of previewCache.entries()) {
        if (Date.now() - (v.ts || 0) > CACHE_TTL_MS) previewCache.delete(k);
      }

      const previewA = makePreviewHTML(sideA, labelA, labelB, 5);
      const previewB = makePreviewHTML(sideB, labelB, labelA, 5);
      const combinedPreview = `🕛 Checked Time: ${new Date(end).toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\n\n${previewA}\n────────────\n${previewB}`;

      addHistory(ne1, ne2, combinedPreview, name, start, end);
      await bot.sendMessage(msg.chat.id, combinedPreview, buildMoreButtons(tokenKey, labelA, labelB));
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
    return bot.sendMessage(msg.chat.id, '👉 Pilih aksi untuk setiap riwayat:', {
      reply_markup: {
        inline_keyboard: history.map((e, i) => ([
          { text: `Ulangi ${e.shortNe1} ↔ ${e.shortNe2}`, callback_data: `retry_${i}` },
          { text: `Hapus ${e.shortNe1} ↔ ${e.shortNe2}`, callback_data: `delete_${i}` }
        ]))
      }
    });
  }

  if (lower === '/start' || lower === '/help') {
    return bot.sendMessage(msg.chat.id, [
      'Hai! 👋',
      'Perintah:',
      '• /cek NE1 NE2  → cek dua arah (preview 5 baris/sisi + tombol tampilkan semua)',
      '• /history      → lihat & kelola riwayat'
    ].join('\n'));
  }

  return bot.sendMessage(msg.chat.id, '👍');
});

bot.on('callback_query', async (q) => {
  const { data, message } = q;
  await bot.answerCallbackQuery(q.id, { show_alert: false }).catch(() => {});
  try {
    if (data.startsWith('more_')) {
      const [, tokenKey, sideFlag] = data.split('_'); // more_<token>_A|B
      const entry = previewCache.get(tokenKey);
      if (!entry) return bot.sendMessage(message.chat.id, '⚠️ Data sudah kadaluarsa. Jalankan /cek lagi.');

      const { sideA, sideB, labelA, labelB } = entry;
      const html = sideFlag === 'A'
        ? _formatSideHTML(sideA, labelA, labelB)
        : _formatSideHTML(sideB, labelB, labelA);

      return bot.sendMessage(message.chat.id, html, { parse_mode: 'HTML', disable_web_page_preview: true });
    }
  } catch (e) {
    await bot.answerCallbackQuery(q.id, { text: '❌ Terjadi kesalahan. Coba lagi.', show_alert: true });
  }
});
