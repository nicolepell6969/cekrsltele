const fs = require('fs');
const f = 'bot.js';
let s = fs.readFileSync(f, 'utf8');

// Komentari baris yang berisi frasa hotfix yang nyasar tanpa // di depan
const commentThese = [
  /(^|\s)atau spasi(\s|$)/i,
  /(^|\s)coba pecah di(\s|$)/i,
  /(^|\s)strategi:\s*ambil blok demi blok/i,
  /(^|\s)1\)\s*coba(\s|$)/i
];

s = s.split('\n').map(line => {
  const trimmed = line.trim();
  if (trimmed.startsWith('//')) return line; // sudah komentar
  if (commentThese.some(re => re.test(line))) {
    return line.replace(/^(\s*)/, '$1// ');
  }
  return line;
}).join('\n');

fs.writeFileSync(f, s);
console.log('✅ Teks polos yang nyasar sudah dikomentari.');
