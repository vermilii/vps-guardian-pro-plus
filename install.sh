#!/usr/bin/env bash
set -euo pipefail
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then echo "Please run as root (sudo)." >&2; exit 1; fi
REPO_DIR="$(pwd)"; INSTALL_DIR="/opt/vps-guardian"; SERVICE_NAME="vps-guardian"

read_var(){ local var="$1" prompt="$2" def="${3:-}"; if [[ -n "${!var-}" ]]; then echo "${!var}"; else read -rp "$prompt${def:+ [$def]}: " input; echo "${input:-$def}"; fi; }

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-$(read_var TELEGRAM_BOT_TOKEN 'Masukkan TELEGRAM_BOT_TOKEN' '')}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-$(read_var TELEGRAM_CHAT_ID 'Masukkan TELEGRAM_CHAT_ID' '')}"

PROM_ENABLE="${PROM_ENABLE:-$(read_var PROM_ENABLE 'Aktifkan Prometheus exporter? (y/N)' 'y')}"
PROM_PORT="${PROM_PORT:-$(read_var PROM_PORT 'Port Prometheus' '9877')}"
INSTALL_FAIL2BAN="${INSTALL_FAIL2BAN:-$(read_var INSTALL_FAIL2BAN 'Install & aktifkan Fail2ban? (y/N)' 'y')}"
FAIL2BAN_JAIL="${FAIL2BAN_JAIL:-$(read_var FAIL2BAN_JAIL 'Nama jail Fail2ban' 'sshd')}"
CF_ENABLED="${CF_ENABLED:-$(read_var CF_ENABLED 'Aktifkan integrasi Cloudflare? (y/N)' 'n')}"
CF_API_TOKEN="${CF_API_TOKEN:-$(read_var CF_API_TOKEN 'Masukkan CF_API_TOKEN (jika enable)' '')}"
CF_ZONE_ID="${CF_ZONE_ID:-$(read_var CF_ZONE_ID 'Masukkan CF_ZONE_ID (jika enable)' '')}"

apt-get update -y
apt-get install -y python3 python3-venv python3-pip curl git rsync jq >/dev/null

mkdir -p "$INSTALL_DIR"
rsync -a --delete "$REPO_DIR"/ "$INSTALL_DIR"/

python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install --upgrade pip >/dev/null
"$INSTALL_DIR/venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt" >/dev/null

CFG="$INSTALL_DIR/config.yaml"
sed -ri "s|(bot_token:).*|\1 \"$TELEGRAM_BOT_TOKEN\"|" "$CFG"
sed -ri "s|(chat_id:).*|\1 \"$TELEGRAM_CHAT_ID\"|" "$CFG"

if [[ "$PROM_ENABLE" =~ ^[Yy]$ ]]; then sed -ri '0,/prometheus:\s*$/{n;s/(enable:).*/\1 true/}' "$CFG"; sed -ri "0,/(port:).*/{s//\1 $PROM_PORT/}" "$CFG"; else sed -ri '0,/prometheus:\s*$/{n;s/(enable:).*/\1 false/}' "$CFG"; fi
if [[ "$INSTALL_FAIL2BAN" =~ ^[Yy]$ ]]; then apt-get install -y fail2ban >/dev/null || true; systemctl enable fail2ban >/dev/null || true; systemctl restart fail2ban || true; sed -ri '0,/fail2ban:\s*$/{n;s/(enable:).*/\1 true/}' "$CFG"; sed -ri "0,/jail:.*/{s//jail: \"$FAIL2BAN_JAIL\"/}" "$CFG"; else sed -ri '0,/fail2ban:\s*$/{n;s/(enable:).*/\1 false/}' "$CFG"; fi
if [[ "$CF_ENABLED" =~ ^[Yy]$ ]]; then sed -ri '0,/cloudflare:\s*$/{n;s/(enable:).*/\1 true/}' "$CFG"; sed -ri "s|(api_token:).*|\1 \"$CF_API_TOKEN\"|" "$CFG"; sed -ri "s|(zone_id:).*|\1 \"$CF_ZONE_ID\"|" "$CFG"; else sed -ri '0,/cloudflare:\s*$/{n;s/(enable:).*/\1 false/}' "$CFG"; fi

cp "$INSTALL_DIR/vps-guardian.service" /etc/systemd/system/

"$INSTALL_DIR/venv/bin/python" - <<'PY'
import yaml, sys
try:
    with open("/opt/vps-guardian/config.yaml","r",encoding="utf-8") as f:
        yaml.safe_load(f)
    print("Config OK")
except Exception as e:
    print("Config ERROR:", e); sys.exit(1)
PY

REPO_URL="$(git -C "$REPO_DIR" config --get remote.origin.url || echo '')"
echo "${REPO_URL:-https://github.com/YOURNAME/vps-guardian-pro-plus.git}" > /opt/vps-guardian/.repo_url
install -m 0755 "$INSTALL_DIR/updateguardian.sh" /usr/local/bin/updateguardian

# --- Drain update Telegram lama agar tidak dikonsumsi saat start pertama ---
if [[ -n "$TELEGRAM_BOT_TOKEN" ]]; then
  "$INSTALL_DIR/venv/bin/python" - <<'PY' "$TELEGRAM_BOT_TOKEN"
import sys, json, urllib.request
tok = sys.argv[1]
try:
    with urllib.request.urlopen(f"https://api.telegram.org/bot{tok}/getUpdates", timeout=10) as r:
        d=json.load(r)
        last=max([u.get("update_id",0) for u in d.get("result",[])] + [0])
    urllib.request.urlopen(f"https://api.telegram.org/bot{tok}/getUpdates?offset={last+1}", timeout=10).read()
    print("Drained Telegram updates:", last)
except Exception as e:
    print("Skip drain:", e)
PY
  rm -f /opt/vps-guardian/.tg_offset || true
fi

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"
echo "Selesai. Cek: systemctl status ${SERVICE_NAME}"
