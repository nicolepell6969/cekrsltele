#!/usr/bin/env bash
set -euo pipefail

# ====== KONFIG ======
GIT_NAME="${GIT_NAME:-nicolepell6969}"
GIT_EMAIL="${GIT_EMAIL:-ferenrezareynaldo5@gmail.com}"
REMOTE="${REMOTE:-origin}"
BRANCH="${BRANCH:-main}"
# Set ini kalau origin belum ada:
GIT_REMOTE_URL="${GIT_REMOTE_URL:-git@github.com:nicolepell6969/cekrsltele.git}"

PATTERNS=(
  ".backup-*"
  "*.bak"
  "*.bak_*"
  "*.bak.*"
  "*.tmp"
  "*.broken*"
)

echo "==> Preflight…"
git rev-parse --is-inside-work-tree >/dev/null

# ====== BACKUP ======
TOP="$(git rev-parse --show-toplevel)"
cd "$TOP/.."
BACKUP_DIR="cekrsltele-backup-$(date +%Y%m%d-%H%M%S)"
echo "==> Backup ke: $BACKUP_DIR"
cp -r cekrsltele "$BACKUP_DIR"
cd cekrsltele

# ====== .gitignore ======
echo "==> Tulis .gitignore"
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
clean_backup_history.sh
clean_backup_history_v2.sh
EOF

git -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" add .gitignore
git -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" commit -m "chore: add .gitignore (backup & temp patterns)" || true

# ====== Pastikan origin ada ======
if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  echo "==> Set remote $REMOTE -> $GIT_REMOTE_URL"
  git remote add "$REMOTE" "$GIT_REMOTE_URL"
fi

# ====== git-filter-repo ======
if ! command -v git-filter-repo >/dev/null 2>&1; then
  echo "==> Install git-filter-repo …"
  if command -v pip3 >/dev/null 2>&1; then
    pip3 install --user git-filter-repo
    export PATH="$HOME/.local/bin:$PATH"
  else
    pip install --user git-filter-repo
    export PATH="$HOME/.local/bin:$PATH"
  fi
fi

git gc --prune=now --aggressive || true

ARGS=(--force)
for p in "${PATTERNS[@]}"; do ARGS+=( --path-glob "$p" ); done
ARGS+=( --invert-paths )

echo "==> Run: git filter-repo ${ARGS[*]}"
git filter-repo "${ARGS[@]}"

echo "==> Push --force ke $REMOTE/$BRANCH"
git push "$REMOTE" --force --tags

echo "✅ Selesai. History sudah bersih dari .backup-* dan *.bak* (*.tmp, *.broken*)."
echo "ℹ️ Client lama perlu re-clone / reset ke history baru."
