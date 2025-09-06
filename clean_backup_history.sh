#!/usr/bin/env bash
set -euo pipefail

# ====== KONFIG ======
GIT_NAME="${GIT_NAME:-nicolepell6969}"
GIT_EMAIL="${GIT_EMAIL:-ferenrezareynaldo5@gmail.com}"
REMOTE="${REMOTE:-origin}"
BRANCH="${BRANCH:-main}"

# Pola yang ingin dibersihkan dari repo + history
PATTERNS=(
  ".backup-*"
  "*.bak"
  "*.bak_*"
  "*.bak.*"
  "*.tmp"
  "*.broken*"
)

echo "==> Preflight checks…"
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "❌ Bukan di dalam repo git"; exit 1
fi

# ====== BACKUP REPO (AMAN) ======
TOP="$(git rev-parse --show-toplevel)"
cd "$TOP/.."
BACKUP_DIR="cekrsltele-backup-$(date +%Y%m%d-%H%M%S)"
echo "==> Backup repo ke: $BACKUP_DIR"
cp -r cekrsltele "$BACKUP_DIR"
cd cekrsltele

# ====== TULIS .gitignore ======
echo "==> Update .gitignore"
cat > .gitignore <<'EOF'
# backup folders
.backup-*/

# temp/backup files
*.bak
*.bak_*
*.bak.*
*.tmp
*.broken*

# node & puppeteer umum
node_modules/
.cache/
**/.cache/puppeteer/
dist/
build/
*.log
history.json

# local helper scripts (jangan publish)
command.sh
update_and_push.sh
auto_replace_and_push.sh
auto_update_and_push.sh
EOF

git -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" add .gitignore || true
git -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" commit -m "chore: add .gitignore (backup & temp patterns)" || true
git push "$REMOTE" "$BRANCH" || true

# ====== INSTALL git-filter-repo JIKA BELUM ADA ======
if ! command -v git-filter-repo >/dev/null 2>&1; then
  echo "==> Menginstal git-filter-repo (via pip) …"
  if command -v pip3 >/dev/null 2>&1; then
    pip3 install --user git-filter-repo
    export PATH="$HOME/.local/bin:$PATH"
  elif command -v pip >/dev/null 2>&1; then
    pip install --user git-filter-repo
    export PATH="$HOME/.local/bin:$PATH"
  else
    echo "❌ pip tidak ditemukan. Install dulu: apt-get install python3-pip"
    exit 1
  fi
fi

# ====== GC untuk merapikan objek sebelum rewrite ======
git gc --prune=now --aggressive || true

# ====== BANGUN ARGS FILTER ======
ARGS=(--force)
for p in "${PATTERNS[@]}"; do
  ARGS+=( --path-glob "$p" )
done
ARGS+=( --invert-paths )

echo "==> Menjalankan: git filter-repo ${ARGS[*]}"
git filter-repo "${ARGS[@]}"

# ====== PUSH FORCE (history berubah) ======
echo "==> Push --force ke $REMOTE/$BRANCH"
git push "$REMOTE" --force --tags

echo "✅ Selesai. Semua .backup-* dan *.bak* (juga *.tmp, *.broken*) dibersihkan dari history."
echo "ℹ️ Catatan: clone lama perlu re-clone / reset ke history baru."
