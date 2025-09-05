#!/usr/bin/env bash
# Uninstaller untuk VPS Guardian Pro Plus
# Usage:
#   sudo bash uninstall.sh               # bersih standar (backup, hapus service, simpan folder)
#   sudo bash uninstall.sh --purge       # hapus total /opt/vps-guardian setelah backup
#   sudo bash uninstall.sh --dir /path   # kalau install dir bukan default
#   sudo bash uninstall.sh --service vps-guardian  # kalau nama servicenya beda
set -euo pipefail

INSTALL_DIR="/opt/vps-guardian"
SERVICE_NAME="vps-guardian"
PURGE=0
UNBLOCK=1

# --- arg parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --purge) PURGE=1; shift;;
    --no-unblock) UNBLOCK=0; shift;;
    --dir) INSTALL_DIR="${2:?}"; shift 2;;
    --service) SERVICE_NAME="${2:?}"; shift 2;;
    -h|--help)
      echo "Usage: sudo bash $0 [--purge] [--no-unblock] [--dir <path>] [--service <name>]"
      exit 0;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

ts="$(date +%F_%H%M%S)"
BACKUP_ROOT="/root/vps-guardian-backup-${ts}"
mkdir -p "$BACKUP_ROOT"

echo "==> Stop & disable service: ${SERVICE_NAME}"
systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
systemctl disable "${SERVICE_NAME}" 2>/dev/null || true

echo "==> Hapus unit systemd (jika ada)"
rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload || true

# --- Backup config/state penting ---
if [[ -d "$INSTALL_DIR" ]]; then
  echo "==> Backup config/state ke: ${BACKUP_ROOT}"
  for f in config.yaml state.json .tg_offset; do
    [[ -f "${INSTALL_DIR}/${f}" ]] && cp -a "${INSTALL_DIR}/${f}" "${BACKUP_ROOT}/" || true
  done
  tar -czf "${BACKUP_ROOT}/essentials.tgz" -C "${INSTALL_DIR}" \
    $(for f in config.yaml state.json .tg_offset; do [[ -f "${INSTALL_DIR}/${f}" ]] && echo "$f"; done) 2>/dev/null || true
else
  echo "   (skip) ${INSTALL_DIR} tidak ditemukan"
fi

# --- Lepaskan blokir IP yang mungkin tersimpan di state.json ---
if [[ "$UNBLOCK" -eq 1 && -f "${INSTALL_DIR}/state.json" ]]; then
  echo "==> Coba lepaskan blokir IP dari state.json (best-effort)"
  if command -v jq >/dev/null 2>&1; then
    mapfile -t IPS < <(jq -r '.blocked_ips | keys[]?' "${INSTALL_DIR}/state.json" 2>/dev/null || true)
  else
    IPS=()
  fi
  for ip in "${IPS[@]}"; do
    iptables  -D INPUT -s "$ip" -j DROP 2>/dev/null || true
    ip6tables -D INPUT -s "$ip" -j DROP 2>/dev/null || true
    if command -v nft >/dev/null 2>&1; then
      nft list ruleset >/dev/null 2>&1 || true
      nft delete rule inet filter input  ip  saddr "$ip" drop 2>/dev/null || true
      nft delete rule inet filter input  ip6 saddr "$ip" drop 2>/dev/null || true
    fi
  done
fi

# --- Hapus helper CLI yang umum dipasang ---
echo "==> Bersih-bersih helper CLI (jika ada)"
for bin in \
  /usr/local/bin/updateguardian \
  /usr/local/bin/guardian-sync-repo \
  /usr/local/bin/guardian-doctor \
  /usr/local/bin/guardian-autofix.sh \
  /usr/local/bin/uninstallguardian
do
  [[ -e "$bin" ]] && rm -f "$bin" || true
done

# --- Hapus folder aplikasi jika --purge ---
if [[ "$PURGE" -eq 1 ]]; then
  echo "==> PURGE: hapus direktori ${INSTALL_DIR}"
  rm -rf "${INSTALL_DIR}"
else
  echo "==> Direktori aplikasi TIDAK dihapus (gunakan --purge untuk hapus total)."
fi

echo "==> Selesai."
echo "Backup penting ada di: ${BACKUP_ROOT}"
