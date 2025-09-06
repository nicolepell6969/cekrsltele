#!/usr/bin/env bash
set -euo pipefail
F="checkMetroStatus.js"

# Backup dulu
cp -f "$F" "$F.bak_singleNE_$(date +%Y%m%d-%H%M%S)"

# Ganti isi fungsi tryFetchAllForSingle: fokus ke 'Metro-e Status Check' + filter
perl -0777 -pe '
s|async function tryFetchAllForSingle\([^\)]*\)\s*\{[\s\S]*?\n\}|
async function tryFetchAllForSingle(page, neName) {
  // Fokus hanya pada "Metro-e Status Check" agar hasil relevan untuk 1 NE
  const rows = await fetchTable(page, neName, "Metro-e Status Check");

  const norm = s => String(s || "").toUpperCase();
  const target = norm(neName);

  // Ambil baris yang benar-benar milik NE tsb & punya interface (buang VLAN/service list)
  return rows.filter(r =>
    norm(r["NE Name"]).includes(target) &&
    String(r["Interface"] || "").trim() !== ""
  );
}
|s' -i "$F"

# Cek sintaks cepat
node -e "new Function(require('fs').readFileSync('$F','utf8'))" >/dev/null \
  && echo "✅ Patch OK" || { echo "❌ Syntax error"; exit 1; }
