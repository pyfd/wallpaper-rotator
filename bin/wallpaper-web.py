#!/usr/bin/env python3
# wallpaper-rotator status + control server (localhost only).
#
# Serves the generated status page and the current-wallpaper thumbnail, and
# accepts a small control form (POST /set) to change the rotation interval and
# toggle the quote / system-stats overlays. Controls write the config file that
# set-wallpaper.sh reads, rewrite the rotate line in the user's crontab, apply
# immediately, and regenerate the page.
#
# Bound to 127.0.0.1 — no network exposure, no auth (localhost trust model).
# @@...@@ placeholders are substituted by install.sh; falls back to XDG defaults
# when run from a raw checkout (guarded by the "@@" prefix check, which the
# substitution can't reproduce).
import os, subprocess, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WEBDIR    = "@@WEBDIR@@"
PORT      = "@@PORT@@"
CONFIG    = "@@CONFIG@@"
GENSTATUS = "@@GENSTATUS@@"
SETWP     = "@@SETWP@@"

HOME  = os.path.expanduser("~")
STATE = os.path.join(HOME, ".local/state/wallpaper-rotator")
HERE  = os.path.dirname(os.path.abspath(__file__))
if WEBDIR.startswith("@@"):    WEBDIR    = os.path.join(STATE, "web")
if PORT.startswith("@@"):      PORT      = "8787"
if CONFIG.startswith("@@"):    CONFIG    = os.path.join(STATE, "config")
if GENSTATUS.startswith("@@"): GENSTATUS = os.path.join(HERE, "gen-status.sh")
if SETWP.startswith("@@"):     SETWP     = os.path.join(HERE, "set-wallpaper.sh")
PORT = int(PORT)

ALLOWED_INTERVALS = {"3", "5", "10", "15", "30", "60"}


def read_config():
    cfg = {"INTERVAL_MIN": "10", "OVERLAY_QUOTE": "0", "OVERLAY_STATS": "0"}
    try:
        with open(CONFIG) as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, v = line.split("=", 1)
                    cfg[k.strip()] = v.strip().strip('"')
    except FileNotFoundError:
        pass
    return cfg


def write_config(cfg):
    os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
    with open(CONFIG, "w") as f:
        f.write("# wallpaper-rotator config (managed by wallpaper-web)\n")
        for k in ("INTERVAL_MIN", "OVERLAY_QUOTE", "OVERLAY_STATS"):
            f.write("%s=%s\n" % (k, cfg[k]))


def set_cron_interval(n):
    """Rewrite the schedule of the rotate line (the one running set-wallpaper.sh) to */n."""
    try:
        cur = subprocess.run(["crontab", "-l"], capture_output=True, text=True).stdout
    except Exception:
        return
    out = []
    for line in cur.splitlines():
        if SETWP in line and not line.lstrip().startswith("#"):
            parts = line.split(None, 5)            # min hour dom mon dow command...
            if len(parts) >= 6:
                line = "*/%s * * * * %s" % (n, parts[5])
        out.append(line)
    subprocess.run(["crontab", "-"], input="\n".join(out) + "\n", text=True)


def regen():
    try:
        subprocess.run([GENSTATUS], timeout=30)
    except Exception:
        pass


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/index.html"):
            fn, ctype = os.path.join(WEBDIR, "index.html"), "text/html; charset=utf-8"
        elif path == "/current.jpg":
            fn, ctype = os.path.join(WEBDIR, "current.jpg"), "image/jpeg"
        else:
            self._send(404, "text/plain", b"not found"); return
        try:
            with open(fn, "rb") as f:
                self._send(200, ctype, f.read())
        except FileNotFoundError:
            self._send(404, "text/plain", b"not generated yet")

    def do_POST(self):
        if self.path.split("?")[0] != "/set":
            self._send(404, "text/plain", b"not found"); return
        ln = int(self.headers.get("Content-Length") or 0)
        form = urllib.parse.parse_qs(self.rfile.read(ln).decode("utf-8", "replace"))
        cfg = read_config()
        iv = form.get("interval", ["10"])[0]
        if iv in ALLOWED_INTERVALS:
            cfg["INTERVAL_MIN"] = iv
        cfg["OVERLAY_QUOTE"] = "1" if form.get("quote") else "0"
        cfg["OVERLAY_STATS"] = "1" if form.get("stats") else "0"
        write_config(cfg)
        set_cron_interval(cfg["INTERVAL_MIN"])
        # Re-apply the CURRENT image with the new settings (don't shuffle to a
        # random one) so Apply only changes overlays/interval, not the picture.
        cur = ""
        try:
            with open(os.path.join(os.path.dirname(CONFIG), "current")) as cf:
                cur = cf.read().strip()
        except Exception:
            cur = ""
        cmd = [SETWP, cur] if (cur and os.path.isfile(cur)) else [SETWP]
        try:
            subprocess.run(cmd, timeout=30)
        except Exception:
            pass
        regen()
        self.send_response(303)
        self.send_header("Location", "/")
        self.end_headers()

    def log_message(self, *a):                     # keep the console quiet
        pass


if __name__ == "__main__":
    os.makedirs(WEBDIR, exist_ok=True)
    regen()
    print("Serving wallpaper-rotator status + controls at http://127.0.0.1:%d" % PORT)
    print("(Ctrl-C to stop)")
    try:
        ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
    except KeyboardInterrupt:
        pass
