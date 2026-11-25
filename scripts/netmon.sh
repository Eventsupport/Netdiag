#!/usr/bin/env bash
# netmon – kör kommandon i netmon-containern utan att behöva veta dess ID.
# Installeras som /usr/local/bin/netmon på Proxmox-värden.
#   netmon                  öppna ett skal i containern
#   netmon <kommando …>     kör kommandot i containern, t.ex. netmon netdiag-events
#   netmon --id             skriv ut containerns ID
set -euo pipefail
id="${NETMON_ID:-$(pct list | awk 'NR>1 && $NF ~ /^netmon(-|$)/ {print $1; exit}')}"
[[ -n "$id" ]] || { echo "Hittar ingen container med namnet netmon (pct list, namn netmon*)." >&2; exit 1; }
case "${1:-}" in
  "")   exec pct enter "$id" ;;
  --id) echo "$id" ;;
  *)    exec pct exec "$id" -- env PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LANG=C.UTF-8 LC_ALL=C.UTF-8 "$@" ;;
esac
