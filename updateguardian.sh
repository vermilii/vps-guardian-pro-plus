#!/usr/bin/env bash
set -euo pipefail
REPO_URL="${REPO_URL:-$( [ -f /opt/vps-guardian/.repo_url ] && cat /opt/vps-guardian/.repo_url || echo "https://github.com/YOURNAME/vps-guardian-pro-plus.git" )}"
TMP="$(mktemp -d)"
git clone --depth=1 "$REPO_URL" "$TMP"
rsync -a --delete --exclude 'config.yaml' --exclude 'state.json' "$TMP"/ /opt/vps-guardian/
cd /opt/vps-guardian
/opt/vps-guardian/venv/bin/pip install -r requirements.txt >/dev/null
systemctl daemon-reload
systemctl restart vps-guardian
echo "✅ Updated from $REPO_URL (config.yaml kept)"
