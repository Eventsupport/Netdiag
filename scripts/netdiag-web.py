#!/usr/bin/env python3
"""netdiag-web – liten webbsida i netmon-LXC:n för felanmälningspaket.

  /                         formulär, senaste avbrott och tidigare paket
  /report?from=..&to=..     skapar paket och laddar ner zip-filen
                            from/to: millisekunder (Grafanas ${__from}/${__to})
                            eller "ÅÅÅÅ-MM-DDTHH:MM" (formuläret)
  /export/<fil>.zip         hämtar ett tidigare skapat paket
  /events                   hela avbrottsloggen som text

Nås bara internt / via Tailscale (brandväggen på värden släpper inget utifrån).
"""
import datetime
import html
import os
import re
import subprocess
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DATA = os.environ.get("NETDIAG_DATA", "/var/lib/netdiag")
EXPORT = os.path.join(DATA, "export")
EVENTS = os.path.join(DATA, "events.log")
REPORT = os.environ.get("NETDIAG_REPORT", "/usr/local/bin/netdiag-report")
PORT = int(os.environ.get("NETDIAG_WEB_PORT", "8080"))
MAX_DAYS = 31

CSS = """body{font-family:system-ui,sans-serif;margin:2rem;max-width:60rem;color:#222}
h1{font-size:1.4rem}h2{font-size:1.1rem;margin-top:2rem}
input,button{font-size:1rem;padding:.3rem .5rem}button{cursor:pointer}
pre{background:#f4f4f4;padding:.8rem;overflow-x:auto;font-size:.85rem}
.err{color:#b00}td{padding:.2rem .8rem .2rem 0}"""


def parse_time(v):
    v = (v or "").strip()
    if re.fullmatch(r"\d{12,14}", v):                      # ms från Grafana
        return datetime.datetime.fromtimestamp(int(v) / 1000)
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2})?", v):
        return datetime.datetime.fromisoformat(v.replace(" ", "T"))
    raise ValueError(f"Ogiltig tid: {v!r}")


def site_name():
    try:
        with open("/etc/netdiag.conf", encoding="utf-8") as f:
            m = re.search(r'^SITE_NAME="(.*)"$', f.read(), re.M)
            return m.group(1) if m else "netdiag"
    except OSError:
        return "netdiag"


def tail(path, n):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.readlines()[-n:]
    except OSError:
        return []


class Handler(BaseHTTPRequestHandler):
    server_version = "netdiag-web"

    def log_message(self, fmt, *args):  # tyst – systemd-journalen räcker
        pass

    def send(self, code, body, ctype="text/html; charset=utf-8", extra=None):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def page(self, body, code=200):
        self.send(code, f"<!doctype html><html lang='sv'><head><meta charset='utf-8'>"
                        f"<title>netdiag – {html.escape(site_name())}</title><style>{CSS}</style>"
                        f"</head><body>{body}</body></html>")

    def send_zip(self, path):
        with open(path, "rb") as f:
            data = f.read()
        name = os.path.basename(path)
        self.send(200, data, "application/zip",
                  {"Content-Disposition": f'attachment; filename="{name}"'})

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        try:
            if u.path == "/":
                return self.index()
            if u.path == "/report":
                return self.report(q.get("from", [""])[0], q.get("to", [""])[0])
            if u.path.startswith("/export/"):
                name = os.path.basename(urllib.parse.unquote(u.path))
                path = os.path.join(EXPORT, name)
                if name.endswith(".zip") and os.path.isfile(path):
                    return self.send_zip(path)
                return self.page("<p class='err'>Filen finns inte.</p>", 404)
            if u.path == "/events":
                return self.send(200, "".join(tail(EVENTS, 100000)) or "Inga avbrott loggade.\n",
                                 "text/plain; charset=utf-8")
            return self.page("<p class='err'>Sidan finns inte.</p>", 404)
        except ValueError as e:
            return self.page(f"<p class='err'>{html.escape(str(e))}</p><p><a href='/'>Tillbaka</a></p>", 400)

    def report(self, f, t):
        start, end = parse_time(f), parse_time(t)
        if end <= start:
            raise ValueError("Sluttiden måste vara efter starttiden.")
        if end - start > datetime.timedelta(days=MAX_DAYS):
            raise ValueError(f"Perioden får vara högst {MAX_DAYS} dagar.")
        fmt = "%Y-%m-%d %H:%M:%S"
        r = subprocess.run([REPORT, start.strftime(fmt), end.strftime(fmt)],
                           capture_output=True, text=True, timeout=300)
        m = re.search(r"^Klart: (.+\.zip)$", r.stdout, re.M)
        path = m.group(1).strip() if m else ""
        if r.returncode != 0 or not path.startswith(EXPORT + "/") or not os.path.isfile(path):
            raise ValueError("Kunde inte skapa paketet: " + (r.stderr or r.stdout).strip()[-500:])
        return self.send_zip(path)

    def index(self):
        now = datetime.datetime.now().replace(second=0, microsecond=0)
        dfmt = "%Y-%m-%dT%H:%M"
        ev = [l.rstrip("\n") for l in tail(EVENTS, 400) if "SVARAR IGEN" in l or "INGET SVAR" in l][-30:]
        try:
            zips = sorted((n for n in os.listdir(EXPORT) if n.endswith(".zip")),
                          key=lambda n: os.path.getmtime(os.path.join(EXPORT, n)), reverse=True)[:20]
        except OSError:
            zips = []
        rows = "".join(f"<tr><td><a href='/export/{urllib.parse.quote(n)}'>{html.escape(n)}</a></td></tr>"
                       for n in zips) or "<tr><td>Inga paket skapade än.</td></tr>"
        body = f"""
<h1>netdiag – {html.escape(site_name())}</h1>
<h2>Skapa felanmälningspaket</h2>
<form action="/report" method="get">
  Från <input type="datetime-local" name="from" value="{(now - datetime.timedelta(hours=24)).strftime(dfmt)}" required>
  till <input type="datetime-local" name="to" value="{now.strftime(dfmt)}" required>
  <button type="submit">Skapa och ladda ner</button>
</form>
<p>Zip-filen innehåller sammanfattning, avbrottslogg, MTR-rapporter och pinglogg.
Tips: i Grafana kan du zooma in på en incident och använda länken
<i>Felanmälningspaket för vald period</i> uppe till höger.</p>
<h2>Senaste avbrott</h2>
<pre>{html.escape(chr(10).join(ev)) or "Inga avbrott loggade."}</pre>
<p><a href="/events">Hela avbrottsloggen</a></p>
<h2>Tidigare paket</h2>
<table>{rows}</table>"""
        return self.page(body)


if __name__ == "__main__":
    os.makedirs(EXPORT, exist_ok=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
