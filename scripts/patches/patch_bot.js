const fs = require('fs');
const f = 'bot.js';
let s = fs.readFileSync(f,'utf8');

/* --- A) FIX "dummy regex" di attachSafeSender() --- */
const fallback = 'part = rest.slice(0, Math.min(max, rest.length));\n        rest = rest.slice(part.length);';
// ganti pola literal "(?![sS]);" versi yang ada di file kamu
s = s.replace(/\(\?\!\[sS\]\)\/\);[^\n]*\n/g, `${fallback}\n`);

/* --- B) Auto-refresh /history pada tombol delete_ --- */
const delBlockRe = /if\s*\(\s*data\.startsWith\('delete_'\)\s*\)\s*\{[\s\S]*?\n\s*\}/m;
const newDelBlock = `
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
`.trim();

if (delBlockRe.test(s)) {
  s = s.replace(delBlockRe, newDelBlock);
} // kalau pola tak ketemu, biarkan apa adanya (tidak merusak)

/* --- Tulis balik --- */
fs.writeFileSync(f, s);
console.log('✅ bot.js patched.');
