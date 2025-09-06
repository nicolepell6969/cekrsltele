const fs = require('fs');
const path = require('path');
const FILE = path.join(__dirname, 'bot.js');

let s = fs.readFileSync(FILE, 'utf8');

const NEW_HELP_BLOCK = `
  // ===== /help =====
  if (low === '/help') {
    const help = [
      '📋 Perintah Utama',
      '/help — daftar perintah',
      '/cek <NE1> [NE2] — cek Metro-e (RX Level only)',
      '/history — riwayat cek (bisa cek ulang / hapus)',
      '',
      '🛠 Admin',
      '/add_admin <id>',
      '/remove_admin <id>',
      '/admin — list admin terdaftar',
      '',
      '📲 WhatsApp',
      '/wa_status',
      '/wa_enable',
      '/wa_disable',
      '/wa_pair — kirim QR ke sini'
    ].join('\\n');
    return bot.sendMessage(chatId, help);
  }
`.trim();

const re = /\/\/\s*=====?\s*\/help\s*=====?\s*\n[\s\S]*?\n\s*}\s*\n/;

if (re.test(s)) {
  // Ganti blok /help lama (yang ditandai “// ===== /help =====”)
  s = s.replace(re, NEW_HELP_BLOCK + '\n\n');
} else {
  // Jika tidak ditemukan marker, sisipkan tepat sebelum blok /history
  const hook = /\/\/\s*=====?\s*\/history\s*=====?\s*\n/;
  if (hook.test(s)) {
    s = s.replace(hook, NEW_HELP_BLOCK + '\n\n$&');
  } else {
    // Jika /history juga tidak ada, append di akhir handler pesan (fallback aman)
    s += '\n\n' + NEW_HELP_BLOCK + '\n';
  }
}

fs.writeFileSync(FILE, s);
console.log('✔️  /help sudah diperbarui.');
