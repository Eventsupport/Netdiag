#!/usr/bin/env bash
# =============================================================================
# update-netmon.sh – uppdaterar en befintlig netdiag-box efter "git pull"
#
# Körs som root på Proxmox-värden:
#   cd /root/netdiag && git pull && bash scripts/update-netmon.sh
#
# Byta mätmål (ersätter hela listan):
#   TARGETS="192.168.1.1 100.67.232.1 1.1.1.1 8.8.8.8 dns.google" bash scripts/update-netmon.sh
# Byta platsnamn:
#   SITE_NAME="Kund AB Ort" bash scripts/update-netmon.sh
# Hastighetstest (off | hourly | 3h | OnCalendar):
#   SPEEDTEST_SCHEDULE=3h bash scripts/update-netmon.sh
#
# - Kör om setup-netmon.sh i netmon-LXC:n med befintliga mätmål/platsnamn
# - Installerar/uppdaterar Grafana-dashboards från grafana/
# - Uppdaterar sysctl-inställningar på värden
# Rör inte nätverk, brandvägg eller Tailscale.
# =============================================================================
set -euo pipefail
NETMON_ID="${NETMON_ID:-$(pct list | awk 'NR>1 && $NF ~ /^netmon(-|$)/ {print $1; exit}')}"
HERE="$(cd "$(dirname "$0")" && pwd)"
[[ $EUID -eq 0 ]] || { echo "Kör som root." >&2; exit 1; }
[[ -n "$NETMON_ID" ]] && pct status "$NETMON_ID" >/dev/null 2>&1 || { echo "Hittar ingen netmon-container (pct list)." >&2; exit 1; }

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
site="${SITE_NAME:-$(sed -nE 's/^SITE_NAME="(.*)"$/\1/p' <<<"$conf")}"
targets="${TARGETS:-$(sed -nE 's/^TARGETS="(.*)"$/\1/p' <<<"$conf")}"
speed="${SPEEDTEST_SCHEDULE:-$(sed -nE 's/^SPEEDTEST_SCHEDULE="(.*)"$/\1/p' <<<"$conf")}"
echo "   Plats: $site"
echo "   Mål:   $targets"

echo "==> Kopierar filer"
pct push "$NETMON_ID" "$HERE/setup-netmon.sh" /root/setup-netmon.sh
pct exec "$NETMON_ID" -- mkdir -p /root/netdiag-dashboards
for d in "$HERE"/../grafana/*.json; do
  [[ -f "$d" ]] && pct push "$NETMON_ID" "$d" "/root/netdiag-dashboards/$(basename "$d")"
done
pct push "$NETMON_ID" "$HERE/netdiag-web.py" /root/netdiag-web.py
install -m 0755 "$HERE/netdiag-export.sh" /usr/local/bin/netdiag-export
install -m 0755 "$HERE/netmon.sh" /usr/local/bin/netmon
TZ_NAME="$(timedatectl show -p Timezone --value 2>/dev/null || echo Europe/Stockholm)"

echo "==> Kör setup-netmon.sh"
pct exec "$NETMON_ID" -- env PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LANG=C.UTF-8 LC_ALL=C.UTF-8 NETMON_ID="$NETMON_ID" TZ_NAME="$TZ_NAME" SITE_NAME="$site" TARGETS="$targets" EXTRA_TARGETS="" SPEEDTEST_SCHEDULE="${speed:-hourly}" \
  bash /root/setup-netmon.sh
