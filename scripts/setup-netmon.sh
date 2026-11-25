#!/usr/bin/env bash
# =============================================================================
# netdiag / netmon – installation i en LXC (Debian 12 eller 13)
#
# Installerar:
#   - network_exporter  (kontinuerlig ICMP + MTR per hopp -> Prometheus)
#   - Prometheus        (lagrar historik, standard 90 dagar)
#   - Grafana           (grafer, http://<ip>:3000, admin/admin första gången)
#   - netdiag-skript    (minutlig pinglogg, MTR-rapporter i textformat,
#                        automatisk MTR vid paketförlust, felanmälningspaket)
#
# Körs som root i containern:
#   SITE_NAME="Kund AB Göteborg" EXTRA_TARGETS="192.168.1.1" bash setup-netmon.sh
# =============================================================================
set -euo pipefail

SITE_NAME="${SITE_NAME:-netdiag2}"
TARGETS="${TARGETS:-1.1.1.1 8.8.8.8 9.9.9.9 ping.sunet.se teliaplay.se}"
EXTRA_TARGETS="${EXTRA_TARGETS:-}"      # t.ex. kundens router och Telias första hopp
RETENTION_DAYS="${RETENTION_DAYS:-90}"
LOSS_THRESHOLD="${LOSS_THRESHOLD:-5}"   # % förlust som utlöser en incident-MTR
MTR_COUNT="${MTR_COUNT:-100}"
MTR_INTERVAL="${MTR_INTERVAL:-0.5}"
DATA="/var/lib/netdiag"

[[ $EUID -eq 0 ]] || { echo "Kör skriptet som root." >&2; exit 1; }

# Samma tidszon som värden – annars får loggar och rapporter fel klockslag.
TZ_NAME="${TZ_NAME:-Europe/Stockholm}"
if [[ -f "/usr/share/zoneinfo/$TZ_NAME" ]]; then
  ln -sf "/usr/share/zoneinfo/$TZ_NAME" /etc/localtime
  echo "$TZ_NAME" > /etc/timezone
  echo "==> Tidszon: $TZ_NAME"
fi
ALL_TARGETS="$(echo $TARGETS $EXTRA_TARGETS)"

echo "==> Installerar paket"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg jq mtr-tiny iputils-ping prometheus tar gzip zip util-linux gawk \
  python3 tzdata

# -----------------------------------------------------------------------------
echo "==> Installerar network_exporter"
case "$(dpkg --print-architecture)" in
  amd64) pat='(x86_64|amd64)';;
  arm64) pat='(arm64|aarch64)';;
  *) echo "Okänd arkitektur" >&2; exit 1;;
esac
url="$(curl -fsSL https://api.github.com/repos/syepes/network_exporter/releases/latest \
  | jq -r '.assets[].browser_download_url' \
  | grep -i linux | grep -iE "$pat" | grep -E '\.(tar\.gz|zip)$' | head -n1 || true)"
[[ -n "$url" ]] || { echo "Hittade ingen network_exporter-release för Linux." >&2; exit 1; }
tmp="$(mktemp -d)"
curl -fsSL "$url" -o "$tmp/pkg"
if [[ "$url" == *.zip ]]; then
  apt-get install -y --no-install-recommends unzip
  unzip -q "$tmp/pkg" -d "$tmp/x"
else
  mkdir -p "$tmp/x"; tar -xzf "$tmp/pkg" -C "$tmp/x"
fi
bin="$(find "$tmp/x" -type f -name network_exporter | head -n1)"
[[ -n "$bin" ]] || { echo "Binären network_exporter saknas i arkivet." >&2; exit 1; }
install -m 0755 "$bin" /usr/local/bin/network_exporter
rm -rf "$tmp"

install -d /etc/network_exporter
{
  cat <<'EOF'
conf:
  refresh: 15m
  nameserver_timeout: 250ms

icmp:
  interval: 3s
  timeout: 1s
  count: 6

mtr:
  interval: 10s
  timeout: 500ms
  max-hops: 30
  count: 10

tcp:
  interval: 3s
  timeout: 1s

http_get:
  interval: 15m
  timeout: 5s

targets:
EOF
  for t in $ALL_TARGETS; do
    cat <<EOF
  - name: ${t}-icmp
    host: ${t}
    type: ICMP
  - name: ${t}-mtr
    host: ${t}
    type: MTR
EOF
  done
} > /etc/network_exporter/network_exporter.yml

cat > /etc/systemd/system/network_exporter.service <<'EOF'
[Unit]
Description=network_exporter (ICMP/MTR till Prometheus)
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=/etc/network_exporter
ExecStart=/usr/local/bin/network_exporter --config.file=/etc/network_exporter/network_exporter.yml --no-ipv6
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# -----------------------------------------------------------------------------
echo "==> Konfigurerar Prometheus"
cat > /etc/prometheus/prometheus.yml <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ['localhost:9090']
  - job_name: network_exporter
    static_configs:
      - targets: ['localhost:9427']
  - job_name: netdiag_web        # omvänd DNS för hopp (netdiag_hop_info)
    scrape_interval: 60s
    static_configs:
      - targets: ['localhost:8080']
EOF
echo "ARGS=\"--storage.tsdb.retention.time=${RETENTION_DAYS}d\"" > /etc/default/prometheus

# -----------------------------------------------------------------------------
echo "==> Installerar Grafana"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
  > /etc/apt/sources.list.d/grafana.list
apt-get update
apt-get install -y grafana
install -d /etc/grafana/provisioning/datasources
cat > /etc/grafana/provisioning/datasources/prometheus.yaml <<'EOF'
apiVersion: 1
deleteDatasources:
  - name: Prometheus
    orgId: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090
    isDefault: true
EOF

# Dashboards: JSON-filer som bootstrap lagt i /root/netdiag-dashboards
install -d /etc/grafana/provisioning/dashboards /var/lib/grafana/dashboards
cat > /etc/grafana/provisioning/dashboards/netdiag.yaml <<'EOF'
apiVersion: 1
providers:
  - name: netdiag
    folder: netdiag
    type: file
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
EOF
if compgen -G "/root/netdiag-dashboards/*.json" >/dev/null; then
  # @NETMON_HOST@ i länkarna ersätts med containerns adress
  host_ip="$(hostname -I | awk '{print $1}')"
  for d in /root/netdiag-dashboards/*.json; do
    sed -e "s/@NETMON_HOST@/${host_ip}/g" -e "s/@NETMON_ID@/${NETMON_ID:-?}/g" "$d" \
      > "/var/lib/grafana/dashboards/$(basename "$d")"
  done
fi
chown -R grafana:grafana /var/lib/grafana/dashboards 2>/dev/null || true

# -----------------------------------------------------------------------------
echo "==> Installerar netdiag-skript"
install -d "$DATA/reports" "$DATA/export"
cat > /etc/netdiag.conf <<EOF
SITE_NAME="${SITE_NAME}"
TARGETS="${ALL_TARGETS}"
RETENTION_DAYS=${RETENTION_DAYS}
LOSS_THRESHOLD=${LOSS_THRESHOLD}
MTR_COUNT=${MTR_COUNT}
MTR_INTERVAL=${MTR_INTERVAL}
DATA="${DATA}"
EOF

# --- Minutlig pingkontroll -> CSV, startar incident-MTR vid förlust ----------
cat > /usr/local/bin/netdiag-pingcheck <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. /etc/netdiag.conf
log="$DATA/ping.csv"
[[ -f "$log" ]] || echo "epoch,tid,mal,skickade,mottagna,forlust_pct,min_ms,avg_ms,max_ms" > "$log"
epoch=$(date +%s); now=$(date -d "@$epoch" -Iseconds)
for t in $TARGETS; do
  out=$(ping -4 -n -q -c 20 -i 0.2 -W 1 "$t" 2>&1)
  sent=$(sed -nE 's/^([0-9]+) packets transmitted, ([0-9]+) (packets )?received.*/\1/p' <<<"$out")
  recv=$(sed -nE 's/^([0-9]+) packets transmitted, ([0-9]+) (packets )?received.*/\2/p' <<<"$out")
  sent=${sent:-20}; recv=${recv:-0}
  loss=$(( (sent - recv) * 100 / sent ))
  mn=""; av=""; mx=""
  read -r mn av mx < <(sed -nE 's#^rtt min/avg/max/mdev = ([0-9.]+)/([0-9.]+)/([0-9.]+)/.*#\1 \2 \3#p' <<<"$out") || true
  echo "$epoch,$now,$t,$sent,$recv,$loss,$mn,$av,$mx" >> "$log"
  if (( loss >= LOSS_THRESHOLD )); then
    systemd-run --quiet --no-block --collect \
      --unit "netdiag-incident-${epoch}-${t//[^a-zA-Z0-9]/_}" \
      /usr/local/bin/netdiag-mtr incident "$t" >/dev/null 2>&1 || true
  fi
done
EOF

# --- MTR-rapport i textformat (det format operatörens support känner igen) ----
cat > /usr/local/bin/netdiag-mtr <<'EOF'
#!/usr/bin/env bash
# Användning: netdiag-mtr [hourly|incident|manual] [mål ...]
set -uo pipefail
. /etc/netdiag.conf
kind="${1:-manual}"; shift || true
targets="${*:-$TARGETS}"
pubip=$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || echo "okänd")
for t in $targets; do
  safe=${t//[^a-zA-Z0-9.-]/_}
  exec 9>"/run/netdiag-mtr-${safe}.lock"
  flock -n 9 || { exec 9>&-; continue; }   # en MTR per mål åt gången
  dir="$DATA/reports/$(date +%F)"; mkdir -p "$dir"
  f="$dir/$(date +%H%M%S)_${kind}_${safe}.txt"
  {
    echo "# netdiag MTR-rapport ($kind)"
    echo "# Plats:     $SITE_NAME"
    echo "# Publik IP: $pubip"
    echo "# Start:     $(date -Iseconds)"
    echo "# Mål:       $t"
    echo "# Kommando:  mtr -4 -r -w -b -c $MTR_COUNT -i $MTR_INTERVAL $t"
    echo
    mtr -4 -r -w -b -c "$MTR_COUNT" -i "$MTR_INTERVAL" "$t" 2>&1
    echo
    echo "# Slut:      $(date -Iseconds)"
  } > "$f"
  exec 9>&-
done
EOF

# --- Felanmälningspaket för ett tidsintervall -------------------------------
cat > /usr/local/bin/netdiag-report <<'EOF'
#!/usr/bin/env bash
# Användning: netdiag-report "2026-11-25 08:00" "2026-11-25 12:00"
set -euo pipefail
. /etc/netdiag.conf
[[ $# -eq 2 ]] || { echo "Användning: netdiag-report \"ÅÅÅÅ-MM-DD HH:MM\" \"ÅÅÅÅ-MM-DD HH:MM\"" >&2; exit 1; }
from=$(date -d "$1" +%s); to=$(date -d "$2" +%s)
name="netdiag_${SITE_NAME//[^a-zA-Z0-9]/_}_$(date -d "@$from" +%Y%m%d-%H%M)_$(date -d "@$to" +%Y%m%d-%H%M)"
work=$(mktemp -d); out="$work/$name"; mkdir -p "$out/mtr"
trap 'rm -rf "$work"' EXIT

head -n1 "$DATA/ping.csv" > "$out/ping.csv"
awk -F, -v f="$from" -v t="$to" 'NR>1 && $1>=f && $1<=t' "$DATA/ping.csv" >> "$out/ping.csv"

find "$DATA/reports" -type f -name '*.txt' -newermt "$1" ! -newermt "$2" -exec cp {} "$out/mtr/" \;

f_s=$(date -d "@$from" '+%F %T'); t_s=$(date -d "@$to" '+%F %T')
touch "$DATA/events.log"
awk -v f="$f_s" -v t="$t_s" '{ s = substr($0,1,19) } s >= f && s <= t' "$DATA/events.log" > "$out/avbrott.log"

{
  echo "NÄTVERKSMÄTNING – UNDERLAG FÖR FELANMÄLAN"
  echo "========================================="
  echo "Plats:        $SITE_NAME"
  echo "Publik IP:    $(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || echo okänd)"
  echo "Period:       $(date -d "@$from" '+%F %H:%M') – $(date -d "@$to" '+%F %H:%M') ($(date +%Z))"
  echo "Metod:        20 ICMP-paket per mål och minut. MTR med $MTR_COUNT paket per hopp"
  echo "              varje timme och automatiskt vid förlust >= ${LOSS_THRESHOLD} %."
  echo
  echo "SAMMANFATTNING PER MÅL"
  printf "%-18s %8s %10s %10s %10s %14s\n" "Mål" "Mätn." "Snittförl%" "Maxförl%" "Snitt ms" "Min. m. förl."
  awk -F, -v th="$LOSS_THRESHOLD" 'NR>1 {
      n[$3]++; s[$3]+=$6; if ($6>m[$3]) m[$3]=$6; if ($6>=th) b[$3]++
      if ($8!="") { ls[$3]+=$8; ln[$3]++ }
    } END {
      for (k in n) printf "%-18s %8d %10.2f %10d %10.1f %14d\n", k, n[k], s[k]/n[k], m[k], (ln[k]?ls[k]/ln[k]:0), b[k]
    }' "$out/ping.csv"
  echo
  echo "AVBROTT (pingvakt, 1 paket/s per mål)"
  if grep -q 'SVARAR IGEN' "$out/avbrott.log"; then
    grep 'SVARAR IGEN' "$out/avbrott.log" | sed 's/^/  /' | head -n 500
  else
    echo "  Inga avbrott under perioden."
  fi
  grep -q 'INGET SVAR' "$out/avbrott.log" && \
    echo "  (Fullständig logg med start och slut: avbrott.log)"
  echo
  echo "MINUTER MED FÖRLUST >= ${LOSS_THRESHOLD} %"
  awk -F, -v th="$LOSS_THRESHOLD" 'NR>1 && $6>=th { printf "  %s  %-16s %3d %% förlust\n", $2, $3, $6 }' "$out/ping.csv" | head -n 500
  echo
  echo "MTR-RAPPORTER I PAKETET: $(ls "$out/mtr" | wc -l) st (katalogen mtr/)"
  echo
  echo "TOLKNING"
  echo "  Förlust på ett mellanliggande hopp som INTE fortsätter till senare hopp"
  echo "  beror normalt på att routern begränsar ICMP-svar och är inget fel."
  echo "  Förlust som syns från ett visst hopp och hela vägen till målet visar"
  echo "  var problemet börjar."
} > "$out/SAMMANFATTNING.txt"

(cd "$work" && zip -qr "$DATA/export/$name.zip" "$name")
echo "Klart: $DATA/export/$name.zip"
EOF

# --- Pingvakt: 1 ping/s per mål, loggar varje avbrott med tid -----------------
cat > /usr/local/bin/netdiag-pingwatch <<'EOF'
#!/usr/bin/env bash
# Körs som tjänst per mål: netdiag-pingwatch@<mål>.service
# Skriver till $DATA/events.log när målet slutar svara och när det svarar igen.
set -uo pipefail
. /etc/netdiag.conf
t="$1"; log="$DATA/events.log"
now() { date '+%F %T'; }
ping -4 -n -D -O -i 1 -W 1 "$t" 2>&1 | gawk -v t="$t" -v logf="$log" '
  function ts(e) { return strftime("%Y-%m-%d %H:%M:%S", e) }
  function out(s) { print s >> logf; fflush(logf) }
  /^\[[0-9.]+\]/ {
    e = substr($1, 2, length($1) - 2) + 0
    if ($0 ~ /no answer yet|[Uu]nreachable|sendmsg/) {
      if (!down) { down = 1; start = e; n = 0
        out(sprintf("%s  %-18s  INGET SVAR", ts(e), t)) }
      n++; next
    }
    if ($0 ~ /bytes from/) {
      if (down) {
        out(sprintf("%s  %-18s  SVARAR IGEN  avbrott %s – %s, %d paket utan svar (%d s)",
                    ts(e), t, ts(start), ts(e), n, int(e - start + 0.5)))
        down = 0
      }
      next
    }
  }
  /^ping: / { out(sprintf("%s  %-18s  FEL  %s", strftime("%Y-%m-%d %H:%M:%S"), t, $0)) }
'
# ping avslutades (t.ex. DNS-fel eller ingen väg ut) – systemd startar om.
echo "$(now)  $(printf '%-18s' "$t")  PINGVAKT STARTAS OM" >> "$log"
exit 1
EOF

cat > /etc/systemd/system/netdiag-pingwatch@.service <<'EOF'
[Unit]
Description=netdiag pingvakt för %i
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/netdiag-pingwatch %i
Restart=always
RestartSec=10
# Starta om dagligen så att värdnamn slås upp på nytt
RuntimeMaxSec=1d

[Install]
WantedBy=multi-user.target
EOF

# --- Webbsida för felanmälningspaket (port 8080) -----------------------------
if [[ -f /root/netdiag-web.py ]]; then
  install -m 0755 /root/netdiag-web.py /usr/local/bin/netdiag-web
  cat > /etc/systemd/system/netdiag-web.service <<'EOF'
[Unit]
Description=netdiag webbsida för felanmälningspaket
After=network-online.target

[Service]
ExecStart=/usr/bin/python3 -I /usr/local/bin/netdiag-web
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
fi

# --- Radera all mätdata (ny kund) ---------------------------------------------
cat > /usr/local/bin/netdiag-reset <<'EOF'
#!/usr/bin/env bash
# Raderar ALL mätdata: Prometheus-historik, pinglogg, avbrottslogg,
# MTR-rapporter och felanmälningspaket. Inställningar och mål behålls.
# Anropas av new-site.sh på värden.
set -euo pipefail
. /etc/netdiag.conf
echo "==> Stoppar mätningar"
systemctl stop netdiag-ping.timer netdiag-mtr.timer prometheus
systemctl stop 'netdiag-pingwatch@*' 2>/dev/null || true
echo "==> Raderar data"
for d in /var/lib/prometheus/metrics2 /var/lib/prometheus/data; do
  [[ -d "$d" ]] && find "$d" -mindepth 1 -delete
done
rm -f "$DATA/ping.csv" "$DATA/events.log"
find "$DATA/reports" "$DATA/export" -mindepth 1 -delete 2>/dev/null || true
echo "==> Startar mätningar"
systemctl start prometheus netdiag-ping.timer netdiag-mtr.timer
systemctl restart netdiag-web network_exporter
for t in $TARGETS; do systemctl start "netdiag-pingwatch@$t.service"; done
echo "All mätdata raderad. Mätningen har börjat om från noll."
EOF

# --- Visa avbrottsloggen ------------------------------------------------------
cat > /usr/local/bin/netdiag-events <<'EOF'
#!/usr/bin/env bash
# Användning: netdiag-events [mål]   |   netdiag-events -f   (följ live)
. /etc/netdiag.conf
log="$DATA/events.log"; [[ -f "$log" ]] || { echo "Inga avbrott loggade än."; exit 0; }
if [[ "${1:-}" == "-f" ]]; then exec tail -n 50 -f "$log"; fi
if [[ -n "${1:-}" ]]; then grep -F "  $1 " "$log"; else cat "$log"; fi
EOF

# --- Städning -----------------------------------------------------------------
cat > /usr/local/bin/netdiag-cleanup <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. /etc/netdiag.conf
find "$DATA/reports" -mindepth 1 -mtime +"$RETENTION_DAYS" -delete
find "$DATA/export" -type f -mtime +"$RETENTION_DAYS" -delete
if [[ -f "$DATA/ping.csv" ]]; then
  cut=$(( $(date +%s) - RETENTION_DAYS*86400 ))
  awk -F, -v c="$cut" 'NR==1 || $1>=c' "$DATA/ping.csv" > "$DATA/ping.csv.tmp" && mv "$DATA/ping.csv.tmp" "$DATA/ping.csv"
fi
if [[ -f "$DATA/events.log" ]]; then
  c=$(date -d "-$RETENTION_DAYS days" '+%F %T')
  awk -v c="$c" 'substr($0,1,19) >= c' "$DATA/events.log" > "$DATA/events.log.tmp" && mv "$DATA/events.log.tmp" "$DATA/events.log"
fi
EOF
chmod 0755 /usr/local/bin/netdiag-*

# --- systemd-timers -----------------------------------------------------------
mk_timer() { # namn, kommando, OnCalendar
  cat > "/etc/systemd/system/$1.service" <<EOF
[Unit]
Description=$1

[Service]
Type=oneshot
ExecStart=$2
EOF
  cat > "/etc/systemd/system/$1.timer" <<EOF
[Unit]
Description=$1

[Timer]
OnCalendar=$3
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
}
mk_timer netdiag-ping    "/usr/local/bin/netdiag-pingcheck"   "*-*-* *:*:00"
mk_timer netdiag-mtr     "/usr/local/bin/netdiag-mtr hourly"  "*-*-* *:05:00"
mk_timer netdiag-cleanup "/usr/local/bin/netdiag-cleanup"     "*-*-* 03:30:00"

# -----------------------------------------------------------------------------
echo "==> Startar tjänster"
systemctl daemon-reload
systemctl enable --now network_exporter prometheus grafana-server
systemctl restart network_exporter prometheus grafana-server
systemctl enable --now netdiag-ping.timer netdiag-mtr.timer netdiag-cleanup.timer

if [[ -f /etc/systemd/system/netdiag-web.service ]]; then
  systemctl enable netdiag-web >/dev/null 2>&1; systemctl restart netdiag-web
fi

# Pingvakter: en per mål, stoppa vakter för mål som tagits bort
for u in $(systemctl list-units --all --plain --no-legend 'netdiag-pingwatch@*' | awk '{print $1}'); do
  inst="${u#netdiag-pingwatch@}"; inst="${inst%.service}"
  [[ " $ALL_TARGETS " == *" $inst "* ]] || systemctl disable --now "$u" >/dev/null 2>&1 || true
done
for t in $ALL_TARGETS; do
  systemctl enable "netdiag-pingwatch@$t.service" >/dev/null 2>&1
  systemctl restart "netdiag-pingwatch@$t.service"
done

ip4=$(hostname -I | awk '{print $1}')
cat <<EOF

=============================================================
 Klart!
 Grafana:          http://${ip4}:3000   (admin / admin)
 Felanmälan:       http://${ip4}:8080
 Prometheus:       http://${ip4}:9090
 network_exporter: http://${ip4}:9427/metrics
 Mål:              ${ALL_TARGETS}

 Felanmälningspaket:
   netdiag-report "$(date +%F) 08:00" "$(date +%F) 12:00"
 MTR direkt:
   netdiag-mtr manual 8.8.8.8
 Avbrottslogg:
   netdiag-events          (alla)   netdiag-events -f   (live)
=============================================================
EOF
