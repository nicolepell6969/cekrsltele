const fs = require('fs');

const file = 'bot.js';
let s = fs.readFileSync(file, 'utf8');
let orig = s;

// ---------- REPLACE BLOK R1/R2 -> SINGLE COMBINED (umum) ----------
// Pola: deklarasi r1 dan r2 lalu bikin combined dari r1 + r2
// Ganti jadi: timeout + single call -> combined, lalu end = Date.now()
s = s.replace(
  /const\s+r1\s*=\s*await\s+runWithTimeout\(\s*checkMetroStatus\(([^)]*)\)\s*,\s*Number\([^)]*\)\s*\);\s*const\s+r2\s*=\s*await\s+runWithTimeout\(\s*checkMetroStatus\(([^)]*)\)\s*,\s*Number\([^)]*\)\s*\);\s*const\s+end\s*=\s*Date\.now\(\);\s*const\s+combined\s*=\s*[\s\S]*?;\s*/g,
  (m, a1/*, a2*/) => {
    return [
      `const timeout = Number(process.env.CEK_TIMEOUT_MS || 180000);`,
      `const combined = await runWithTimeout(checkMetroStatus(${a1}), timeout);`,
      `const end = Date.now();`
    ].join('\n') + '\n';
  }
);

// Pola: deklarasi r1 dan r2, lalu NANTI ada end = Date.now() dan kirim ${r1} ... ${r2}
// Ganti r1/r2 → combined (tanpa menyentuh bagian kirim)
s = s.replace(
  /const\s+r1\s*=\s*await\s+runWithTimeout\(\s*checkMetroStatus\(([^)]*)\)\s*,\s*Number\([^)]*\)\s*\);\s*const\s+r2\s*=\s*await\s+runWithTimeout\(\s*checkMetroStatus\(([^)]*)\)\s*,\s*Number\([^)]*\)\s*\);\s*/g,
  (m, a1/*, a2*/) => {
    return [
      `const timeout = Number(process.env.CEK_TIMEOUT_MS || 180000);`,
      `const combined = await runWithTimeout(checkMetroStatus(${a1}), timeout);`
    ].join('\n') + '\n';
  }
);

// ---------- Ganti penyisipan ${r1}....${r2} jadi ${combined} ----------
s = s.replace(/\$\{r1\}[\s\S]*?\$\{r2\}/g, '${combined}');

// ---------- Sedikit rapikan teks notifikasi awal (opsional aman) ----------
s = s.replace(/ONCEK, DITUNGGU/i, 'Checking');

// Tulis kembali bila ada perubahan
if (s !== orig) {
  fs.writeFileSync(file, s);
  console.log('✅ bot.js di-patch untuk hapus duplikasi 2 sisi.');
} else {
  console.log('ℹ️ Tidak ada perubahan yang diterapkan (mungkin sudah terpatch).');
}
