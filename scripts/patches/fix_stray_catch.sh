#!/usr/bin/env bash
set -euo pipefail

echo "==> Backup bot.js"
cp -f bot.js bot.js.bak_straycatch_$(date +%Y%m%d-%H%M%S)

echo "==> Comment blok stray '} catch(e) {' sampai penutup '}'"
awk 'BEGIN{inbad=0; depth=0}
{
  if (!inbad) {
    if ($0 ~ /^[[:space:]]*\}[[:space:]]*catch[[:space:]]*\(/) {
      print "// [FIX] removed stray catch: " $0;
      inbad=1; depth=0; next
    } else { print; next }
  } else {
    line=$0
    print "// [FIX] stray-catch body: " line
    oc=gsub(/\{/,"{",line)
    cc=gsub(/\}/,"}",line)
    depth += (oc-cc)
    if (depth<=-1 || line ~ /^[[:space:]]*}\s*$/) { inbad=0 }
  }
}' bot.js > bot.js.tmp && mv bot.js.tmp bot.js

echo "==> Cek sintaks bot.js"
if node -e 'const fs=require("fs");try{new Function(fs.readFileSync("bot.js","utf8"))}catch(e){console.error(e.stack);process.exit(1)}' >/dev/null 2>syntax.err; then
  echo "✅ Syntax OK — restart service"
  systemctl restart cekrsltele
  sleep 1
  journalctl -u cekrsltele -n 40 -l --no-pager
else
  echo "❌ Syntax masih error. Stacktrace:"
  cat syntax.err
  echo "==> Potongan file sekitar awal untuk inspeksi:"
  nl -ba bot.js | sed -n '1,200p'
fi
