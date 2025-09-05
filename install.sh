#!/usr/bin/env bash
set -euo pipefail

SERVICE="vps-guardian"
INSTALL_DIR="/opt/vps-guardian"
REPO_URL_DEFAULT="https://github.com/vermilii/vps-guardian-pro-plus.git"

apt-get update -y
apt-get install -y python3 python3-venv python3-pip git rsync curl

mkdir -p "$INSTALL_DIR"
rsync -a --delete --exclude 'config.yaml' --exclude 'state.json' --exclude 'venv' ./ "$INSTALL_DIR"/

# Normalisasi LF
find "$INSTALL_DIR" -type f \( -name "*.py" -o -name "*.sh" -o -name "*.service" -o -name "*.yml" -o -name "*.yaml" \) -exec sed -i 's/\r$//' {} \;

# Venv + deps
python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install --upgrade pip >/dev/null
if [ -f "$INSTALL_DIR/requirements.txt" ]; then
  "$INSTALL_DIR/venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt" >/dev/null
else
  echo -e "psutil>=5.9.0\nPyYAML>=6.0.1\nrequests>=2.31.0" > "$INSTALL_DIR/requirements.txt"
  "$INSTALL_DIR/venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt" >/dev/null
fi

# Buat config.yaml kalau belum ada
if [ ! -f "$INSTALL_DIR/config.yaml" ]; then
  cat >"$INSTALL_DIR/config.yaml" <<YAML
telegram:
  bot_token: "PASTE_TOKEN_DISINI"
  chat_id: "PASTE_CHAT_ID"
  polling_interval: 2
prometheus:
  enable: false
  bind: "0.0.0.0"
  port: 9102
state:
  file: "$INSTALL_DIR/state.json"
YAML
  echo "NOTE: Edit $INSTALL_DIR/config.yaml lalu restart service."
fi

# Drain update Telegram lama (jika token diisi)
"$INSTALL_DIR/venv/bin/python" - <<'PY'
import sys, json, urllib.request, yaml, os
cfgp="/opt/vps-guardian/config.yaml"
if not os.path.exists(cfgp): raise SystemExit(0)
cfg=yaml.safe_load(open(cfgp,encoding="utf-8"))
tok=(cfg.get("telegram") or {}).get("bot_token") or ""
if not tok or "PASTE_TOKEN" in tok: raise SystemExit(0)
try:
    with urllib.request.urlopen(f"https://api.telegram.org/bot{tok}/getUpdates", timeout=10) as r:
        d=json.load(r); last=max([u.get("update_id",0) for u in d.get("result",[])] + [0])
    urllib.request.urlopen(f"https://api.telegram.org/bot{tok}/getUpdates?offset={last+1}", timeout=10).read()
    print("Drained Telegram updates:", last)
except Exception as e:
    print("Skip drain:", e)
PY
rm -f "$INSTALL_DIR/.tg_offset" || true

# Pasang service
cat > /etc/systemd/system/$SERVICE.service <<SERVICE
[Unit]
Description=VPS Guardian Pro Plus - Monitoring & Anti-DDoS with Telegram
After=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/vps_guardian.py
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
SERVICE

# Validasi YAML sebelum start
"$INSTALL_DIR/venv/bin/python" - <<'PY'
import yaml, sys
try:
    yaml.safe_load(open("/opt/vps-guardian/config.yaml","r",encoding="utf-8"))
    print("Config OK")
except Exception as e:
    print("Config ERROR:", e); sys.exit(1)
PY

# Pasang updateguardian ke /usr/local/bin agar bisa update 1x klik
install -m 755 "$INSTALL_DIR/updateguardian.sh" /usr/local/bin/updateguardian

systemctl daemon-reload
systemctl enable "$SERVICE"
systemctl restart "$SERVICE"

echo "Selesai. Cek: systemctl status $SERVICE --no-pager"
echo "Update nantinya cukup: sudo updateguardian"
