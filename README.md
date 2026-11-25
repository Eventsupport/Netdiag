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
   - Hostname: `netdiagN.example.com`, där N är boxens nummer. Numret bestämmer det interna nätet.
   - Ge boxen en tillfällig statisk IP på ditt eget nät.
2. **Hämta repot** till värden:
   ```
   # Enterprise-källorna kräver licens och stoppar apt – stäng av dem först
   cd /etc/apt/sources.list.d
   for f in pve-enterprise.sources ceph.sources; do [ -f "$f" ] && mv "$f" "$f.disabled"; done
   apt-get update && apt-get install -y git tmux
   git clone https://github.com/Eventsupport/Netdiag.git /root/netdiag
   ```
3. **Kör bootstrap i tmux**, så att den överlever om SSH tappar anslutningen. Återanslut med `tmux attach -t setup`.
   ```
   tmux new -s setup
   cd /root/netdiag/scripts
   ADMIN_NET=10.10.10.0/23 bash bootstrap-netdiag.sh 2>&1 | tee /root/bootstrap.log
   ```
   - `ADMIN_NET` är nätet du sitter på, med rätt nätmask. 255.255.254.0 motsvarar /23.
   - **Tailscale:** öppna länken som visas och logga in. Tryck *inte* Ctrl+C, för skriptet fortsätter av sig självt.
   - **Brandväggen:** öppna en ny SSH-anslutning. Om den fungerar skriver du `JA` inom 2 minuter. Annars tas reglerna bort automatiskt.
   - Om något stoppar: rätta felet och kör samma kommando igen. Steg som redan är klara hoppas över.
4. **Godkänn subnet-routen** `172.30.N.0/24` för boxen i Tailscale-konsolen (*Machines → boxen → Edit route settings*).
5. **Grafana:** öppna `http://172.30.N.20:3000` och logga in med admin/admin. Byt lösenord när du blir ombedd.
6. **Starta om** (`reboot`). `vmbr0` går då över till DHCP och kan få en ny adress. Anslut därefter via Tailscale (`ssh root@netdiagN`). Kontrollera:
   ```
   pct status 120                          # running
   pct exec 120 -- systemctl --failed      # 0 loaded units listed
   ```
7. **Före leverans till kund:** ta bort admin-undantaget för ditt lokala nät. Efter det fungerar bara Tailscale.
   ```
   sed -i '/TILLFÄLLIG/d' /etc/nftables.conf && nft -f /etc/nftables.conf
   ```
   Testa från ett annat nät: `nmap -Pn <publik-ip>`. Alla portar ska visas som filtered.

Allt startar automatiskt vid omstart: brandvägg, Tailscale, netmon-containern och alla tjänster i den.

### Standardmål

`1.1.1.1 8.8.8.8 9.9.9.9 ping.sunet.se teliaplay.se`. Lägg till kundens router och operatörens första hopp med `EXTRA_TARGETS="…"` vid bootstrap, eller byt mål senare med `update-netmon.sh` (se nedan).

### Internt nät per box

Varje box har ett eget internt nät, `172.30.N.0/24`, där **N är numret i värdnamnet**. `netdiag3` får alltså `172.30.3.0/24`. Det ger två fördelar:

- Varje box har en unik subnet-route i Tailscale, så flera boxar krockar inte med varandra.
- Det interna nätet krockar inte med vanliga hemma- och företagsnät som 10.10.10.x eller 192.168.x.

Om nätet ändå krockar med kundens nät avbryter skriptet. Välj då ett annat nät med `LAN_PREFIX=…`.

| Adress | Tjänst |
|---|---|
| 172.30.N.1 | Proxmox-värden (https://…:8006) |
| 172.30.N.10 | Uptime Kuma, om den återställts med `KUMA_BACKUP` |
| 172.30.N.20:3000 | Grafana |
| 172.30.N.20:8080 | Felanmälningspaket och avbrottslogg |

### Nätverk: alltid DHCP

Boxen tar alltid IP via DHCP på `vmbr0`, både direkt mot internet och på kundens LAN. Du behöver inte göra någon inställning på plats. Värdnamnet pekar på den interna adressen `172.30.N.1` i `/etc/hosts`, så Proxmox påverkas inte när IP-adressen ändras. Brandväggen fungerar likadant i båda fallen: inget inkommande släpps in från `vmbr0`, varken från internet eller från kundens nät.

### Variabler till bootstrap-netdiag.sh

| Variabel | Standard | Beskrivning |
|---|---|---|
| `SITE_NAME` | hostname | Visas i rapporterna |
| `ADMIN_NET` | – | Tillfälligt tillåtet admin-nät under uppsättning |
| `TARGETS` | se Standardmål | Ersätt standardmålen helt |
| `KUMA_BACKUP` | – | vzdump-fil med Uptime Kuma som ska återställas |
| `EXTRA_TARGETS` | – | Mätmål utöver standardmålen, t.ex. kundens router eller operatörens första hopp |
| `WAN_DHCP` | `1` | `0` = behåll statisk IP på vmbr0 |
| `BOX_ID` | siffran i värdnamnet | Boxnummer N, avgör det interna nätet |
| `LAN_PREFIX` | `172.30` | Internt nät blir `LAN_PREFIX.N.0/24` |

Skriptet kan köras flera gånger. Steg som redan är gjorda hoppas över.

## Felanmälan

Boxen sparar automatiskt:

- **Varje minut:** 20 ping per mål, loggat till `/var/lib/netdiag/ping.csv`.
- **Varje timme:** MTR-rapport i textformat med 100 paket per hopp.
- **Vid förlust ≥ 5 %:** en extra MTR direkt.

- **Hela tiden:** en pingvakt per mål skickar 1 ping/s. Den loggar varje gång målet slutar svara och när det svarar igen, med datum, tid och längd. Loggen finns i `/var/lib/netdiag/events.log`.

Visa avbrottsloggen:

```
pct exec 120 -- netdiag-events                 # alla avbrott
pct exec 120 -- netdiag-events ping.sunet.se   # ett mål
pct exec 120 -- netdiag-events -f              # följ live
```

Exempel:

```
2026-11-25 21:20:02  ping.sunet.se       INGET SVAR
2026-11-25 21:20:05  ping.sunet.se       SVARAR IGEN  avbrott 2026-11-25 21:20:02 – 2026-11-25 21:20:05, 3 paket utan svar (3 s)
```

Skapa ett felanmälningspaket. Det finns tre sätt:

1. **Från Grafana.** Zooma in på perioden i dashboarden och klicka på länken **Felanmälningspaket för vald period (zip)** uppe till höger. Zip-filen laddas ner direkt.
2. **Från webbsidan** `http://172.30.N.20:8080/`. Välj från och till. Där finns också de senaste avbrotten och tidigare skapade paket.
3. **Från terminalen** på värden:
   ```
   netdiag-export "08:00" "12:00"                       # idag
   netdiag-export "2026-11-25 08:00" "2026-11-26 12:00"
   ```
   Zip-filen hamnar i `/root`. Hämta den med WinSCP eller `pscp`.

Webbsidan nås bara internt och via Tailscale. Allt annat stoppas av brandväggen.

Zip-filen innehåller:

- `SAMMANFATTNING.txt`: alla avbrott, förlust och latens per mål, samt de minuter som hade förlust.
- `avbrott.log`: pingvaktens logg för perioden.
- Alla MTR-rapporter från perioden.
- Pingloggen.

Bifoga den direkt i felanmälan.

Kör en MTR manuellt: `pct exec 120 -- netdiag-mtr manual 8.8.8.8`

**Tolkning:** Förlust på ett hopp i mitten som *inte* fortsätter till senare hopp beror nästan alltid på att routern begränsar ICMP-svar. Det är inget fel. Förlust som börjar på ett visst hopp och fortsätter hela vägen till målet visar var problemet ligger.

## Uppdatera en befintlig box

```
cd /root/netdiag && git pull && bash scripts/update-netmon.sh
```

### Byta mätmål

Listan ersätts helt med de mål du anger. Både IP-adresser och värdnamn fungerar.

```
TARGETS="192.168.1.1 100.67.232.1 1.1.1.1 8.8.8.8" bash scripts/update-netmon.sh
```

Bra mål att ha med:

- **Kundens router.** Visar om felet ligger i kundens eget LAN.
- **Operatörens första hopp.** Det är den första publika eller CGNAT-adressen i en MTR-rapport. Visar om felet ligger i accessnätet.
- **Operatörens DNS och ett par stora mål**, t.ex. 1.1.1.1 och 8.8.8.8. Visar om felet ligger längre ut.

Grafana har också dashboarden **netdiag – Hjälp och kommandon**, med alla kommandon från detta README färdiga att kopiera. Den nås via länken **Hjälp och kommandon** i huvuddashboarden.

Grafana: mappen **netdiag** → **netdiag – MTR per hopp**. Där finns en sektion per mål med:

- en hopptabell för vald period, som i PingPlotter, med IP-adress och namn (omvänd DNS) per hopp
- slutmålets latens och förlust
- latens per hopp och förlust per hopp över tid
- antal skickade, mottagna och tappade paket för perioden, och per minut
- antal hopp, som visar när vägen byts

## Filer

| Fil | Körs på | Gör |
|---|---|---|
| `scripts/bootstrap-netdiag.sh` | Proxmox-värden | Repos, uppdatering, vmbr1/NAT, Tailscale, LXC:er, brandvägg |
| `scripts/setup-netmon.sh` | I netmon-LXC:n (anropas av bootstrap) | network_exporter, Prometheus, Grafana, netdiag-skript |
| `scripts/netdiag-export.sh` | Proxmox-värden (som `netdiag-export`) | Skapar felanmälningspaket och lägger det i /root |
| `scripts/netdiag-web.py` | I netmon-LXC:n (port 8080) | Webbsida för felanmälningspaket och avbrottslogg |
| `scripts/update-netmon.sh` | Proxmox-värden | Uppdaterar en befintlig box efter `git pull` (behåller mätmål) |
| `grafana/*.json` | – | Dashboards som installeras automatiskt i Grafana |

## Att göra

- [x] Grafana-dashboard för latens/förlust per hopp
- [ ] Schemalagda hastighetstester
- [ ] Central översikt över alla boxar
