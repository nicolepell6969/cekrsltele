const fs = require('fs');
const f = 'bot.js';
let s = fs.readFileSync(f, 'utf8');

// 1) GANTI baris regex rusak "(?![sS])/);" menjadi fallback aman
//    Contoh baris nyasar: (?![sS])/); // dummy regex ...
s = s.replace(/^[ \t]*\(\?\!\[sS\]\)\/\);.*$/gm, "        part = ''; // patched: force fallback");

// 2) Jika masih ada sisa "part = takeUntil(/" yang terpotong, bersihkan ke fallback
s = s.replace(/^[ \t]*\/\/.*part\s*=\s*takeUntil\(\s*\/.*$/gm, "        part = ''; // patched: stripped takeUntil");

// 3) Komentari baris teks polos berbahasa Indo yang pernah nyasar tanpa //
const INDOS = [
  /(^|\s)atau spasi(\s|$)/i,
  /(^|\s)coba pecah di(\s|$)/i,
  /(^|\s)strategi:\s*ambil blok demi blok/i,
  /(^|\s)1\)\s*coba(\s|$)/i
];
s = s.split('\n').map(line => {
  const trimmed = line.trim();
  if (trimmed.startsWith('//')) return line;
  return INDOS.some(re => re.test(line)) ? line.replace(/^(\s*)/, '$1// ') : line;
}).join('\n');

// 4) (Opsional) Jika ada duplikat patch “attachSafeSender” yang menambah risiko,
//    kita BIARKAN (tidak dihapus) agar tidak mengubah fitur. Yang penting sintaks valid.

// Tulis balik
fs.writeFileSync(f, s);
console.log('✅ bot.js dibersihkan dari regex/teks nyasar.');
