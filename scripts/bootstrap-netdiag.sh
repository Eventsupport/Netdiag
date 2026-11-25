#!/usr/bin/env bash
# =============================================================================
# bootstrap-netdiag.sh – gör en nyinstallerad Proxmox VE 9 till en netdiag-box
#
# Körs som root på värden, med setup-netmon.sh i samma katalog:
#   SITE_NAME="Kund AB Ort" bash bootstrap-netdiag.sh
#
# Valfritt:
#   ADMIN_NET=192.168.1.0/24   tillåt admin från ditt eget nät under uppsättning
#                              (kör om utan ADMIN_NET innan boxen åker till kund)
#   KUMA_BACKUP=/root/vzdump-lxc-XXX.tar.zst   återställ Uptime Kuma
#   EXTRA_TARGETS="192.168.1.1"                extra mätmål till netmon
#   WAN_DHCP=0                 behåll statisk IP på vmbr0 (standard: DHCP)
#   BOX_ID=3                   boxnummer (standard: siffran i värdnamnet)
#   LAN_PREFIX=172.30          internt nät blir LAN_PREFIX.BOX_ID.0/24
#
# Steg: repos -> uppdatering -> vmbr1 -> Tailscale -> LXC:er -> brandvägg
#       -> vmbr0 till DHCP (gäller från nästa omstart)
# =============================================================================
set -euo pipefail

WAN_DHCP="${WAN_DHCP:-1}"
SITE_NAME="${SITE_NAME:-$(hostname -s)}"
ADMIN_NET="${ADMIN_NET:-}"
KUMA_BACKUP="${KUMA_BACKUP:-}"
EXTRA_TARGETS="${EXTRA_TARGETS:-}"
WAN="vmbr0"; LAN="vmbr1"
# Internt nät per box: 172.30.<BOX_ID>.0/24. BOX_ID tas från värdnamnet
# (netdiag3 -> 3) så att varje box får ett unikt nät i Tailscale.
BOX_ID="${BOX_ID:-$(hostname -s | grep -oE '[0-9]+$' || true)}"
LAN_PREFIX="${LAN_PREFIX:-172.30}"
[[ "$BOX_ID" =~ ^[0-9]+$ ]] && (( BOX_ID >= 1 && BOX_ID <= 254 )) || {
  echo "Kan inte avgöra boxnummer från värdnamnet. Ange BOX_ID=N (1–254)." >&2; exit 1; }
LAN_IP="$LAN_PREFIX.$BOX_ID.1"; LAN_NET="$LAN_PREFIX.$BOX_ID.0/24"
NETMON_ID=120; NETMON_IP="$LAN_PREFIX.$BOX_ID.20"
KUMA_ID=110;   KUMA_IP="$LAN_PREFIX.$BOX_ID.10"
HERE="$(cd "$(dirname "$0")" && pwd)"

[[ $EUID -eq 0 ]] || { echo "Kör som root." >&2; exit 1; }
command -v pveversion >/dev/null || { echo "Detta är ingen Proxmox-värd." >&2; exit 1; }
[[ -f "$HERE/setup-netmon.sh" ]] || { echo "setup-netmon.sh saknas i $HERE" >&2; exit 1; }
step() { echo; echo "==> $*"; }

# Avbryt om det interna nätet krockar med nätet utanför (vmbr0).
if ip -4 route show dev "$WAN" 2>/dev/null | grep -q "^$LAN_PREFIX\.$BOX_ID\."; then
  echo "Internt nät $LAN_NET krockar med nätet på $WAN. Välj annat med LAN_PREFIX=…" >&2
  exit 1
fi
# Varna om vmbr1 redan finns med en annan adress.
if grep -q "iface $LAN" /etc/network/interfaces && \
   ! grep -A2 "iface $LAN" /etc/network/interfaces | grep -q "address $LAN_IP/"; then
  echo "$LAN finns redan med en annan adress än $LAN_IP. Ändra/ta bort den först." >&2
  exit 1
fi
echo "Box $BOX_ID – internt nät $LAN_NET"

# -----------------------------------------------------------------------------
step "Paketkällor: no-subscription"
codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
# Enterprise-källorna kräver licens och får apt-get update att fallera.
for f in $(grep -l 'enterprise.proxmox.com' /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list 2>/dev/null); do
  mv "$f" "$f.disabled"; echo "Avaktiverade $(basename "$f")"
done
# Ceph behövs inte, men lägg no-subscription-källan om ceph.sources fanns.
if [[ -f /etc/apt/sources.list.d/ceph.sources.disabled ]] && [[ ! -f /etc/apt/sources.list.d/ceph.sources ]]; then
  suite="$(awk '/^URIs:/{print $2}' /etc/apt/sources.list.d/ceph.sources.disabled | grep -oE 'ceph-[a-z]+' | head -n1)"
  [[ -n "$suite" ]] && cat > /etc/apt/sources.list.d/ceph.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/${suite}
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
fi
cat > /etc/apt/sources.list.d/proxmox.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${codename}
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

step "Uppdaterar systemet"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade
DEBIAN_FRONTEND=noninteractive apt-get -y install nftables curl

step "Stänger av onödiga tjänster"
systemctl disable --now rpcbind.service rpcbind.socket 2>/dev/null || true

cat > /etc/sysctl.d/99-netdiag.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl --system >/dev/null

# -----------------------------------------------------------------------------
step "Internt nät $LAN ($LAN_NET)"
if ! grep -q "iface $LAN" /etc/network/interfaces; then
  cat >> /etc/network/interfaces <<EOF

auto $LAN
iface $LAN inet static
    address $LAN_IP/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOF
  ifreload -a
fi

# NAT behövs redan nu så att containrarna kommer ut under installationen.
# Hela brandväggen läggs på sist.
nft list table ip netdiag_nat >/dev/null 2>&1 || nft -f - <<EOF
table ip netdiag_nat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr $LAN_NET oifname "$WAN" masquerade
  }
}
EOF

# -----------------------------------------------------------------------------
step "Tailscale"
command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
echo "Logga in via länken som visas (om den visas)."
tailscale up --advertise-routes="$LAN_NET" --hostname="$(hostname -s)" --ssh=false
echo "Kom ihåg: godkänn subnet-routen $LAN_NET i Tailscale-konsolen."

# -----------------------------------------------------------------------------
storage="$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 && $3=="active"{print $1; exit}')"
[[ -n "$storage" ]] || { echo "Hittar ingen lagring för containrar." >&2; exit 1; }

if [[ -n "$KUMA_BACKUP" ]] && ! pct status "$KUMA_ID" >/dev/null 2>&1; then
  step "Återställer Uptime Kuma (CT $KUMA_ID)"
  pct restore "$KUMA_ID" "$KUMA_BACKUP" --storage "$storage" --unique 1
  pct set "$KUMA_ID" --net0 "name=eth0,bridge=$LAN,ip=$KUMA_IP/24,gw=$LAN_IP" \
    --nameserver "1.1.1.1 9.9.9.9" --onboot 1
  pct start "$KUMA_ID"
fi

if ! pct status "$NETMON_ID" >/dev/null 2>&1; then
  step "Skapar netmon (CT $NETMON_ID)"
  pveam update >/dev/null
  arch="$(dpkg --print-architecture)"   # amd64 på Intel/AMD
  tmpl="$(pveam available --section system | awk '{print $2}' \
    | grep -E "^debian-13-standard_.*_${arch}\.tar\.(zst|gz|xz)$" | sort -V | tail -n1)"
  [[ -n "$tmpl" ]] || { echo "Hittar ingen Debian 13-mall." >&2; exit 1; }
  pveam list local | grep -q "$tmpl" || pveam download local "$tmpl"
  pct create "$NETMON_ID" "local:vztmpl/$tmpl" \
    --hostname netmon --cores 2 --memory 3072 --swap 512 \
    --rootfs "$storage:32" --unprivileged 1 --features nesting=1 \
    --net0 "name=eth0,bridge=$LAN,ip=$NETMON_IP/24,gw=$LAN_IP" \
    --nameserver "1.1.1.1 9.9.9.9" --onboot 1
  pct start "$NETMON_ID"
  sleep 5
fi

step "Installerar netmon-tjänsterna"
pct push "$NETMON_ID" "$HERE/setup-netmon.sh" /root/setup-netmon.sh
pct exec "$NETMON_ID" -- env SITE_NAME="$SITE_NAME" EXTRA_TARGETS="$EXTRA_TARGETS" \
  bash /root/setup-netmon.sh

# -----------------------------------------------------------------------------
step "Brandvägg"
admin_rule=""
[[ -n "$ADMIN_NET" ]] && admin_rule="iifname \$WAN ip saddr $ADMIN_NET accept   # TILLFÄLLIG"
cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
# netdiag – brandvägg för $(hostname -f). Genererad av bootstrap-netdiag.sh
define WAN     = "$WAN"
define LAN     = "$LAN"
define LAN_NET = $LAN_NET

table inet netdiag_fw
delete table inet netdiag_fw
table inet netdiag_fw {
    chain input {
        type filter hook input priority 0; policy drop;
        ct state established,related accept
        ct state invalid drop
        iif "lo" accept
        iifname "tailscale0" accept
        iifname \$LAN accept
        $admin_rule
        iifname \$WAN udp sport 67 udp dport 68 accept
        meta l4proto ipv6-icmp accept
        icmp type { destination-unreachable, time-exceeded, parameter-problem } accept
        icmp type echo-request limit rate 10/second burst 20 packets accept
        iifname \$WAN udp dport 41641 accept
    }
    chain forward {
        type filter hook forward priority 0; policy drop;
        ct state established,related accept
        ct state invalid drop
        iifname \$LAN oifname \$WAN accept
        iifname "tailscale0" oifname \$LAN accept
    }
    chain output {
        type filter hook output priority 0; policy accept;
    }
}

table ip netdiag_nat
delete table ip netdiag_nat
table ip netdiag_nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr \$LAN_NET oifname \$WAN masquerade
    }
}
EOF
nft -c -f /etc/nftables.conf

# Säkerhetsnät: reglerna tas bort efter 2 minuter om du inte bekräftar.
systemctl stop netdiag-fw-rollback.timer 2>/dev/null || true
systemd-run --quiet --unit netdiag-fw-rollback --on-active=120 \
  /usr/sbin/nft delete table inet netdiag_fw
nft -f /etc/nftables.conf
echo
echo "Brandväggen är aktiv. Öppna en NY anslutning (SSH eller https://...:8006)"
echo "och kontrollera att du kommer åt boxen."
ans=""
read -r -t 110 -p "Fungerar det? Skriv JA inom 110 sekunder: " ans || true
if [[ "$ans" == "JA" ]]; then
  systemctl stop netdiag-fw-rollback.timer
  systemctl enable nftables
  echo "Brandväggen är sparad och startar vid omstart."
else
  echo "Inte bekräftat – reglerna tas bort automatiskt. Kontrollera och kör om."
  exit 1
fi

# -----------------------------------------------------------------------------
dhcp_pending=0
if [[ "$WAN_DHCP" == "1" ]]; then
  step "$WAN till DHCP"
  # Värdnamnet pekar på den interna adressen, som aldrig ändras.
  fqdn="$(hostname -f)"; short="$(hostname -s)"
  sed -i -E "/[[:space:]]${short}([[:space:]]|$)/d" /etc/hosts
  echo "$LAN_IP $fqdn $short" >> /etc/hosts

  if grep -qE "^iface $WAN inet dhcp" /etc/network/interfaces; then
    echo "$WAN använder redan DHCP."
  else
    cp /etc/network/interfaces "/etc/network/interfaces.bak.$(date +%Y%m%d-%H%M%S)"
    awk -v ifc="$WAN" '
      $1=="iface" && $2==ifc && $3=="inet" { print "iface " ifc " inet dhcp"; blk=1; next }
      blk && ($1=="address" || $1=="gateway" || $1=="netmask") { next }
      /^(auto|iface|allow-|source)/ { blk=0 }
      { print }' /etc/network/interfaces > /etc/network/interfaces.new
    mv /etc/network/interfaces.new /etc/network/interfaces
    dhcp_pending=1
    echo "Klart. $WAN tar IP via DHCP från nästa omstart (eller ifreload -a)."
    echo "Den nuvarande IP-adressen slutar då gälla – anslut via Tailscale efteråt."
  fi
fi

cat <<EOF

=============================================================
 $(hostname -f) är klar.
 Proxmox:   https://<tailscale-ip>:8006
 Grafana:   http://$NETMON_IP:3000   (via Tailscale subnet route)
$( [[ -n "$KUMA_BACKUP" ]] && echo " Kuma:      http://$KUMA_IP:3001" )
$( [[ -n "$ADMIN_NET" ]] && echo " OBS: ADMIN_NET är öppet – kör om utan ADMIN_NET före leverans." )
$( [[ "$dhcp_pending" == "1" ]] && echo " OBS: Starta om (reboot) för att $WAN ska gå över till DHCP." )
 Testa utifrån:  nmap -Pn <publik-ip>   (allt ska vara filtered)
=============================================================
EOF
