#!/usr/bin/env bash
# install.sh - VPS Guardian Pro Plus (dengan APT Guard)
set -euo pipefail
umask 022

SERVICE="vps-guardian"
APP="/opt/vps-guardian"

# ===== opsi ENV non-interaktif (opsional) =====
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
PROM_ENABLE="${PROM_ENABLE:-n}"          # y/n
PROM_BIND="${PROM_BIND:-0.0.0.0}"
PROM_PORT="${PROM_PORT:-9877}"
INSTALL_FAIL2BAN="${INSTALL_FAIL2BAN:-n}"# y/n
FAIL2BAN_JAIL="${FAIL2BAN_JAIL:-sshd}"
CF_ENABLED="${CF_ENABLED:-n}"            # y/n
CF_TOKEN="${CF_TOKEN:-}"
CF_ZONE_ID="${CF_ZONE_ID:-}"

APT_GUARD_ENABLE="${APT_GUARD_ENABLE:-y}"      # y/n (default aktif)
APT_GUARD_TIMEOUT="${APT_GUARD_TIMEOUT:-180}"  # detik
APT_GUARD_STRICT="${APT_GUARD_STRICT:-y}"      # y=blokir bila timeout/gagal kirim; n=allow
APT_GUARD_WHITELIST="${APT_GUARD_WHITELIST:-}" # pola dipisah koma, ex: "apt,base-files,linux-*"

# ===== helper =====
need_root() { [ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Jalankan sebagai root (sudo)."; exit 1; }; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }
log() { echo -e "\033[1;36m==>\033[0m $*"; }
warn() { echo -e "\033[1;33mWARN:\033[0m $*"; }
die() { echo -e "\033[1;31mERROR:\033[0m $*"; exit 1; }

need_root
has_cmd apt-get || die "Hanya mendukung Ubuntu/Debian (apt)."

# ===== deps awal =====
log "Instal dependensi dasar"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y python3 python3-venv python3-pip git rsync curl jq ca-certificates >/dev/null

# ===== siapkan direktori & salin kode repo (jalankan dari root repo) =====
log "Siapkan direktori $APP"
install -d -m 755 "$APP"

log "Salin kode ke $APP (exclude venv, config, state)"
rsync -a --delete \
  --exclude '.git' \
  --exclude 'venv' \
  --exclude 'config.yaml' \
  --exclude 'state.json' \
  --exclude '.tg_offset' \
  ./ "$APP"/

# ===== normalisasi CRLF → LF =====
log "Normalisasi CRLF → LF"
find "$APP" -type f \( -name "*.py" -o -name "*.sh" -o -name "*.service" -o -name "*.yml" -o -name "*.yaml" \) -exec sed -i 's/\r$//' {} \;

# ===== venv + requirements =====
log "Buat/upgrade venv + install requirements"
if [ ! -x "$APP/venv/bin/python" ]; then
  python3 -m venv "$APP/venv"
fi
"$APP/venv/bin/pip" install --upgrade pip >/dev/null
if [ -f "$APP/requirements.txt" ]; then
  "$APP/venv/bin/pip" install -r "$APP/requirements.txt" >/dev/null
else
  echo -e "psutil>=5.9.0\nPyYAML>=6.0.1\nrequests>=2.31.0" > "$APP/requirements.txt"
  "$APP/venv/bin/pip" install -r "$APP/requirements.txt" >/dev/null
fi

# ===== buat/patch config.yaml =====
CFG="$APP/config.yaml"
log "Buat/Patch config.yaml"
if [ ! -f "$CFG" ]; then
  cat >"$CFG" <<CFG
telegram:
  bot_token: "${TELEGRAM_BOT_TOKEN:-PASTE_TOKEN}"
  chat_id: "${TELEGRAM_CHAT_ID:-PASTE_CHAT_ID}"
  polling_interval: 2

thresholds:
  cpu: 75
  mem: 85
  disk: 90
  load_per_core: 1.5

monitoring:
  interval: 5
  cpu_threshold: 75
  mem_threshold: 85
  disk_threshold: 90
  load_threshold: 1.5
  notify_cooldown_seconds: 120

alerts:
  ssh_ban_notify: true
  ssh_ban_throttle_minutes: 30
  overload_cause: true
  confirm_kill: true

state:
  file: "$APP/state.json"

prometheus:
  enable: ${PROM_ENABLE/y/true}
  bind: "${PROM_BIND}"
  port: ${PROM_PORT}

fail2ban:
  enable: ${INSTALL_FAIL2BAN/y/true}
  jail: "${FAIL2BAN_JAIL}"

cloudflare:
  enable: ${CF_ENABLED/y/true}
  api_token: "${CF_TOKEN}"
  zone_id: "${CF_ZONE_ID}"

apt_guard:
  enable: ${APT_GUARD_ENABLE/y/true}
  timeout_seconds: ${APT_GUARD_TIMEOUT}
  strict: ${APT_GUARD_STRICT/y/true}
  whitelist: [${APT_GUARD_WHITELIST:+$(echo "$APT_GUARD_WHITELIST" | awk -F, '{for(i=1;i<=NF;i++){gsub(/^[ \t]+|[ \t]+$/,"",$i); if($i!=""){printf "\"%s\"%s",$i,(i<NF?", ":"")}}}')}]

firewall:
  whitelist_ips: ["127.0.0.1"]
CFG
else
  "$APP/venv/bin/python" - <<'PY'
import os, yaml, sys
p=os.environ.get("CFG")
cfg=yaml.safe_load(open(p,"rb")) or {}
# telegram
tg=cfg.get("telegram") or {}
tg.setdefault("bot_token", os.environ.get("TELEGRAM_BOT_TOKEN","PASTE_TOKEN"))
tg.setdefault("chat_id", os.environ.get("TELEGRAM_CHAT_ID","PASTE_CHAT_ID"))
tg.setdefault("polling_interval", 2)
cfg["telegram"]=tg
# thresholds → monitoring default
thr=cfg.get("thresholds") or {}
mon=cfg.get("monitoring") or {}
mon.setdefault("interval", 5)
mon.setdefault("cpu_threshold", thr.get("cpu",75))
mon.setdefault("mem_threshold", thr.get("mem",85))
mon.setdefault("disk_threshold",thr.get("disk",90))
mon.setdefault("load_threshold",thr.get("load_per_core",1.5))
mon.setdefault("notify_cooldown_seconds",120)
cfg["monitoring"]=mon
# prometheus
pr=cfg.get("prometheus") or {}
def truthy(k, d): v=os.environ.get(k); return d if v is None else (str(v).lower() in ("1","true","y","yes","on"))
pr["enable"]=truthy("PROM_ENABLE", pr.get("enable", False))
pr["bind"]=os.environ.get("PROM_BIND", pr.get("bind","0.0.0.0"))
pr["port"]=int(os.environ.get("PROM_PORT", pr.get("port",9877)))
cfg["prometheus"]=pr
# fail2ban
f2b=cfg.get("fail2ban") or {}
f2b["enable"]=truthy("INSTALL_FAIL2BAN", f2b.get("enable",False))
f2b["jail"]=os.environ.get("FAIL2BAN_JAIL", f2b.get("jail","sshd"))
cfg["fail2ban"]=f2b
# cloudflare
cf=cfg.get("cloudflare") or {}
cf["enable"]=truthy("CF_ENABLED", cf.get("enable",False))
cf["api_token"]=os.environ.get("CF_TOKEN", cf.get("api_token",""))
cf["zone_id"]=os.environ.get("CF_ZONE_ID", cf.get("zone_id",""))
cfg["cloudflare"]=cf
# apt_guard
ag=cfg.get("apt_guard") or {}
ag["enable"]=truthy("APT_GUARD_ENABLE", ag.get("enable",True))
ag["timeout_seconds"]=int(os.environ.get("APT_GUARD_TIMEOUT", ag.get("timeout_seconds",180)))
ag["strict"]=truthy("APT_GUARD_STRICT", ag.get("strict",True))
wl=os.environ.get("APT_GUARD_WHITELIST")
if wl and not ag.get("whitelist"):
    ag["whitelist"]=[x.strip() for x in wl.split(",") if x.strip()]
ag.setdefault("whitelist", [])
cfg["apt_guard"]=ag
# state / firewall
st=cfg.get("state") or {}
st["file"]=st.get("file", os.path.join(os.environ.get("APP","/opt/vps-guardian"),"state.json"))
cfg["state"]=st
fw=cfg.get("firewall") or {}
fw.setdefault("whitelist_ips", ["127.0.0.1"])
cfg["firewall"]=fw
yaml.safe_dump(cfg, open(p,"w"), sort_keys=False)
print("config.yaml patched.")
PY
fi

# ===== validasi YAML =====
log "Validasi YAML"
"$APP/venv/bin/python" - <<PY
import yaml,sys; p="$CFG"
try:
    yaml.safe_load(open(p,"rb"))
    print("Config OK")
except Exception as e:
    print("Config ERROR:", e); sys.exit(1)
PY

# ===== optional: pasang fail2ban =====
if [ "${INSTALL_FAIL2BAN,,}" = "y" ]; then
  log "Pasang Fail2ban"
  apt-get install -y fail2ban >/dev/null || warn "Gagal pasang fail2ban"
fi

# ===== integrasi APT Guard (file bot + hook) =====
log "Pasang APT Guard (bot handler + apt hook)"
install -d -m 755 "$APP/utils" "$APP/run/apt_guard"

# — bot-side handler: tulis keputusan dari tombol Approve/Deny ke file nonce.decision
cat >"$APP/utils/apt_guard.py" <<'PY'
import os, json, time
class AptGuardBot:
    def __init__(self, cfg, notify, bot):
        self.dir = "/opt/vps-guardian/run/apt_guard"
        self.notify = notify
        self.bot = bot
        try: os.makedirs(self.dir, exist_ok=True)
        except Exception: pass
    def register(self):
        self.bot.on_callback("apt:approve:", self._cb)
        self.bot.on_callback("apt:deny:", self._cb)
    def _cb(self, cb_id, payload):
        data = payload.get("data","")
        # format: apt:approve:<nonce>  atau  apt:deny:<nonce>
        try:
            _, action, nonce = data.split(":", 2)
            path = os.path.join(self.dir, f"{nonce}.decision")
            with open(path, "w") as f:
                f.write(action)
            try: self.bot.answer_callback(cb_id, f"{action.capitalize()} OK")
            except Exception: pass
        except Exception:
            try: self.bot.answer_callback(cb_id, "Bad data")
            except Exception: pass
PY

# — apt hook (dipanggil oleh APT sebelum dpkg jalan)
#   membaca daftar paket dari STDIN, kirim permintaan approve via Telegram,
#   lalu menunggu file keputusan dari bot hingga timeout.
cat >"$APP/apt_guard_hook.py" <<'PY'
#!/opt/vps-guardian/venv/bin/python
import sys, os, time, yaml, json, socket, getpass, fnmatch, requests, random, string

APP = "/opt/vps-guardian"
CFG = os.path.join(APP,"config.yaml")
RUN = os.path.join(APP,"run","apt_guard")
os.makedirs(RUN, exist_ok=True)

def load_cfg():
    try: return yaml.safe_load(open(CFG,"rb")) or {}
    except Exception: return {}

def send_tg(token, chat_id, text, buttons=None):
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    payload = {"chat_id": str(chat_id), "text": text, "parse_mode":"HTML", "disable_web_page_preview": True}
    if buttons:
        payload["reply_markup"] = json.dumps({"inline_keyboard": buttons})
    try:
        r = requests.post(url, data=payload, timeout=10)
        return r.ok
    except Exception:
        return False

def main():
    # bypass cepat
    if os.environ.get("GUARDIAN_BYPASS") == "1" or os.path.exists(os.path.join(APP,"apt_guard_disable")):
        return 0

    cfg = load_cfg()
    ag = cfg.get("apt_guard") or {}
    if not ag.get("enable", True):
        return 0

    tg = (cfg.get("telegram") or {})
    token = tg.get("bot_token") or ""
    chat  = tg.get("chat_id") or ""
    if not token or "PASTE_TOKEN" in token or not str(chat).strip():
        # Telegram belum diset → fallback
        return 0 if not ag.get("strict", True) else 1

    timeout = int(ag.get("timeout_seconds", 180))
    wl = ag.get("whitelist") or []

    # baca paket dari stdin
    raw = sys.stdin.read().strip().splitlines()
    # format baris contoh: "install pkg:amd64 <cur-ver> <cand-ver>"
    pkgs = []
    for line in raw:
        parts = line.split()
        if not parts: continue
        # ambil kandidat nama paket di token ke-1 (install/upgrade/remove) → parts[1]
        if len(parts) >= 2 and ":" in parts[1]:
            name = parts[1].split(":")[0]
        elif len(parts) >= 2:
            name = parts[1]
        else:
            continue
        pkgs.append(name)

    if not pkgs:
        return 0

    # filter whitelist (glob)
    remain = []
    for p in pkgs:
        allowed = any(fnmatch.fnmatch(p, pat) for pat in wl)
        if not allowed: remain.append(p)

    if not remain:
        return 0

    # siapkan nonce & file penghubung
    nonce = f"{int(time.time())}-" + "".join(random.choices(string.ascii_lowercase+string.digits,k=6))
    decision_file = os.path.join(RUN, f"{nonce}.decision")

    # kirim permintaan persetujuan
    host = socket.gethostname()
    user = os.environ.get("SUDO_USER") or os.environ.get("USER") or getpass.getuser()
    preview = ", ".join(remain[:8]) + (f" (+{len(remain)-8})" if len(remain)>8 else "")
    text = (f"<b>[APT Guard]</b> {host}\n"
            f"User: <code>{user}</code>\n"
            f"Akan memasang/upgrade paket:\n<code>{preview}</code>\n\n"
            f"Setujui?")
    buttons = [[
        {"text":"✅ Approve", "callback_data": f"apt:approve:{nonce}"},
        {"text":"❌ Deny",    "callback_data": f"apt:deny:{nonce}"}
    ]]
    ok = send_tg(token, chat, text, buttons)
    if not ok:
        return 0 if not ag.get("strict", True) else 1

    # tunggu keputusan
    t0 = time.time()
    while time.time() - t0 < timeout:
        if os.path.exists(decision_file):
            try:
                d = open(decision_file).read().strip()
            except Exception:
                d = ""
            try: os.remove(decision_file)
            except Exception: pass
            if d == "approve":
                return 0
            else:
                return 1
        time.sleep(1)

    # timeout
    return 1 if ag.get("strict", True) else 0

if __name__ == "__main__":
    sys.exit(main())
PY
chmod +x "$APP/apt_guard_hook.py"

# — aktifkan hook APT setelah semua deps terpasang
cat >/etc/apt/apt.conf.d/90guardian-apt-guard <<CONF
DPkg::Pre-Install-Pkgs { "/opt/vps-guardian/apt_guard_hook.py"; };
CONF

# ===== patch vps_guardian.py untuk memuat handler APT Guard (aman & idempotent) =====
log "Patch vps_guardian.py agar muat AptGuardBot (idempotent)"
if ! grep -q "from utils.apt_guard import AptGuardBot" "$APP/vps_guardian.py" 2>/dev/null; then
  # sisipkan setelah inisiasi bot = SimpleBot(...)
  python3 - "$APP/vps_guardian.py" <<'PY'
import io,sys,re
p=sys.argv[1]
s=open(p,'r',encoding='utf-8').read()
pat=re.compile(r'(bot\s*=\s*SimpleBot\(.*?\)\s*)', re.S)
inj=r"""\1
# --- APT Guard integration (auto injected) ---
try:
    from utils.apt_guard import AptGuardBot
    AptGuardBot(cfg, notify, bot).register()
except Exception as _e:
    # diamkan jika modul tak ada / error agar service tetap jalan
    pass
# --- end APT Guard integration ---
"""
ns, n = pat.subn(inj, s, count=1)
if n==0:
    # fallback: append di akhir main() sebelum loop
    ns = re.sub(r'(bot\.start_polling\(\).*?\n)(\s*ResourceMonitor\()', r"\1\n    # (APT Guard hook try-load removed if not used)\n    try:\n        from utils.apt_guard import AptGuardBot\n        AptGuardBot(cfg, notify, bot).register()\n    except Exception:\n        pass\n\n    \2", s, count=1, flags=re.S)
open(p,'w',encoding='utf-8').write(ns)
print("Injected.")
PY
fi

# ===== drain update Telegram lama (kalau token sudah diisi) =====
"$APP/venv/bin/python" - <<'PY'
import sys, json, urllib.request, yaml, os
cfgp="/opt/vps-guardian/config.yaml"
if not os.path.exists(cfgp): raise SystemExit(0)
cfg=yaml.safe_load(open(cfgp,encoding="utf-8")) or {}
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
rm -f "$APP/.tg_offset" || true

# ===== unit systemd =====
log "Tulis unit systemd"
cat > /etc/systemd/system/$SERVICE.service <<SERVICE
[Unit]
Description=VPS Guardian Pro Plus - Monitoring & Anti-DDoS with Telegram
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$APP
ExecStart=$APP/venv/bin/python $APP/vps_guardian.py
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable "$SERVICE" >/dev/null

# ===== helper update & uninstall =====
log "Pasang updateguardian & uninstall"
cat > /usr/local/bin/updateguardian <<'UPD'
#!/usr/bin/env bash
set -euo pipefail
APP="/opt/vps-guardian"; SERVICE="vps-guardian"
TMP="$(mktemp -d)"
REPO_URL="$(cat "$APP/.repo_url" 2>/dev/null || true)"
if [ -z "${REPO_URL:-}" ]; then
  echo "Usage: updateguardian <repo_url>"; [ $# -ge 1 ] || exit 1
  REPO_URL="$1"; echo "$REPO_URL" > "$APP/.repo_url"
fi
git clone --depth=1 "$REPO_URL" "$TMP" >/dev/null
find "$TMP" -type f \( -name "*.py" -o -name "*.sh" -o -name "*.service" -o -name "*.yml" -o -name "*.yaml" \) -exec sed -i 's/\r$//' {} \;
rsync -a --delete --exclude '.git' --exclude 'venv' --exclude 'config.yaml' --exclude 'state.json' --exclude '.tg_offset' --exclude '.repo_url' "$TMP"/ "$APP"/
[ -f "$APP/requirements.txt" ] && "$APP/venv/bin/pip" install -r "$APP/requirements.txt" >/dev/null
systemctl restart "$SERVICE"
rm -rf "$TMP"
echo "OK. Service restarted."
UPD
chmod +x /usr/local/bin/updateguardian

cat > "$APP/uninstall.sh" <<UN
#!/usr/bin/env bash
set -euo pipefail
SERVICE="$SERVICE"; APP="$APP"
echo "Stop & disable \$SERVICE"; systemctl stop "\$SERVICE" || true; systemctl disable "\$SERVICE" || true
rm -f "/etc/systemd/system/\$SERVICE.service"; systemctl daemon-reload
rm -f /etc/apt/apt.conf.d/90guardian-apt-guard
echo "Hapus \$APP"; rm -rf "\$APP"
echo "Selesai."
UN
chmod +x "$APP/uninstall.sh"

# ===== start service kalau TOKEN/CHAT valid =====
START_OK=true
if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" || "$TELEGRAM_BOT_TOKEN" = "PASTE_TOKEN" || "$TELEGRAM_CHAT_ID" = "PASTE_CHAT_ID" ]]; then
  START_OK=false
  warn "BOT TOKEN / CHAT ID belum diisi. Service belum dijalankan."
  echo "Edit $CFG lalu jalankan:  sudo rm -f $APP/.tg_offset && sudo systemctl restart $SERVICE"
fi

if $START_OK; then
  rm -f "$APP/.tg_offset" || true
  log "Start service"
  systemctl restart "$SERVICE"
  sleep 1
  systemctl status "$SERVICE" --no-pager -l | sed -n '1,12p'
fi

log "Selesai. Perintah penting:
  systemctl status $SERVICE --no-pager
  journalctl -u $SERVICE -f
  updateguardian                 # update kode dari repo
  $APP/uninstall.sh             # uninstall
  # Toggle APT Guard cepat:  touch $APP/apt_guard_disable  (disable) / rm -f file (enable)
  # Bypass sekali jalan:     GUARDIAN_BYPASS=1 apt-get install <pkg>"
