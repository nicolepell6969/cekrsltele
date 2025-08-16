// textToCommand.js — ekstrak NE dari teks bebas (pola langsung + to_ link)
function uniq(arr){ return Array.from(new Set(arr.filter(Boolean))); }
function cleanToken(s){ return String(s||'').toUpperCase().trim(); }

// NE general: SBY-PRMJ(-EN1|OPT)?(-H910D|910D)?
const NE_CORE = /\b[A-Z]{3}-[A-Z0-9]{3,}(?:-(?:EN1|OPT))?(?:-(?:H?910D))?\b/g;

// Link: to_SBY-PRMJ-OPT-H910D_25GE...  /  to-SBY-PRMJ-OPT-H910D:...
const TO_LINK  = /\bto[_-]([A-Z]{3}-[A-Z0-9-]+?)(?=[_: \n\r]|$)/gi;

// Normalisasi kandidat agar tetap ke bentuk NE yang valid (buang buntut port setelah NE)
function normalizeNE(raw){
  if (!raw) return null;
  const up = cleanToken(raw);
  // putus di separator umum setelah NE
  const base = up.split(/[ :|]/)[0];                     // buang setelah spasi/kolon/pipa
  const stop = base.replace(/[_-](GE|XE|25GE|10GE|100GE|GIGABIT|ETH).*/i,''); // buang after port hint
  // terakhir: cocokkan ke NE_CORE lagi untuk memastikan pola
  const m = stop.match(NE_CORE);
  return m ? m[0] : null;
}

function extractNEs(text){
  const t = String(text||'');
  const found = [];

  // 1) dari pola to_
  let m;
  while ((m = TO_LINK.exec(t)) !== null) {
    const norm = normalizeNE(m[1]);
    if (norm) found.push(norm);
  }

  // 2) dari pola langsung NE
  const direct = t.match(NE_CORE) || [];
  direct.forEach(x => {
    const norm = normalizeNE(x);
    if (norm) found.push(norm);
  });

  return uniq(found);
}

function buildCekCommandFromText(text){
  const nes = extractNEs(text);
  if (nes.length >= 2) {
    // ambil 2 NE pertama yang berbeda
    const a = nes[0];
    const b = nes.find(x => x !== a) || null;
    if (b) return { cmd: `/cek ${a} ${b}`, list: nes };
  }
  if (nes.length === 1) {
    const a = nes[0];
    return { cmd: `/cek ${a} <NE-LAWAN>`, list: nes, note: 'Hanya menemukan 1 NE dari teks.' };
  }
  return { cmd: null, list: [], note: 'Tidak menemukan pola NE.' };
}

module.exports = { extractNEs, buildCekCommandFromText, normalizeNE };
