#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="${HOME}/cekrsltele"
BRANCH="main"
GIT_NAME="nicolepell6969"
GIT_EMAIL="ferenrezareynaldo5@gmail.com"
SERVICE="cekrsltele"

cd "$REPO_DIR"
git fetch origin || true
git checkout -B "$BRANCH"
git pull --rebase origin "$BRANCH" || true

TS="$(date +%Y%m%d-%H%M%S)"
[ -f checkMetroStatus.js ] && cp -f checkMetroStatus.js "checkMetroStatus.js.bak_${TS}" || true
[ -f bot.js ] && cp -f bot.js "bot.js.bak_${TS}" || true

# --------- PATCH checkMetroStatus.js ----------
awk '
BEGIN{patched=0}
# Ganti default konstanta
/const PAGE_TIMEOUT =/ {print "const PAGE_TIMEOUT = Number(process.env.PAGE_TIMEOUT_MS || 15000);"; next}
 /const MAX_CANDIDATES =/ {print "const MAX_CANDIDATES = Number(process.env.MAX_CANDIDATES || 4);"; next}
# Tambah singleton browser + getBrowser()
/module\.exports = checkMetroStatus;/ {hold=$0; next}
{print}
END{
  print "";
}
' checkMetroStatus.js > checkMetroStatus.js.tmp

# Sisipkan helper singleton & progress hook
cat >> checkMetroStatus.js.tmp <<'EOF'

// ====== Singleton browser ======
let _sharedBrowser = null;
async function getBrowser() {
  try {
    if (_sharedBrowser && _sharedBrowser.process() && !_sharedBrowser.process().killed) {
      return _sharedBrowser;
    }
  } catch {}
  _sharedBrowser = await launchBrowser();
  return _sharedBrowser;
}

// Optional: pemanggil dapat kirim progress(text) untuk info ke user
function notifyProgress(options, text){
  try {
    if (options && typeof options.progress === 'function') options.progress(text);
  } catch {}
}

// Override genCandidates: urutkan yang paling prospektif dulu
function genCandidates(ne){
  const NE = U.up(ne);
  const parts = NE.split('-');
  const citySite = U.citySite(NE);
  const third = parts[2] || '';
  const swapMode = s => s.replace(/-EN1-/g,'-OPT-').replace(/-OPT-/g,'-EN1-');
  const swapH = s => s.replace(/H910D/g,'910D').replace(/-910D\b/g,'-H910D');

  const arr = [
    NE,
    `${citySite}-EN1-H910D`,
    `${citySite}-OPT-H910D`,
    `${citySite}`,
    swapMode(NE), swapH(NE), swapH(swapMode(NE)),
    `${citySite}-${third||'EN1'}`, `${citySite}-${third||'OPT'}`,
    `${citySite}-EN1-910D`, `${citySite}-OPT-910D`
  ];
  return U.uniq(arr).slice(0, MAX_CANDIDATES);
}

// Ubah checkMetroStatus & checkSingleNE supaya pakai getBrowser() & ada progress
EOF

# Ganti fungsi export utama agar gunakan getBrowser() & progress
awk '
/async function checkMetroStatus\(ne1, ne2, options=\{\}\)\{/{
  print $0;
  print "  const browser = options.browser || await getBrowser();";
  print "  const ownBrowser = false; // kita pakai singleton";
  print "  const fA = await createFetcher(browser);";
  print "  const fB = await createFetcher(browser);";
  print "  const logs = [];";
  print "  try{";
  print "    const A = U.up(ne1), B = U.up(ne2);";
  print "    const baseA = U.citySite(A), baseB = U.citySite(B);";
  print "    notifyProgress(options, `🔎 Mencoba varian NE: ${A} vs ${B}…`);";
  print "    const [resA, resB] = await Promise.all([";
  print "      trySide(fA, A, baseB, B, logs),";
  print "      trySide(fB, B, baseA, A, logs),";
  print "    ]);";
  print "    const text = [...logs,";
  print "      fmtSide(resA.rows, U.citySite(resA.used), baseB),";
  print "      '────────────',";
  print "      fmtSide(resB.rows, U.citySite(resB.used), baseA)";
  print "    ].join('\\n');";
  print "    if (options.returnStructured){";
  print "      return { logs, sideA: resA.rows, usedA: resA.used, svcA: resA.svc, sideB: resB.rows, usedB: resB.used, svcB: resB.svc };";
  print "    }";
  print "    return text;";
  print "  } catch(e){";
  print "    return `❌ Gagal memeriksa\\nError: ${e.message}`;";
  print "  } finally { try{ await fA.close(); }catch{} try{ await fB.close(); }catch{} }";
  print "  return \"\";";
  skip=1; next
}
skip==1 && /finally/ {next}
{print}
' checkMetroStatus.js.tmp > checkMetroStatus.js

# --------- PATCH bot.js (naikkan overall timeout & kirim progress) ----------
OVERALL='const OVERALL = Number(process.env.OVERALL_TIMEOUT_MS || 150000);'
awk -v O="$OVERALL" '
/function withTimeout\(promise, ms\)\{/ {seen=1}
BEGIN{added=0}
{print}
END{
  if (!added) {}
}
' bot.js > /dev/null

# Sisipkan konstanta OVERALL + kirim progress
awk -v O="$OVERALL" '
BEGIN{done=0}
# Tambah OVERALL di atas helper timeout
/\/\* ===== helper timeout ===== \*\//{
  print O; print; next
}
# Pada runcek_ gunakan options.progress untuk update
/const out = await withTimeout\(checkMetroStatus\(ne1, ne2, \{ mode:\x27normal\x27 \}\), 90_000\);/{
  print "      const out = await withTimeout(checkMetroStatus(ne1, ne2, {";
  print "        mode: \"normal\",";
  print "        progress: async (t)=>{ try{ await safeSend(chatId, t); }catch{} }";
  print "      }), OVERALL);";
  next
}
# Pada runcek1_ juga naikkan timeout
/const out   = await withTimeout\(checkMetroStatus\.checkSingleNE\(ne\), 90_000\);/{
  print "      const out   = await withTimeout(checkMetroStatus.checkSingleNE(ne), OVERALL);";
  next
}
# Ubah nilai 90_000 lain kalau ada
/\(ne\), 90_000\)/{ gsub(/90_000/, "OVERALL"); print; next }
{print}
' bot.js > bot.js.new && mv bot.js.new bot.js

npm install

git -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" add bot.js checkMetroStatus.js
git -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" commit -m "perf: singleton browser, kandidat dipersempit & diurutkan; timeout total via OVERALL_TIMEOUT_MS; progress message"
git push -u origin "$BRANCH"

# Set environment yang direkomendasikan
sudo mkdir -p /etc/systemd/system/${SERVICE}.service.d
sudo tee /etc/systemd/system/${SERVICE}.service.d/override-timeout.conf >/dev/null <<'UNIT'
[Service]
Environment=PAGE_TIMEOUT_MS=15000
Environment=MAX_CANDIDATES=4
Environment=MAX_LINES_PER_SIDE=40
Environment=OVERALL_TIMEOUT_MS=150000
UNIT

sudo systemctl daemon-reload
sudo systemctl restart ${SERVICE}
systemctl status ${SERVICE} --no-pager -l | sed -n '1,16p'
