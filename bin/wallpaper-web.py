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
import os, re, shutil, subprocess, threading, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WEBDIR    = "@@WEBDIR@@"
PORT      = "@@PORT@@"
CONFIG    = "@@CONFIG@@"
GENSTATUS = "@@GENSTATUS@@"
SETWP     = "@@SETWP@@"
FETCH     = "@@FETCH@@"
POOL      = "@@POOL@@"

HOME  = os.path.expanduser("~")
STATE = os.path.join(HOME, ".local/state/wallpaper-rotator")
HERE  = os.path.dirname(os.path.abspath(__file__))
if WEBDIR.startswith("@@"):    WEBDIR    = os.path.join(STATE, "web")
if PORT.startswith("@@"):      PORT      = "8787"
if CONFIG.startswith("@@"):    CONFIG    = os.path.join(STATE, "config")
if GENSTATUS.startswith("@@"): GENSTATUS = os.path.join(HERE, "gen-status.sh")
if SETWP.startswith("@@"):     SETWP     = os.path.join(HERE, "set-wallpaper.sh")
if FETCH.startswith("@@"):     FETCH     = os.path.join(HERE, "fetch-wallpaper.sh")
if POOL.startswith("@@"):      POOL      = os.path.join(HOME, "Pictures/online-wallpapers")
PORT = int(PORT)

ALLOWED_INTERVALS = {"3", "5", "10", "15", "30", "60"}
ALLOWED_POS = {"auto", "northwest", "north", "northeast", "west", "center", "east",
               "southwest", "south", "southeast"}
ALLOWED_SIZE = {"small", "medium", "large"}
ALLOWED_THEME = {"dark", "light", "accent"}
ALLOWED_FONT = {"default", "DejaVu-Sans", "DejaVu-Serif", "DejaVu-Sans-Mono",
                "Liberation-Sans", "Liberation-Serif", "FreeSans", "FreeSerif"}
ALLOWED_BGTHEME = {"", "nature", "landscape", "minimal", "space", "city", "abstract",
                   "cars", "cycling", "animals", "dark", "forest", "ocean"}
ALLOWED_OVERLAY_STYLE = {"scrim", "frosted", "editorial", "chips"}
ALLOWED_CLOCK_STYLE = {"digital", "analogue"}
ALLOWED_CLOCK_FACE = {"classic", "minimal", "dots", "numbers"}
CFG_KEYS = ("INTERVAL_MIN", "OVERLAY_QUOTE", "OVERLAY_QUOTE_DETAIL", "OVERLAY_STATS",
            "QUOTE_POS", "STATS_POS", "OVERLAY_SIZE", "OVERLAY_THEME", "OVERLAY_FONT",
            "OVERLAY_STYLE", "STATS_SPARKLINE", "OVERLAY_WEATHER", "WEATHER_POS",
            "WEATHER_LOCATION", "OVERLAY_WEATHER_ICON", "OVERLAY_WEATHER_ICON_COLOR",
            "OVERLAY_WEATHER_FORECAST",
            "OVERLAY_CLOCK", "CLOCK_STYLE", "CLOCK_FACE", "CLOCK_POS", "CLOCK_24H",
            "CLOCK_DATE", "THEME", "AI_WALLPAPER", "AI_PROMPT", "AI_TOKEN",
            "OVERLAY_PULSE", "PULSE_POS", "PULSE_URL", "PULSE_JQ", "WEB_BIND")
CFG_DEFAULTS = {"INTERVAL_MIN": "10", "OVERLAY_QUOTE": "0", "OVERLAY_QUOTE_DETAIL": "0",
                "OVERLAY_STATS": "0", "QUOTE_POS": "south", "STATS_POS": "northeast",
                "OVERLAY_SIZE": "medium", "OVERLAY_THEME": "light", "OVERLAY_FONT": "default",
                "OVERLAY_STYLE": "scrim", "STATS_SPARKLINE": "0", "OVERLAY_WEATHER": "0",
                "WEATHER_POS": "north", "WEATHER_LOCATION": "", "OVERLAY_WEATHER_ICON": "0",
                "OVERLAY_WEATHER_ICON_COLOR": "0", "OVERLAY_WEATHER_FORECAST": "0",
                "OVERLAY_CLOCK": "0",
                "CLOCK_STYLE": "digital", "CLOCK_FACE": "classic",
                "CLOCK_POS": "northwest", "CLOCK_24H": "1",
                "CLOCK_DATE": "0", "THEME": "",
                # AI_TOKEN: config-file only (not a form field) — optional
                # pollinations.ai token for the fast generation path
                "AI_WALLPAPER": "0", "AI_PROMPT": "", "AI_TOKEN": "",
                "OVERLAY_PULSE": "0", "PULSE_POS": "east",
                "PULSE_URL": "", "PULSE_JQ": ".",
                # not a form field — set in the config file, needs a service
                # restart: "" = localhost only, "tailscale" = + tailnet IP,
                # or an explicit extra IP to bind
                "WEB_BIND": ""}


def read_config():
    cfg = dict(CFG_DEFAULTS)
    try:
        with open(CONFIG) as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, v = line.split("=", 1)
                    v = v.strip()
                    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                        v = v[1:-1]
                    cfg[k.strip()] = v
    except FileNotFoundError:
        pass
    return cfg


def write_config(cfg):
    os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
    with open(CONFIG, "w") as f:
        f.write("# wallpaper-rotator config (managed by wallpaper-web)\n")
        for k in CFG_KEYS:
            # Single-quote + escape so any value (spaces, double quotes in jq
            # templates, $ signs) survives `. config` sourcing verbatim.
            v = str(cfg.get(k, CFG_DEFAULTS[k]))
            f.write("%s='%s'\n" % (k, v.replace("'", "'\\''")))


def set_cron_interval(n):
    """Rewrite the schedule of the rotate line (the one running set-wallpaper.sh) to */n."""
    try:
        cur = subprocess.run(["crontab", "-l"], capture_output=True, text=True).stdout
    except Exception:
        return
    out = []
    for line in cur.splitlines():
        # ONLY the rotate line — not the every-minute clock-refresh line, which also
        # contains SETWP but references the 'current' file (rewriting it to */n broke
        # the clock cadence and made it collide/double-run with rotate).
        if SETWP in line and "current" not in line and not line.lstrip().startswith("#"):
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


def current_image():
    """Path of the original behind the wallpaper on screen (state file), or ''."""
    try:
        with open(os.path.join(os.path.dirname(CONFIG), "current")) as f:
            return f.read().strip()
    except Exception:
        return ""


def under_pool(path):
    """True only if path resolves to a file inside the pool (delete/move guard)."""
    if not path:
        return False
    real = os.path.realpath(path)
    return real.startswith(os.path.realpath(POOL) + os.sep) and os.path.isfile(real)


def newest_pool_image():
    """Most-recently-modified image in the pool (the just-fetched one), or ''."""
    try:
        files = [os.path.join(POOL, f) for f in os.listdir(POOL)
                 if f.lower().endswith((".jpg", ".jpeg", ".png"))]
        files = [f for f in files if os.path.isfile(f)]
        return max(files, key=os.path.getmtime) if files else ""
    except Exception:
        return ""


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
        elif path.startswith("/fav/"):
            name = urllib.parse.unquote(path[5:])
            if "/" in name or name.startswith("."):
                self._send(404, "text/plain", b"not found"); return
            fn = os.path.join(POOL, "favourites", name)
            ctype = "image/png" if name.lower().endswith(".png") else "image/jpeg"
        else:
            self._send(404, "text/plain", b"not found"); return
        try:
            with open(fn, "rb") as f:
                self._send(200, ctype, f.read())
        except FileNotFoundError:
            self._send(404, "text/plain", b"not generated yet")

    def _done(self):
        """Regenerate the page and bounce to / (fetch() follows and gets fresh HTML)."""
        regen()
        self.send_response(303)
        self.send_header("Location", "/")
        self.end_headers()

    def _setwp(self, arg=None):
        try:
            subprocess.run([SETWP, arg] if arg else [SETWP], timeout=30)
        except Exception:
            pass

    def do_POST(self):
        path = self.path.split("?")[0]
        if path == "/next":                       # rotate now
            self._setwp()
            self._done(); return
        if path == "/ban":                        # delete current image + rotate
            cur = current_image()
            if under_pool(cur):
                try:
                    os.remove(os.path.realpath(cur))
                except Exception:
                    pass
                # replace the banned image in the background so the pool stays topped up
                try:
                    subprocess.Popen([FETCH], start_new_session=True,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                except Exception:
                    pass
            self._setwp()
            self._done(); return
        if path == "/keep":                       # move current image to favourites/
            cur = current_image()
            fav = os.path.join(POOL, "favourites")
            # favourites/ sits inside the pool so rotation still picks it up
            # (set-wallpaper's find recurses) but every pruner globs only the
            # pool's top level, so kept images are never aged out.
            if under_pool(cur) and os.path.dirname(os.path.realpath(cur)) != os.path.realpath(fav):
                try:
                    os.makedirs(fav, exist_ok=True)
                    dest = os.path.join(fav, os.path.basename(cur))
                    shutil.move(os.path.realpath(cur), dest)
                    with open(os.path.join(os.path.dirname(CONFIG), "current"), "w") as f:
                        f.write(dest + "\n")
                except Exception:
                    pass
            self._done(); return
        if path in ("/use", "/unfav"):           # act on a named favourite
            ln = int(self.headers.get("Content-Length") or 0)
            form = urllib.parse.parse_qs(self.rfile.read(ln).decode("utf-8", "replace"))
            name = form.get("img", [""])[0]
            fav = os.path.join(POOL, "favourites", name)
            if name and "/" not in name and not name.startswith(".") and os.path.isfile(fav):
                if path == "/use":               # set this favourite as the wallpaper
                    self._setwp(fav)
                else:                            # back to the (prunable) pool
                    try:
                        dest = os.path.join(POOL, name)
                        shutil.move(fav, dest)
                        if current_image() == fav:
                            with open(os.path.join(os.path.dirname(CONFIG), "current"), "w") as f:
                                f.write(dest + "\n")
                    except Exception:
                        pass
            self._done(); return
        if path != "/set":
            self._send(404, "text/plain", b"not found"); return
        ln = int(self.headers.get("Content-Length") or 0)
        form = urllib.parse.parse_qs(self.rfile.read(ln).decode("utf-8", "replace"))
        cfg = read_config()
        old_theme = cfg.get("THEME", "")
        old_ai = cfg.get("AI_WALLPAPER", "0")
        old_bind = cfg.get("WEB_BIND", "")
        iv = form.get("interval", ["10"])[0]
        if iv in ALLOWED_INTERVALS:
            cfg["INTERVAL_MIN"] = iv
        cfg["OVERLAY_QUOTE"] = "1" if form.get("quote") else "0"
        cfg["OVERLAY_QUOTE_DETAIL"] = "1" if form.get("quote_detail") else "0"
        cfg["OVERLAY_STATS"] = "1" if form.get("stats") else "0"
        cfg["STATS_SPARKLINE"] = "1" if form.get("sparkline") else "0"
        cfg["OVERLAY_WEATHER"] = "1" if form.get("weather") else "0"
        cfg["OVERLAY_WEATHER_ICON"] = "1" if form.get("weather_icon") else "0"
        cfg["OVERLAY_WEATHER_ICON_COLOR"] = "1" if form.get("weather_icon_color") else "0"
        cfg["OVERLAY_WEATHER_FORECAST"] = "1" if form.get("weather_forecast") else "0"
        cfg["OVERLAY_CLOCK"] = "1" if form.get("clock") else "0"
        cfg["CLOCK_24H"] = "1" if form.get("clock_24h") else "0"
        cfg["CLOCK_DATE"] = "1" if form.get("clock_date") else "0"
        cfg["AI_WALLPAPER"] = "1" if form.get("ai") else "0"
        cfg["OVERLAY_PULSE"] = "1" if form.get("pulse") else "0"
        # Tailnet toggle: ON keeps an existing explicit value (advanced users may
        # have set an IP); OFF clears. A change needs a server restart to rebind —
        # scheduled detached below, after the response has gone out.
        if form.get("web_bind"):
            cfg["WEB_BIND"] = old_bind or "tailscale"
        else:
            cfg["WEB_BIND"] = ""

        def pick(field, allowed, default):
            v = form.get(field, [default])[0]
            return v if v in allowed else default
        cfg["QUOTE_POS"]     = pick("quote_pos", ALLOWED_POS, "south")
        cfg["STATS_POS"]     = pick("stats_pos", ALLOWED_POS, "northeast")
        cfg["WEATHER_POS"]   = pick("weather_pos", ALLOWED_POS, "north")
        cfg["OVERLAY_SIZE"]  = pick("size", ALLOWED_SIZE, "medium")
        cfg["OVERLAY_THEME"] = pick("overlay_theme", ALLOWED_THEME, "light")
        cfg["OVERLAY_FONT"]  = pick("font", ALLOWED_FONT, "default")
        cfg["OVERLAY_STYLE"] = pick("overlay_style", ALLOWED_OVERLAY_STYLE, "scrim")
        cfg["CLOCK_STYLE"]   = pick("clock_style", ALLOWED_CLOCK_STYLE, "digital")
        cfg["CLOCK_FACE"]    = pick("clock_face", ALLOWED_CLOCK_FACE, "classic")
        cfg["CLOCK_POS"]     = pick("clock_pos", ALLOWED_POS, "northwest")
        # THEME is multi-select: checked boxes arrive as repeated theme=...
        # fields; store as a space-separated list (none checked = "" = any).
        themes = [t for t in form.get("theme", []) if t and t in ALLOWED_BGTHEME]
        cfg["THEME"] = " ".join(dict.fromkeys(themes))
        wl = form.get("weather_location", [""])[0].strip()
        cfg["WEATHER_LOCATION"] = re.sub(r"[^A-Za-z0-9 ,.\-]", "", wl)[:40]
        cfg["PULSE_POS"] = pick("pulse_pos", ALLOWED_POS, "east")
        ap = form.get("ai_prompt", [""])[0].strip()
        cfg["AI_PROMPT"] = re.sub(r"[^A-Za-z0-9 ,.\-']", "", ap)[:100]
        pu = form.get("pulse_url", [""])[0].strip()
        cfg["PULSE_URL"] = pu if re.match(r"^(https?|file)://[^\s\"'<>]+$", pu) else ""
        pj = form.get("pulse_jq", ["."])[0].replace("\n", " ").replace("\r", "").strip()
        cfg["PULSE_JQ"] = pj[:200] or "."
        write_config(cfg)
        set_cron_interval(cfg["INTERVAL_MIN"])
        if cfg["WEB_BIND"] != old_bind:
            try:
                subprocess.Popen(["bash", "-c", "sleep 1; systemctl --user restart wallpaper-web"],
                                 start_new_session=True,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except Exception:
                pass
        ai_turned_on = cfg["AI_WALLPAPER"] == "1" and old_ai != "1"
        if ai_turned_on:
            # AI generation takes minutes — converge ENTIRELY in the background
            # (generate one, show it, top up a few more, prune) so Apply returns
            # immediately instead of pinning the button on "Applying…".
            try:
                subprocess.Popen(
                    ["bash", "-c",
                     "%s; n=$(ls -t %s/*.jpg 2>/dev/null | head -1); [ -n \"$n\" ] && %s \"$n\"; "
                     "for i in 1 2 3; do %s; done; "
                     "ls -tp %s/*.jpg 2>/dev/null | tail -n +13 | xargs -r rm --; %s"
                     % (FETCH, POOL, SETWP, FETCH, POOL, GENSTATUS)],
                    start_new_session=True,
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except Exception:
                pass
            self._done(); return
        if set(cfg["THEME"].split()) != set(old_theme.split()):
            # Theme changed: only wallhaven honours the theme and the pool is mostly
            # theme-blind, so a plain re-render shows nothing new. Fetch a themed
            # image NOW and display it (instant feedback), then top up with more
            # themed images + prune the oldest in the background so rotation
            # converges to the theme without blocking this response.
            try:
                subprocess.run([FETCH], timeout=120)   # AI generation can take ~a minute
            except Exception:
                pass
            newest = newest_pool_image()
            cmd = [SETWP, newest] if newest else [SETWP]
            try:
                subprocess.run(cmd, timeout=30)
            except Exception:
                pass
            try:
                subprocess.Popen(
                    ["bash", "-c",
                     "for i in $(seq 1 7); do %s; done; "
                     "ls -tp %s/*.jpg 2>/dev/null | tail -n +13 | xargs -r rm --"
                     % (FETCH, POOL)],
                    start_new_session=True,
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except Exception:
                pass
        else:
            # No theme change: re-apply the CURRENT image with the new settings
            # (don't shuffle) so Apply only changes overlays/interval, not the picture.
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
        self._done()

    def log_message(self, *a):                     # keep the console quiet
        pass


def bind_addresses():
    """127.0.0.1 always; WEB_BIND in the config adds more (restart to apply):
    "tailscale" resolves this machine's tailnet IP, anything else is used
    verbatim as an extra address. Localhost trust model still applies — only
    open this up on networks where everyone may control the wallpaper."""
    addrs = ["127.0.0.1"]
    wb = read_config().get("WEB_BIND", "").strip()
    if wb == "tailscale":
        try:
            out = subprocess.run(["tailscale", "ip", "-4"], capture_output=True,
                                 text=True, timeout=10).stdout.strip().splitlines()
            if out and out[0]:
                addrs.append(out[0])
        except Exception:
            print("WARNING: WEB_BIND=tailscale but no tailscale IP — localhost only")
    elif wb:
        addrs.append(wb)
    return addrs


if __name__ == "__main__":
    os.makedirs(WEBDIR, exist_ok=True)
    regen()
    servers = []
    for addr in bind_addresses():
        try:
            servers.append(ThreadingHTTPServer((addr, PORT), Handler))
            print("Serving wallpaper-rotator status + controls at http://%s:%d" % (addr, PORT))
        except OSError as e:
            print("WARNING: could not bind %s:%d (%s)" % (addr, PORT, e))
    print("(Ctrl-C to stop)")
    try:
        for srv in servers[1:]:
            threading.Thread(target=srv.serve_forever, daemon=True).start()
        if servers:
            servers[0].serve_forever()
    except KeyboardInterrupt:
        pass
