#!/usr/bin/env bash
# =============================================================================
# new-site.sh – förbered boxen för en ny kund
#
# Körs som root på Proxmox-värden:
#   SITE_NAME="Kund AB Ort" TARGETS="192.168.1.1 100.64.0.1 1.1.1.1 8.8.8.8 9.9.9.9 ping.sunet.se teliaplay.se" \
#     bash scripts/new-site.sh
#
# 1. Sätter platsnamn och mål (via update-netmon.sh)
# 2. Raderar ALL gammal mätdata i netmon-containern (netdiag-reset)
# Utelämnas TARGETS behålls nuvarande mål.
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[[ $EUID -eq 0 ]] || { echo "Kör som root." >&2; exit 1; }
[[ -n "${SITE_NAME:-}" ]] || { echo "Ange SITE_NAME=\"Kund AB Ort\" före kommandot." >&2; exit 1; }

id="${NETMON_ID:-$(pct list | awk 'NR>1 && $NF ~ /^netmon(-|$)/ {print $1; exit}')}"
[[ -n "$id" ]] || { echo "Hittar ingen netmon-container (pct list)." >&2; exit 1; }
old_site="$(pct exec "$id" -- sed -nE 's/^SITE_NAME="(.*)"$/\1/p' /etc/netdiag.conf 2>/dev/null || true)"

cat <<EOF

  Ny kund:   $SITE_NAME
  Mål:       ${TARGETS:-(oförändrade)}

  Detta RADERAR all mätdata från "${old_site:-nuvarande plats}":
  grafer, pinglogg, avbrottslogg, MTR-rapporter och felanmälningspaket.

  Spara först det du vill behålla, t.ex.:
    netdiag-export "$(date -d '-7 days' +%F) 00:00" "$(date +%F) 23:59"

EOF
read -r -p "Skriv RADERA för att fortsätta: " ans
[[ "$ans" == "RADERA" ]] || { echo "Avbrutet – inget ändrat."; exit 1; }

export SITE_NAME
[[ -n "${TARGETS:-}" ]] && export TARGETS
NETMON_ID="$id" bash "$HERE/update-netmon.sh"

echo
echo "==> Nollställer mätdata"
pct exec "$id" -- env LANG=C.UTF-8 LC_ALL=C.UTF-8 netdiag-reset

cat <<EOF

=============================================================
 Klar för $SITE_NAME.
 Ladda om Grafana – graferna börjar om från noll.
=============================================================
EOF
