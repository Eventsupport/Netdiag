#!/usr/bin/env bash
# =============================================================================
# update-netmon.sh – uppdaterar en befintlig netdiag-box efter "git pull"
#
# Körs som root på Proxmox-värden:
#   cd /root/netdiag && git pull && bash scripts/update-netmon.sh
#
# - Kör om setup-netmon.sh i netmon-LXC:n med befintliga mätmål/platsnamn
# - Installerar/uppdaterar Grafana-dashboards från grafana/
# - Uppdaterar sysctl-inställningar på värden
# Rör inte nätverk, brandvägg eller Tailscale.
# =============================================================================
set -euo pipefail
NETMON_ID="${NETMON_ID:-120}"
HERE="$(cd "$(dirname "$0")" && pwd)"
[[ $EUID -eq 0 ]] || { echo "Kör som root." >&2; exit 1; }
pct status "$NETMON_ID" >/dev/null 2>&1 || { echo "CT $NETMON_ID finns inte." >&2; exit 1; }

echo "==> sysctl på värden"
f=/etc/sysctl.d/99-netdiag.conf
grep -q icmp_ratelimit "$f" 2>/dev/null || cat >> "$f" <<'EOF'
# Ingen gräns för ICMP-felsvar (time-exceeded) från värden. Annars ser
# hopp 1 i MTR ut att tappa paket, vilket ger missvisande underlag.
net.ipv4.icmp_ratelimit = 0
net.ipv6.icmp.ratelimit = 0
EOF
sysctl --system >/dev/null

echo "==> Läser befintlig konfiguration från CT $NETMON_ID"
conf="$(pct exec "$NETMON_ID" -- cat /etc/netdiag.conf)"
site="$(sed -nE 's/^SITE_NAME="(.*)"$/\1/p' <<<"$conf")"
targets="$(sed -nE 's/^TARGETS="(.*)"$/\1/p' <<<"$conf")"
echo "   Plats: $site"
echo "   Mål:   $targets"

echo "==> Kopierar filer"
pct push "$NETMON_ID" "$HERE/setup-netmon.sh" /root/setup-netmon.sh
pct exec "$NETMON_ID" -- mkdir -p /root/netdiag-dashboards
for d in "$HERE"/../grafana/*.json; do
  [[ -f "$d" ]] && pct push "$NETMON_ID" "$d" "/root/netdiag-dashboards/$(basename "$d")"
done

echo "==> Kör setup-netmon.sh"
pct exec "$NETMON_ID" -- env SITE_NAME="$site" TARGETS="$targets" EXTRA_TARGETS="" \
  bash /root/setup-netmon.sh
