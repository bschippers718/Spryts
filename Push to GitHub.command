#!/bin/zsh
# Copies the project out of iCloud and pushes it to GitHub. Never includes .env or logs.
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="$HERE/push.log"
REPO="$HOME/Library/Caches/Spryts/repo"
exec > "$LOG" 2>&1
export GIT_TERMINAL_PROMPT=0
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
echo "START $(date)"
mkdir -p "$REPO"
rsync -a --delete --exclude ".git" --exclude ".env" --exclude ".build" --exclude "*.log" --exclude "Characters/models" --exclude ".DS_Store" "$HERE/" "$REPO/"
cd "$REPO" || { echo "PUSH FAILED: no repo folder"; exit 1; }
printf ".env\n.build/\n*.log\nCharacters/models/\n.DS_Store\n" > .gitignore
[ -d .git ] || git init -b main
git config user.name >/dev/null || git config user.name "Ben Schippers"
git config user.email >/dev/null || git config user.email "bschippers718@users.noreply.github.com"
git add -A
git commit -m "Spryts: characters, role workspaces, Orange Smash

Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Sgo1Hi61R8uEP7xBLYbdQG" || echo "nothing new to commit"
git branch -M main
git remote remove origin 2>/dev/null
git remote add origin https://github.com/bschippers718/Spryts.git
if git push -u origin main; then
  echo "PUSH OK (https)"
else
  echo "https push failed, trying ssh"
  git remote set-url origin git@github.com:bschippers718/Spryts.git
  if GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new" git push -u origin main; then
    echo "PUSH OK (ssh)"
  else
    echo "PUSH FAILED"
  fi
fi
git log --oneline | head -3
echo "END $(date)"
