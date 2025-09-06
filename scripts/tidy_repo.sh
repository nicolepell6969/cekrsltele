#!/usr/bin/env bash
set -euo pipefail

# Colors
ok(){ echo -e "\033[32m$*\033[0m"; }
warn(){ echo -e "\033[33m$*\033[0m"; }
err(){ echo -e "\033[31m$*\033[0m"; }

# Ensure run at repo root
[ -d .git ] || { err "Run inside the git repo root."; exit 1; }

# Create folders
mkdir -p scripts/patches scripts/ops .githooks .github/workflows

# Move patch/fix shell scripts into scripts/
shopt -s nullglob
for f in *.sh; do
  case "$f" in
    patch_*|fix_*|*rescue*|*doctor*|*rebuild*|*enable_whatsapp*|*clean_repo*)
      git mv -k "$f" "scripts/patches/" 2>/dev/null || mv "$f" "scripts/patches/"
      ;;
    sanitize_env_and_restart.sh|update_command_guard.sh|replace_bot_fix1ne.sh|rescue_clean_bot.sh|rescue_bot.sh|clean_repo.sh)
      git mv -k "$f" "scripts/ops/" 2>/dev/null || mv "$f" "scripts/ops/"
      ;;
  esac
done

# Optional: move helper js patches
for f in patch_*.js fix_*_lines.js patch_bot.js patch_help.js .patch_dedup_two_sides.js; do
  [ -e "$f" ] || continue
  git mv -k "$f" scripts/patches/ 2>/dev/null || mv "$f" scripts/patches/
done

# Ensure .gitignore
cat > .gitignore <<'IGN'
# runtime & deps
node_modules/
npm-debug.log*
yarn-error.log*
pnpm-debug.log*
package-lock.json

# env & secrets
.env
.env.*
!.env.example
wa_auth/
*.pem
*.key

# logs & dumps
*.log
*.err
logs/
tmp/
dist/
coverage/

# editor/OS
.DS_Store
Thumbs.db
.idea/
.vscode/
IGN
ok "Wrote .gitignore"

# Install pre-commit hook using custom hooksPath
git config core.hooksPath .githooks
cat > .githooks/pre-commit <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
if git diff --cached --name-only | grep -E '(^|/)\.env$' >/dev/null 2>&1; then
  echo "❌ Blocked: .env is staged. Unstage it:  git restore --staged .env"
  exit 1
fi
echo "✅ pre-commit checks passed."
HOOK
chmod +x .githooks/pre-commit
ok "Installed pre-commit hook"

# Protect-secrets action
mkdir -p .github/workflows
cat > .github/workflows/protect-secrets.yml <<'YML'
name: Protect secrets
on: [push, pull_request]
jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Fail if .env exists
        run: |
          if [ -f ".env" ] || git ls-files | grep -E '(^|/)\.env$'; then
            echo "::error::.env found in repository. Remove it before pushing."
            exit 1
          fi
          echo "OK: no .env tracked."
YML
ok "Added GitHub workflow"

# Ensure .env.example exists
if [ ! -f .env.example ]; then
  cat > .env.example <<'ENV'
TELEGRAM_BOT_TOKEN=YOUR_TOKEN_HERE
ADMIN_IDS=12345,67890
WA_ENABLED=false
CEK_TIMEOUT_MS=180000
METRO_URL=http://124.195.52.213:9487/snmp/metro_manual.php
ENV
  ok "Created .env.example"
fi

# Untrack accidental .env from git index (keeps local file)
if git ls-files --error-unmatch .env >/dev/null 2>&1; then
  warn ".env is tracked—removing from index"
  git rm -q --cached .env || true
fi

ok "Repo tidied. Stage changes with 'git add -A' then commit."
