#!/usr/bin/env bash
set -euo pipefail

# ======= Konfigurasi =======
GIT_NAME="${GIT_NAME:-nicolepell6969}"
GIT_EMAIL="${GIT_EMAIL:-ferenrezareynaldo5@gmail.com}"
REMOTE_NAME="${REMOTE_NAME:-origin}"
BRANCH_NAME="${BRANCH_NAME:-main}"

# Set true kalau mau rewrite history (butuh git-filter-repo, akan push --force)
CLEAN_HISTORY="${CLEAN_HISTORY:-true}"

# Pola file/folder lokal yang tidak ingin dipublish
LOCAL_SCRIPTS=(
  "command.sh"
  "update_and_push.sh"
  "auto_replace_and_push.sh"
  "auto_update_and_push.sh"
)
LOCAL_DIRS_IGNORE=(
  ".dev-scripts/"
)

# ======= Backup repo (aman) =======
echo "==> Backup repo ke ../cekrsltele-backup-$(date +%Y%m%d-%H%M%S)"
cd "$(git rev-parse --show-toplevel)"
cd ..
cp -r cekrsltele "cekrsltele-backup-$(date +%Y%m%d-%H%M%S)" || true
cd cekrsltele

# ======= Tulis/merge .gitignore =======
echo "==> Update .gitignore"
cat > .gitignore <<'EOF'
# --- Dependencies & caches
node_modules/
.pnpm-store/
.npm/
.yarn/
dist/
build/
coverage/
tmp/
temp/
.cache/
*.cache

# --- Puppeteer / Chromium caches & downloads
.chromium/
.chromedriver*
chrome-profile*/
**/chrome-linux*/
**/chrome-win*/
**/chrome-mac*/
**/.local-chromium/
**/.cache/puppeteer/

# --- OS / editor junk
.DS_Store
Thumbs.db
.idea/
.vscode/
*.swp
*.swo

# --- Logs & runtime artifacts
*.log
npm-debug.log*
yarn-error.log*
pnpm-debug.log*
*.pid
*.pid.lock
history.json

# --- Env & credentials
.env
.env.local
.env.*.local

# --- Local helper scripts (jangan publish)
command.sh
update_and_push.sh
auto_replace_and_push.sh
auto_update_and_push.sh
.dev-scripts/

# --- Backups / temp
*.bak
*.bak_*
*.tmp
*.broken*
.backup-*/
EOF

# ======= Untrack file/dir yang seharusnya di-ignore (tanpa hapus dari disk) =======
echo "==> Untrack file/dir tak penting dari index (tanpa hapus lokal)"
set +e
git rm -r --cached node_modules 2>/dev/null
git rm    --cached history.json 2>/dev/null
git rm -r --cached .cache 2>/dev/null
git rm -r --cached .chromium 2>/dev/null
git rm -r --cached **/.cache/puppeteer 2>/dev/null
git rm    --cached .DS_Store 2>/dev/null
git rm    --cached Thumbs.db 2>/dev/null
for f in "${LOCAL_SCRIPTS[@]}"; do git rm --cached "$f" 2>/dev/null; done
for d in "${LOCAL_DIRS_IGNORE[@]}"; do git rm -r --cached "$d" 2>/dev/null; done
# pola backup/temp umum
git ls-files -z "*.bak" "*.bak_*" "*.tmp" "*.broken*" 2>/dev/null | xargs -0r git rm --cached
set -e

# ======= Commit & push perubahan .gitignore + untrack =======
echo "==> Commit .gitignore & untrack"
git -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" add .gitignore || true
# add semua perubahan index (untrack tidak perlu di-add lagi)
git -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" commit -m "chore: clean repo (.gitignore + untrack runtime/deps/scripts lokal)" || echo "No changes to commit."

git push "$REMOTE_NAME" "$BRANCH_NAME" || echo "Push skip / nothing to push."

# ======= (Opsional) Clean history dengan git-filter-repo =======
if [ "$CLEAN_HISTORY" = "true" ]; then
  echo "==> CLEAN_HISTORY=true -> rewrite history dengan git-filter-repo --force"
  if command -v git-filter-repo >/dev/null 2>&1; then
    # rapikan objek dulu (mengurangi komplain)
    git gc --prune=now --aggressive || true

    # siapkan argumen path untuk semua pola
    FILTER_ARGS=()
    for f in "${LOCAL_SCRIPTS[@]}"; do FILTER_ARGS+=( --path "$f" ); done
    FILTER_ARGS+=( --path history.json )
    FILTER_ARGS+=( --path node_modules )
    FILTER_ARGS+=( --path .cache )
    FILTER_ARGS+=( --path .chromium )
    FILTER_ARGS+=( --path ".dev-scripts" )

    # jalankan filter-repo
    git filter-repo --force "${FILTER_ARGS[@]}" --invert-paths

    # force push (ingat: semua clone lama perlu re-clone/reset)
    git push "$REMOTE_NAME" --force --tags
    echo "==> Selesai rewrite history & push --force."
  else
    echo "❌ git-filter-repo tidak ditemukan. Install dulu (mis. 'sudo apt-get install git-filter-repo' atau 'pip install git-filter-repo'), lalu jalankan ulang dengan CLEAN_HISTORY=true."
  fi
else
  echo "==> CLEAN_HISTORY=false -> skip rewrite history (aman)."
fi

echo "✅ Beres! Repo sudah bersih & .gitignore terpasang."
