#!/usr/bin/env bash
set -euo pipefail
action="${1:-}"
if [[ "$action" == "apply" ]]; then
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport 22 -m state --state NEW -m recent --set 2>/dev/null || true
    iptables -C INPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 60 --hitcount 6 -j DROP 2>/dev/null || \
    iptables -A INPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 60 --hitcount 6 -j DROP
  fi
  echo "Applied basic SSH rate-limit."
elif [[ "$action" == "revert" ]]; then
  if command -v iptables >/dev/null 2>&1; then
    iptables -D INPUT -p tcp --dport 22 -m state --state NEW -m recent --update --seconds 60 --hitcount 6 -j DROP 2>/dev/null || true
  fi
  echo "Reverted."
else
  echo "Usage: $0 apply|revert"
fi
