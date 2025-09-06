# VPS Guardian Pro Plus

Monitoring & proteksi ringan untuk VPS dengan **notifikasi Telegram**, **quick menu**, dan opsi **tindakan otomatis** (auto-remediation). Dirancang agar install/update aman: validasi YAML, anti-loop restart, dan perintah perawatan siap pakai.

---

## ✨ Fitur Utama

- **Notifikasi Telegram**: login SSH mencurigakan, CPU/Mem/Disk/Load tinggi (dengan *penyebab / cause hints*), proses boros/aneh, dsb.
- **Quick Menu (Reply Keyboard)** di Telegram: 📋 Menu, 📊 Status, 🧪 Self-test, 🚫 Blocked, 🛡 Fail2ban, ☁️ Cloudflare, 🔁 Restart Agent.
- **Anti-Loop Restart**: menyimpan `update_id` ke disk (`.tg_offset`) + restart delay aman → tidak spam “restarting…”.
- **Auto Remediation (opsional)**: bisa otomatis meng-kill proses boros, throttle, atau memban IP (via Fail2ban/iptables).
- **Integrasi Fail2ban (opsional)**: jail `sshd` siap pakai.
- **Prometheus exporter (opsional)**: endpoint `/metrics` untuk Grafana/Prometheus.
- **Uninstall & Update mudah**: `uninstall.sh` dan `updateguardian` tidak merusak `venv`/`config`.

> **Teruji**: Ubuntu 20.04/22.04 (root/sudo).

---

## ⚡ Quick Install (Non-Interactive)

> **Wajib:** Bot Telegram aktif & kamu sudah **/start** di DM bot.  
> **Perlu:** `TELEGRAM_BOT_TOKEN` dan `TELEGRAM_CHAT_ID` (angka; untuk supergroup: negatif, contoh `-100xxxxxxxxxx`).

```bash
sudo apt update -y && sudo apt install -y git unzip
git clone https://github.com/vermilii/vps-guardian-pro-plus.git
cd vps-guardian-pro-plus

sudo TELEGRAM_BOT_TOKEN="ISI_TOKEN" TELEGRAM_CHAT_ID="ISI_CHAT_ID" \
     PROM_ENABLE="y" PROM_PORT="9877" \
     INSTALL_FAIL2BAN="y" FAIL2BAN_JAIL="sshd" \
     CF_ENABLED="n" \
     bash install.sh

# cek layanan
systemctl status vps-guardian --no-pager
journalctl -u vps-guardian -f

🛠️ Perintah Penting
# start/stop/restart & log
sudo systemctl start|stop|restart vps-guardian
sudo journalctl -u vps-guardian -f

# update kode (preserve venv/config)
sudo updateguardian

# uninstall bersih
sudo /opt/vps-guardian/uninstall.sh

📁 Struktur & Lokasi

Kode & venv: /opt/vps-guardian/

Konfigurasi utama: /opt/vps-guardian/config.yaml

State file: /opt/vps-guardian/state.json

Offset Telegram anti-loop: /opt/vps-guardian/.tg_offset

Unit systemd: /etc/systemd/system/vps-guardian.service

⚙️ Konfigurasi (/opt/vps-guardian/config.yaml)

Installer membuat config minimal. Kunci terpenting:

telegram:
  bot_token: "PASTE_TOKEN"
  chat_id: "PASTE_CHAT_ID"
  polling_interval: 2

# thresholds lama tetap didukung; monitoring di bawah bisa mengambil nilai dari sini jika ada
thresholds:
  cpu: 75
  mem: 85
  disk: 90
  load_per_core: 1.5

# WAJIB ada (installer/doctor akan auto-patch bila hilang)
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
  file: "/opt/vps-guardian/state.json"

prometheus:
  enable: false
  bind: "0.0.0.0"
  port: 9877

fail2ban:
  enable: true
  jail: "sshd"

cloudflare:
  enable: false
  api_token: ""
  zone_id: ""

firewall:
  whitelist_ips: ["127.0.0.1"]


Ganti token/chat id dengan aman (tanpa sed):

sudo python3 - <<'PY'
import yaml
p="/opt/vps-guardian/config.yaml"
cfg=yaml.safe_load(open(p,"rb")) or {}
cfg.setdefault("telegram",{})
cfg["telegram"]["bot_token"]="ISI_TOKEN_BARU"
cfg["telegram"]["chat_id"]=str("ISI_CHAT_ID_BARU")
yaml.safe_dump(cfg, open(p,"w"), sort_keys=False)
print("Config Telegram updated.")
PY
sudo rm -f /opt/vps-guardian/.tg_offset
sudo systemctl restart vps-guardian

📱 Perintah Telegram

Ketik atau tekan tombol:

/menu (atau tombol 📋 Menu) – tampilkan keyboard cepat.

/status – CPU/Mem/Disk/Load + penyebab (top process) & saran cepat.

/selftest – uji kirim pesan ke chat.

/blocked – daftar IP yang diblokir (jika tersedia).

/f2b_status – status Fail2ban (jika diaktifkan).

/cf_status – status Cloudflare (jika diaktifkan).

/restart_agent – restart service agent (anti-loop safe).

🧪 Troubleshooting Telegram

Pastikan kamu sudah DM bot dan tekan Start.

Validasi token + kirim uji:

TOKEN=$(python3 -c 'import yaml;print(yaml.safe_load(open("/opt/vps-guardian/config.yaml","rb"))["telegram"]["bot_token"])')
CHAT=$(python3 -c 'import yaml;print(yaml.safe_load(open("/opt/vps-guardian/config.yaml","rb"))["telegram"]["chat_id"])')

curl -s https://api.telegram.org/bot$TOKEN/getMe | jq .
curl -s -X POST https://api.telegram.org/bot$TOKEN/sendMessage \
     -d chat_id="$CHAT" -d text="ping" | jq .


Jika ok=false → token salah / chat_id tidak cocok / bot belum di-Start.

Cari kandidat chat_id (kirim /start ke bot, lalu):

curl -s https://api.telegram.org/bot$TOKEN/getUpdates | \
  jq '.result | map({id: (.message.chat.id // .channel_post.chat.id // .edited_message.chat.id), title: (.message.chat.title // .channel_post.chat.title // .edited_message.chat.title), type: (.message.chat.type // .channel_post.chat.type // .edited_message.chat.type)}) | unique'


Update telegram.chat_id, hapus offset, restart:

sudo rm -f /opt/vps-guardian/.tg_offset && sudo systemctl restart vps-guardian


Cek log service:

journalctl -u vps-guardian -n 150 --no-pager

🛡️ Fail2ban & Keamanan SSH

Aktifkan saat install (INSTALL_FAIL2BAN="y" & FAIL2BAN_JAIL="sshd").

Lihat status:

sudo fail2ban-client status
sudo fail2ban-client status sshd


Rekomendasi: pakai SSH key; pertimbangkan menonaktifkan password login; ganti port ssh bila perlu.

📊 Prometheus (Opsional)

Aktifkan saat install (PROM_ENABLE="y" dan PROM_PORT="9877") atau ubah di config.yaml.
Endpoint: http://<ip>:9877/metrics → bisa di-scrape Prometheus lalu divisualisasikan di Grafana.

🔁 Update & 🧹 Uninstall
# Update kode dari repo (venv/config aman)
sudo updateguardian

# Uninstall bersih (menghapus service & direktori app)
sudo /opt/vps-guardian/uninstall.sh

🧰 Doctor & Anti-Loop

Agent menyimpan offset Telegram di /opt/vps-guardian/.tg_offset agar tidak memproses ulang update lama.

Perintah Restart Agent sudah diberi delay & persist offset → menghindari spam “restarting…”.

Jika terjadi error konfigurasi, jalankan doctor (bila tersedia di repo) atau periksa log systemd.

📝 Catatan Windows (CRLF)

Jika mengedit file di Windows, pastikan line endings LF. Repo menyertakan .gitattributes untuk memaksa LF pada .py/.sh/.service/.yml/.yaml.

FAQ Singkat

Bot tidak respon? Cek token & chat_id, pastikan sudah /start, reset .tg_offset, lalu restart service.

CPU/RAM tinggi dapat notifikasi, bisa auto-tindak? Bisa diaktifkan via alerts/monitoring/remediator (lihat kode & config). Notifikasi menyertakan cause hints (top process) agar kamu bisa bertindak cepat.

Ganti token/chat id? Lihat snippet update YAML di bagian konfigurasi.

Lisensi

MIT (lihat file LICENSE).


> Setelah ditempel, commit & push seperti biasa:
> ```
> git add README.md
> git commit -m "docs: rewrite README end-to-end"
> git push
> ```
> Kalau mau, nanti aku siapkan **install.sh** versi final (auto-patch `monitoring` + validasi YAML) dan **guardian-doctor** jadi kamu cukup `updateguardian` untuk narik perubahan.
::contentReference[oaicite:0]{index=0}
