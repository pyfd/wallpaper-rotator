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
import os, re, shutil, subprocess, threading, time, json, urllib.parse, urllib.request
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
ALLOWED_PULSE_TTL = {"1", "5", "15", "30"}
# Keep in sync with the qtheme_opts list in gen-status.sh
ALLOWED_QUOTE_THEME = {"", "love", "life", "inspirational", "humor", "philosophy",
                       "wisdom", "happiness", "hope", "success", "romance",
                       "friendship", "science"}
CFG_KEYS = ("INTERVAL_MIN", "OVERLAY_QUOTE", "OVERLAY_QUOTE_DETAIL", "QUOTE_THEME",
            "QUOTE_MATCH_IMAGE", "OVERLAY_STATS",
            "QUOTE_POS", "STATS_POS", "OVERLAY_SIZE", "OVERLAY_THEME", "OVERLAY_FONT",
            "OVERLAY_STYLE", "STATS_SPARKLINE", "OVERLAY_WEATHER", "WEATHER_POS",
            "WEATHER_LOCATION", "OVERLAY_WEATHER_ICON", "OVERLAY_WEATHER_ICON_COLOR",
            "OVERLAY_WEATHER_FORECAST",
            "OVERLAY_CLOCK", "CLOCK_STYLE", "CLOCK_FACE", "CLOCK_POS", "CLOCK_24H",
            "CLOCK_DATE", "THEME", "AI_WALLPAPER", "AI_PROMPT", "AI_TOKEN", "AI_HORDE_KEY",
            "OVERLAY_PULSE", "PULSE_POS", "PULSE_URL", "PULSE_JQ", "PULSE_TTL",
            "PULSE_TITLE", "WEB_BIND", "ALERTS_URL")
CFG_DEFAULTS = {"INTERVAL_MIN": "10", "OVERLAY_QUOTE": "0", "OVERLAY_QUOTE_DETAIL": "0",
                "QUOTE_THEME": "", "QUOTE_MATCH_IMAGE": "0",
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
                # pollinations.ai token for the fast generation path.
                # AI_HORDE_KEY: config-file only — registered AI Horde key for
                # full-res gens (anonymous is capped at 640x384 by Horde policy)
                "AI_WALLPAPER": "0", "AI_PROMPT": "", "AI_TOKEN": "", "AI_HORDE_KEY": "",
                "OVERLAY_PULSE": "0", "PULSE_POS": "east",
                "PULSE_URL": "", "PULSE_JQ": ".", "PULSE_TTL": "5",
                "PULSE_TITLE": "",
                # not a form field — set in the config file, needs a service
                # restart: "" = localhost only, "tailscale" = + tailnet IP,
                # or an explicit extra IP to bind
                "WEB_BIND": "",
                # not a form field — set in the config file. "" = infra-alert
                # badge off; an alerts-endpoint URL enables check-alerts.sh.
                # Listed in CFG_KEYS purely so a web-UI save preserves it.
                "ALERTS_URL": ""}


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


def _bg(sh):
    """Run a shell chain detached — the canvas-editor UI never blocks on a
    render/fetch; it polls /state.json instead."""
    try:
        subprocess.Popen(["bash", "-c", sh], start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
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


LOG_FILE     = os.path.join(STATE, "wallpaper.log")
LOGIN_TARGET = "/usr/share/backgrounds/login-random.jpg"
# DM -> the privileged refresh command (same one the per-login autostart runs;
# install.sh drops a matching passwordless /etc/sudoers.d rule for each).
LOGIN_REFRESH = {
    "gdm":     ["/usr/local/bin/build-gdm-greeter.sh", "--refresh"],
    "lightdm": ["/usr/local/bin/random-login-bg.sh"],
}
_LOGIN_LOG_RE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) \[(?:login|gdm)\] (\w+)(?: img=(.+))?")


def detect_dm():
    """Which display manager owns the login screen: 'gdm' | 'lightdm' | other."""
    try:
        with open("/etc/X11/default-display-manager") as f:
            dm = os.path.basename(f.read().strip()).lower()
        if "gdm" in dm:
            return "gdm"
        if "lightdm" in dm:
            return "lightdm"
    except Exception:
        pass
    try:
        out = subprocess.run(["systemctl", "status", "display-manager"],
                             capture_output=True, text=True, timeout=5).stdout or ""
        m = re.search(r"lightdm|gdm[0-9]*|sddm", out)
        if m:
            return "gdm" if m.group(0).startswith("gdm") else m.group(0)
    except Exception:
        pass
    return "other"


def login_bg_state():
    """Login-background status for the UI panel: display manager, the source
    image + timestamp of the last refresh (from the wallpaper log), and whether
    a preview image exists."""
    dm = detect_dm()
    ts = status = img = ""
    try:
        with open(LOG_FILE, errors="replace") as f:
            for line in f:                       # keep the LAST matching line
                m = _LOGIN_LOG_RE.match(line)
                if m:
                    ts, status, img = m.group(1), m.group(2), (m.group(3) or "").strip()
    except Exception:
        pass
    mtime = os.path.getmtime(LOGIN_TARGET) if os.path.isfile(LOGIN_TARGET) else None
    return {
        "dm": dm,
        "supported": dm in LOGIN_REFRESH,
        "current_img": img,
        "last_status": status,
        "last_refresh": ts,
        "target_mtime": mtime,
        "has_preview": mtime is not None,
    }


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        # Everything here is regenerated server-side (index.html by gen-status,
        # state.json on poll, jpgs per rotate) -- a heuristically-cached copy is
        # always wrong. Without this, a JS fix only reaches the browser via a
        # hard refresh (bit us 2026-06-05: fixed poll JS never loaded, "Next
        # still not working").
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/index.html"):
            fn, ctype = os.path.join(WEBDIR, "index.html"), "text/html; charset=utf-8"
        elif path == "/state.json":
            # The app polls this; regenerate when stale (throttled so a burst of
            # post-action polls doesn't stack gen-status runs).
            fn, ctype = os.path.join(WEBDIR, "state.json"), "application/json; charset=utf-8"
            try:
                if time.time() - os.path.getmtime(fn) > 5:
                    regen()
            except OSError:
                regen()
        elif path == "/alerts.json":
            # Infra-alert set for the UI panel. Fetch LIVE from the aggregator so
            # an ack (or any change) reflects immediately — the on-disk cache is
            # only refreshed by check-alerts.sh every 60s, which made acked
            # banners linger. Falls back to that cache if the aggregator is
            # unreachable. Also refreshes the cache so the wallpaper badge stays
            # current between check-alerts runs.
            ctype = "application/json; charset=utf-8"
            cache = os.path.join(STATE, "alerts.json")
            aurl = read_config().get("ALERTS_URL", "")
            body = None
            if aurl:
                try:
                    with urllib.request.urlopen(aurl, timeout=3) as r:
                        body = r.read()
                    try:
                        with open(cache, "wb") as f:
                            f.write(body)
                    except Exception:
                        pass
                except Exception:
                    body = None
            if body is None:
                try:
                    with open(cache, "rb") as f:
                        body = f.read()
                except Exception:
                    body = b'{"active":[]}'
            self._send(200, ctype, body); return
        elif path == "/loginbg.json":
            self._send(200, "application/json; charset=utf-8",
                       json.dumps(login_bg_state()).encode())
            return
        elif path == "/loginbg.jpg":
            # the current login-screen image (root-owned 0644); falls through to
            # the generic file send below, 404 if login background isn't set up.
            fn, ctype = LOGIN_TARGET, "image/jpeg"
        elif path == "/current.jpg":
            fn, ctype = os.path.join(WEBDIR, "current.jpg"), "image/jpeg"
        elif path == "/canvas.jpg":
            fn, ctype = os.path.join(WEBDIR, "canvas.jpg"), "image/jpeg"
        elif path == "/thumb":
            # Filmstrip thumbnail: ?f=<name>[&fav=1], cached under WEBDIR/thumbs.
            qs = urllib.parse.parse_qs(self.path.split("?", 1)[1] if "?" in self.path else "")
            name = qs.get("f", [""])[0]
            fav = qs.get("fav", ["0"])[0] == "1"
            if not name or "/" in name or name.startswith("."):
                self._send(404, "text/plain", b"not found"); return
            src = os.path.join(POOL, "favourites", name) if fav else os.path.join(POOL, name)
            if not os.path.isfile(src):
                self._send(404, "text/plain", b"not found"); return
            tdir = os.path.join(WEBDIR, "thumbs")
            os.makedirs(tdir, exist_ok=True)
            fn = os.path.join(tdir, ("fav-" if fav else "") + name + ".jpg")
            try:
                if not os.path.isfile(fn) or os.path.getmtime(fn) < os.path.getmtime(src):
                    subprocess.run(["convert", src, "-thumbnail", "236x133^",
                                    "-gravity", "center", "-extent", "236x133", fn],
                                   timeout=20)
            except Exception:
                pass
            ctype = "image/jpeg"
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

    def _done(self, do_regen=True):
        """Regenerate the page and bounce to / (fetch() follows and gets fresh HTML).
        Rotate-triggering actions pass do_regen=False: the rotate is async, so a
        synchronous regen here (~6s of gen-status) only delays the response with
        state that is stale the moment the rotate lands -- /state.json polling
        regenerates when fresh data exists."""
        if do_regen:
            regen()
        self.send_response(303)
        self.send_header("Location", "/")
        self.end_headers()

    def _setwp(self, arg=None):
        # Fire-and-forget: a full render is CPU-bound (10s+ overlay composite on
        # a modest box, more when the weather cache wants a refetch), and running
        # it inside the POST made Next/Ban/Use feel dead -- the button "did
        # nothing" for 15-30s (Fam3, 2026-06-05). The UI polls /state.json
        # (which self-regenerates when stale) until the rotate lands.
        try:
            subprocess.Popen([SETWP, arg] if arg else [SETWP], start_new_session=True,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass

    def do_POST(self):
        path = self.path.split("?")[0]
        if path == "/next":                       # rotate now
            self._setwp()
            self._done(do_regen=False); return
        if path == "/ack":                        # acknowledge an infra alert
            ln = int(self.headers.get("Content-Length") or 0)
            form = urllib.parse.parse_qs(self.rfile.read(ln).decode("utf-8", "replace"))
            ahost = form.get("host", [""])[0]
            akey = form.get("key", [""])[0]
            aurl = read_config().get("ALERTS_URL", "")
            if not ahost or not akey or not aurl:
                self._send(400, "application/json", b'{"ok":false,"error":"missing host/key/ALERTS_URL"}'); return
            ackurl = aurl.replace("/admin/alerts.json", "/api/alerts/ack")
            payload = json.dumps({"host": ahost, "key": akey, "acked_by": os.uname().nodename}).encode()
            try:
                req = urllib.request.Request(ackurl, data=payload,
                                             headers={"Content-Type": "application/json"}, method="POST")
                with urllib.request.urlopen(req, timeout=8) as r:
                    self._send(200, "application/json; charset=utf-8", r.read())
            except Exception as e:
                self._send(502, "application/json", ('{"ok":false,"error":%s}' % json.dumps(str(e))).encode())
            return
        if path == "/loginbg-refresh":            # re-roll the login-screen background now
            st = login_bg_state()
            cmd = LOGIN_REFRESH.get(st["dm"])
            if not cmd:
                self._send(400, "application/json",
                           json.dumps({"ok": False,
                                       "error": "login background not supported on %s" % st["dm"]}).encode())
                return
            try:
                # sudo -n: the per-login autostart already runs this passwordless
                # (install.sh installs the matching /etc/sudoers.d rule).
                p = subprocess.run(["sudo", "-n"] + cmd,
                                   capture_output=True, text=True, timeout=120)
                ok = p.returncode == 0
                body = {"ok": ok, "state": login_bg_state()}
                if not ok:
                    body["error"] = (p.stderr or p.stdout or ("exit %d" % p.returncode)).strip()[-300:]
                self._send(200 if ok else 502, "application/json; charset=utf-8",
                           json.dumps(body).encode())
            except Exception as e:
                self._send(502, "application/json",
                           json.dumps({"ok": False, "error": str(e)}).encode())
            return
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
            self._done(do_regen=False); return
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
        if path == "/img-act":                   # filmstrip: act on a NAMED pool/favourites image
            ln = int(self.headers.get("Content-Length") or 0)
            form = urllib.parse.parse_qs(self.rfile.read(ln).decode("utf-8", "replace"))
            name = form.get("img", [""])[0]
            in_fav = form.get("fav", ["0"])[0] == "1"
            actn = form.get("act", [""])[0]
            if not name or "/" in name or name.startswith("."):
                self._send(400, "text/plain", b"bad image name"); return
            src = os.path.join(POOL, "favourites", name) if in_fav else os.path.join(POOL, name)
            if not os.path.isfile(src) or actn not in ("use", "fav", "unfav", "ban"):
                self._send(404, "text/plain", b"not found"); return
            statedir = os.path.dirname(CONFIG)
            if actn == "use":
                _bg("%s '%s'; %s" % (SETWP, src, GENSTATUS))
            elif actn == "fav" and not in_fav:
                fav = os.path.join(POOL, "favourites")
                try:
                    os.makedirs(fav, exist_ok=True)
                    dest = os.path.join(fav, name)
                    shutil.move(src, dest)
                    if current_image() == src:
                        with open(os.path.join(statedir, "current"), "w") as f:
                            f.write(dest + "\n")
                except Exception:
                    pass
                regen()
            elif actn == "unfav" and in_fav:
                try:
                    dest = os.path.join(POOL, name)
                    shutil.move(src, dest)
                    if current_image() == src:
                        with open(os.path.join(statedir, "current"), "w") as f:
                            f.write(dest + "\n")
                except Exception:
                    pass
                regen()
            elif actn == "ban":
                was_cur = current_image() == src
                try:
                    os.remove(src)
                except Exception:
                    pass
                # top up the pool; rotate away if we just deleted the on-screen image
                _bg("%s; %s%s" % (FETCH, (SETWP + "; ") if was_cur else "", GENSTATUS))
            self._send(200, "application/json", b'{"ok":true}'); return
        if path == "/dream":                     # one-shot AI generation, then show it
            _bg("WR_FORCE_SRC=ai %s; n=$(ls -t %s/*.jpg 2>/dev/null | head -1); "
                "[ -n \"$n\" ] && %s \"$n\"; %s" % (FETCH, POOL, SETWP, GENSTATUS))
            self._send(200, "application/json", b'{"ok":true}'); return
        if path == "/setone":                    # instant-apply: one or a few settings
            ln = int(self.headers.get("Content-Length") or 0)
            form = urllib.parse.parse_qs(self.rfile.read(ln).decode("utf-8", "replace"))
            cfg = read_config()
            old = dict(cfg)
            BOOLS = {"quote": "OVERLAY_QUOTE", "quote_detail": "OVERLAY_QUOTE_DETAIL",
                     "quote_match": "QUOTE_MATCH_IMAGE", "stats": "OVERLAY_STATS",
                     "sparkline": "STATS_SPARKLINE", "weather": "OVERLAY_WEATHER",
                     "weather_icon": "OVERLAY_WEATHER_ICON",
                     "weather_icon_color": "OVERLAY_WEATHER_ICON_COLOR",
                     "weather_forecast": "OVERLAY_WEATHER_FORECAST",
                     "clock": "OVERLAY_CLOCK", "clock_24h": "CLOCK_24H",
                     "clock_date": "CLOCK_DATE", "ai": "AI_WALLPAPER",
                     "pulse": "OVERLAY_PULSE"}
            PICKS = {"quote_pos": ("QUOTE_POS", ALLOWED_POS), "stats_pos": ("STATS_POS", ALLOWED_POS),
                     "weather_pos": ("WEATHER_POS", ALLOWED_POS), "clock_pos": ("CLOCK_POS", ALLOWED_POS),
                     "pulse_pos": ("PULSE_POS", ALLOWED_POS), "size": ("OVERLAY_SIZE", ALLOWED_SIZE),
                     "overlay_theme": ("OVERLAY_THEME", ALLOWED_THEME), "font": ("OVERLAY_FONT", ALLOWED_FONT),
                     "overlay_style": ("OVERLAY_STYLE", ALLOWED_OVERLAY_STYLE),
                     "clock_style": ("CLOCK_STYLE", ALLOWED_CLOCK_STYLE),
                     "clock_face": ("CLOCK_FACE", ALLOWED_CLOCK_FACE),
                     "pulse_ttl": ("PULSE_TTL", ALLOWED_PULSE_TTL),
                     "interval": ("INTERVAL_MIN", ALLOWED_INTERVALS)}
            touched = False
            for k, vals in form.items():
                v = vals[0]
                if k in BOOLS and v in ("0", "1"):
                    cfg[BOOLS[k]] = v; touched = True
                elif k in PICKS and v in PICKS[k][1]:
                    cfg[PICKS[k][0]] = v; touched = True
                elif k == "quote_theme":
                    # the UI's select says "any"; the config stores "" for it
                    v = "" if v == "any" else v
                    if v in ALLOWED_QUOTE_THEME:
                        cfg["QUOTE_THEME"] = v; touched = True
                elif k == "weather_location":
                    cfg["WEATHER_LOCATION"] = re.sub(r"[^A-Za-z0-9 ,.\-]", "", v.strip())[:40]; touched = True
                elif k == "ai_prompt":
                    cfg["AI_PROMPT"] = re.sub(r"[^A-Za-z0-9 ,.\-']", "", v.strip())[:100]; touched = True
                elif k == "pulse_title":
                    cfg["PULSE_TITLE"] = re.sub(r"[^A-Za-z0-9 ,.\-':&]", "", v.strip())[:40]; touched = True
                elif k == "pulse_url":
                    pu = v.strip()
                    cfg["PULSE_URL"] = pu if re.match(r"^(https?|file)://[^\s\"'<>]+$", pu) else ""
                    touched = True
                elif k == "pulse_jq":
                    cfg["PULSE_JQ"] = v.replace("\n", " ").replace("\r", "").strip()[:200] or "."; touched = True
                elif k == "theme":
                    themes = [t for t in vals if t and t in ALLOWED_BGTHEME]
                    cfg["THEME"] = " ".join(dict.fromkeys(themes)); touched = True
                elif k == "web_bind":
                    cfg["WEB_BIND"] = (old.get("WEB_BIND") or "tailscale") if v == "1" else ""
                    touched = True
            if not touched:
                self._send(400, "text/plain", b"no valid setting in request"); return
            if (cfg["PULSE_URL"], cfg["PULSE_JQ"]) != (old.get("PULSE_URL"), old.get("PULSE_JQ")):
                try:
                    os.remove(os.path.join(os.path.dirname(CONFIG), "pulse.txt"))
                except Exception:
                    pass
            write_config(cfg)
            # side-effects mirror /set, but everything slow runs detached so the
            # UI gets its 200 instantly and just polls /state.json for results
            if cfg["INTERVAL_MIN"] != old.get("INTERVAL_MIN"):
                set_cron_interval(cfg["INTERVAL_MIN"])
                regen()
            elif cfg["WEB_BIND"] != old.get("WEB_BIND"):
                _bg("sleep 1; systemctl --user restart wallpaper-web")
            elif cfg["AI_WALLPAPER"] == "1" and old.get("AI_WALLPAPER") != "1":
                _bg("%s; n=$(ls -t %s/*.jpg 2>/dev/null | head -1); [ -n \"$n\" ] && %s \"$n\"; "
                    "for i in 1 2 3; do %s; done; "
                    "ls -tp %s/*.jpg 2>/dev/null | tail -n +13 | xargs -r rm --; %s"
                    % (FETCH, POOL, SETWP, FETCH, POOL, GENSTATUS))
            elif set(cfg["THEME"].split()) != set((old.get("THEME") or "").split()):
                _bg("%s; n=$(ls -t %s/*.jpg 2>/dev/null | head -1); [ -n \"$n\" ] && %s \"$n\"; "
                    "for i in $(seq 1 7); do %s; done; "
                    "ls -tp %s/*.jpg 2>/dev/null | tail -n +13 | xargs -r rm --; %s"
                    % (FETCH, POOL, SETWP, FETCH, POOL, GENSTATUS))
            else:
                cur = current_image()
                cmd = "%s '%s'" % (SETWP, cur) if (cur and os.path.isfile(cur)) else SETWP
                _bg("%s; %s" % (cmd, GENSTATUS))
            self._send(200, "application/json", b'{"ok":true}'); return
        if path == "/pulse_test":                # dry-run a pulse URL + template
            ln = int(self.headers.get("Content-Length") or 0)
            form = urllib.parse.parse_qs(self.rfile.read(ln).decode("utf-8", "replace"))
            url = form.get("url", [""])[0].strip()
            jqf = form.get("jq", ["."])[0].replace("\n", " ").replace("\r", "").strip()[:200] or "."
            if not re.match(r"^(https?|file)://[^\s\"'<>]+$", url):
                self._send(400, "text/plain; charset=utf-8", b"invalid URL"); return
            try:
                p = subprocess.run(
                    ["bash", "-c", 'curl -fsL --max-time 6 "$1" | jq -r "$2"', "_", url, jqf],
                    capture_output=True, text=True, timeout=15)
                out = p.stdout.strip() or p.stderr.strip() or "(empty result)"
            except Exception as e:
                out = "test failed: %s" % e
            self._send(200, "text/plain; charset=utf-8", out[:2000].encode("utf-8")); return
        if path != "/set":
            self._send(404, "text/plain", b"not found"); return
        ln = int(self.headers.get("Content-Length") or 0)
        form = urllib.parse.parse_qs(self.rfile.read(ln).decode("utf-8", "replace"))
        cfg = read_config()
        old_theme = cfg.get("THEME", "")
        old_ai = cfg.get("AI_WALLPAPER", "0")
        old_bind = cfg.get("WEB_BIND", "")
        old_pulse_url = cfg.get("PULSE_URL", "")
        old_pulse_jq = cfg.get("PULSE_JQ", ".")
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
        cfg["PULSE_TTL"] = pick("pulse_ttl", ALLOWED_PULSE_TTL, "5")
        pt = form.get("pulse_title", [""])[0].strip()
        cfg["PULSE_TITLE"] = re.sub(r"[^A-Za-z0-9 ,.\-':&]", "", pt)[:40]
        cfg["QUOTE_THEME"] = pick("quote_theme", ALLOWED_QUOTE_THEME, "")
        cfg["QUOTE_MATCH_IMAGE"] = "1" if form.get("quote_match") else "0"
        # Pulse settings changed -> drop the cached lines so the re-render that
        # follows this Apply fetches fresh with the new URL/template.
        if (cfg["PULSE_URL"], cfg["PULSE_JQ"]) != (old_pulse_url, old_pulse_jq):
            try:
                os.remove(os.path.join(os.path.dirname(CONFIG), "pulse.txt"))
            except Exception:
                pass
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
