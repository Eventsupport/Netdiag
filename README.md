# netdiag

Nätverksdiagnostik hos kund: en liten Proxmox-box som sitter direkt på kundens internetanslutning och mäter linjen dygnet runt. Resultatet används för att se var på vägen det tar stopp, och som underlag vid felanmälan till operatören (t.ex. Telia).

## Arkitektur

```
 Internet / operatörens CPE
            │  (en IP-adress, DHCP)
   ┌────────┴─────────────────────────────────────┐
   │ Proxmox VE 9  –  vmbr0 (WAN)                 │
   │   nftables: allt inkommande blockerat        │
   │   Tailscale: admin + subnet route            │
   │                                              │
   │   vmbr1 172.30.N.1/24 (internt, NAT)         │
   │     ├─ CT 110  uptime-kuma  172.30.N.10:3001 │
   │     └─ CT 120  netmon       172.30.N.20      │
   │          network_exporter  :9427  (ICMP/MTR) │
   │          Prometheus        :9090  (90 dagar) │
   │          Grafana           :3000             │
   │          netdiag-skript    (rapporter)       │
   └──────────────────────────────────────────────┘
```

- Boxen tar **bara en IP-adress** från kundens anslutning. Allt annat ligger virtuellt bakom NAT.
- **Ingen tjänst nås från internet.** Administration sker via Tailscale.
- Mätningen görs direkt på linjen, utan egen router emellan. Då finns ingen egen utrustning som operatören kan skylla på.

## Ny box från början

1. **Installera Proxmox VE 9** från ISO.
   - Hostname: `netdiagN.example.com`, där N är boxens nummer.
   - Ge boxen en tillfällig statisk IP på ditt eget nät.
2. **Hämta repot** till värden:
   ```
   # Enterprise-källorna kräver licens och stoppar apt – stäng av dem först
   cd /etc/apt/sources.list.d
   for f in pve-enterprise.sources ceph.sources; do [ -f "$f" ] && mv "$f" "$f.disabled"; done
   apt-get update && apt-get install -y git tmux
   git clone https://github.com/Eventsupport/Netdiag.git /root/netdiag
   ```
3. **Kör bootstrap**:
   ```
   cd /root/netdiag/scripts
   ADMIN_NET=192.168.1.0/24 SITE_NAME="netdiag3" bash bootstrap-netdiag.sh
   ```
   - Logga in i Tailscale via länken som skriptet visar.
   - När brandväggen slås på: öppna en ny anslutning och skriv `JA` inom 2 minuter. Annars tas reglerna bort automatiskt.
4. **Godkänn subnet-routen** `172.30.N.0/24` för boxen i Tailscale-konsolen.
5. **Starta om** (`reboot`). Bootstrap har ställt om `vmbr0` till DHCP, och det gäller från omstarten. Därefter når du boxen via Tailscale.
6. **Före leverans till kund:**
   - Kör `bash bootstrap-netdiag.sh` igen **utan** `ADMIN_NET`. Det stänger admin-åtkomsten från ditt lokala nät.
   - Testa från ett annat nät: `nmap -Pn <publik-ip>`. Allt ska visas som filtered.

### Internt nät per box

Varje box har ett eget internt nät, `172.30.N.0/24`, där **N är numret i värdnamnet**. `netdiag3` får alltså `172.30.3.0/24`. Det ger två fördelar:

- Varje box har en unik subnet-route i Tailscale, så flera boxar krockar inte med varandra.
- Det interna nätet krockar inte med vanliga hemma- och företagsnät som 10.10.10.x eller 192.168.x.

Om nätet ändå krockar med kundens nät avbryter skriptet. Välj då ett annat nät med `LAN_PREFIX=…`.

| Box | Internt nät | netmon / Grafana | Uptime Kuma |
|---|---|---|---|
| netdiag3 | 172.30.3.0/24 | http://172.30.3.20:3000 | http://172.30.3.10:3001 |

### Nätverk: alltid DHCP

Boxen tar alltid IP via DHCP på `vmbr0`, både direkt mot internet och på kundens LAN. Du behöver inte göra någon inställning på plats. Värdnamnet pekar på den interna adressen `172.30.N.1` i `/etc/hosts`, så Proxmox påverkas inte när IP-adressen ändras. Brandväggen fungerar likadant i båda fallen: inget inkommande släpps in från `vmbr0`, varken från internet eller från kundens nät.

### Variabler till bootstrap-netdiag.sh

| Variabel | Standard | Beskrivning |
|---|---|---|
| `SITE_NAME` | hostname | Visas i rapporterna |
| `ADMIN_NET` | – | Tillfälligt tillåtet admin-nät under uppsättning |
| `KUMA_BACKUP` | – | vzdump-fil med Uptime Kuma som ska återställas |
| `EXTRA_TARGETS` | – | Extra mätmål, t.ex. kundens router eller operatörens första hopp |
| `WAN_DHCP` | `1` | `0` = behåll statisk IP på vmbr0 |
| `BOX_ID` | siffran i värdnamnet | Boxnummer N, avgör det interna nätet |
| `LAN_PREFIX` | `172.30` | Internt nät blir `LAN_PREFIX.N.0/24` |

Skriptet kan köras flera gånger. Steg som redan är gjorda hoppas över.

## Felanmälan

Boxen sparar automatiskt:

- **Varje minut:** 20 ping per mål, loggat till `/var/lib/netdiag/ping.csv`.
- **Varje timme:** MTR-rapport i textformat med 100 paket per hopp.
- **Vid förlust ≥ 5 %:** en extra MTR direkt.

Skapa ett paket för ett tidsintervall:

```
pct exec 120 -- netdiag-report "2026-11-25 08:00" "2026-11-25 12:00"
pct pull 120 /var/lib/netdiag/export/<fil>.zip ./<fil>.zip
```

Zip-filen innehåller:

- `SAMMANFATTNING.txt`: förlust och latens per mål, samt de minuter som hade förlust.
- Alla MTR-rapporter från perioden.
- Pingloggen.

Bifoga den direkt i felanmälan.

Kör en MTR manuellt: `pct exec 120 -- netdiag-mtr manual 8.8.8.8`

**Tolkning:** Förlust på ett hopp i mitten som *inte* fortsätter till senare hopp beror nästan alltid på att routern begränsar ICMP-svar. Det är inget fel. Förlust som börjar på ett visst hopp och fortsätter hela vägen till målet visar var problemet ligger.

## Filer

| Fil | Körs på | Gör |
|---|---|---|
| `scripts/bootstrap-netdiag.sh` | Proxmox-värden | Repos, uppdatering, vmbr1/NAT, Tailscale, LXC:er, brandvägg |
| `scripts/setup-netmon.sh` | I netmon-LXC:n (anropas av bootstrap) | network_exporter, Prometheus, Grafana, netdiag-skript |

## Att göra

- [ ] Grafana-dashboard för latens/förlust per hopp (kräver mätvärdesnamn från en körande box)
- [ ] Schemalagda hastighetstester
- [ ] Central översikt över alla boxar
