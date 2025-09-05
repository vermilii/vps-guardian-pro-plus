#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/vermilii/vps-guardian-pro-plus.git"
TMP="$(mktemp -d)"

git clone --depth=1 "$REPO_URL" "$TMP"

# Sinkron kode ke /opt/vps-guardian tapi JANGAN hapus config/state/venv
rsync -a --delete \
  --exclude 'config.yaml' \
  --exclude 'state.json' \
  --exclude 'venv' \
  "$TMP"/ /opt/vps-guardian/

# Pastikan venv ada
if [[ ! -x /opt/vps-guardian/venv/bin/pip ]]; then
  python3 -m venv /opt/vps-guardian/venv
fi

/opt/vps-guardian/venv/bin/pip install --upgrade pip >/dev/null
/opt/vps-guardian/venv/bin/pip install -r /opt/vps-guardian/requirements.txt >/dev/null

systemctl daemon-reload
systemctl restart vps-guardian

echo "✅ Updated from $REPO_URL (config & state kept; venv preserved)"
