#!/usr/bin/env bash
# netdiag-export – skapar felanmälningspaket och lägger zip-filen i /root
#   netdiag-export "08:00" "12:00"                         (idag)
#   netdiag-export "2026-11-25 08:00" "2026-11-26 12:00"
set -euo pipefail
ID="${NETMON_ID:-$(pct list | awk 'NR>1 && $NF ~ /^netmon(-|$)/ {print $1; exit}')}"
[[ -n "$ID" ]] || { echo "Hittar ingen netmon-container." >&2; exit 1; }
[[ $# -eq 2 ]] || { echo "Användning: netdiag-export \"[ÅÅÅÅ-MM-DD ]HH:MM\" \"[ÅÅÅÅ-MM-DD ]HH:MM\"" >&2; exit 1; }
out="$(pct exec "$ID" -- env LANG=C.UTF-8 LC_ALL=C.UTF-8 /usr/local/bin/netdiag-report "$1" "$2")"
f="$(sed -n 's/^Klart: //p' <<<"$out")"
[[ -n "$f" ]] || { echo "$out" >&2; exit 1; }
dest="/root/$(basename "$f")"
pct pull "$ID" "$f" "$dest"
echo "Sparad: $dest"
echo "Hämta till Windows:  pscp root@$(hostname -s):$dest ."
echo "Eller i webbläsaren: http://$(pct exec "$ID" -- hostname -I | awk '{print $1}'):8080/"
