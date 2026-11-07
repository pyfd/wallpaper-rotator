#!/usr/bin/env python3
"""Page use (#1815): the usage beacon on every page the web UI serves, and its store.

    python3 tests/test_usage.py            # needs ~/gits/workshop-service + ~/gits/song-journey for the drift check
    WR_NO_UPSTREAM=1 python3 tests/test_usage.py   # everything but the drift check

Runs the real server (bin/wallpaper-web.py) in-process on a free port, with HOME pointed at a temp dir, so it never
touches this machine's state, pool or config. What it holds:
  - EVERY GET route the server answers (read from do_GET's own source, not a file glob) that serves HTML carries
    exactly one beacon tag; and the two vendored scripts are served.
  - /seen keeps one row per view with the largest figures; a cross-site post and a malformed body write nothing.
  - who: by=claude -> claude, a script's user-agent -> automation, a browser -> human.
  - /health.json says usage_quiet when a person loaded the page and no beacon row came back, and stops once one does.
  - rows older than a year are pruned.
  - every control the page's click/change handlers act on carries a data-usage name.
  - the vendored copies match upstream below the sentinel, byte for byte.
"""
import importlib.util, inspect, json, os, re, sqlite3, sys, tempfile, threading, unittest, urllib.error, urllib.request
from datetime import datetime, timedelta, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REAL_HOME = os.path.expanduser("~")                     # the upstream clones live here, not under the test's HOME
TMP = tempfile.mkdtemp(prefix="wr-usage-test-")
os.environ["HOME"] = TMP                               # before the import: STATE derives from ~
spec = importlib.util.spec_from_file_location("wallpaper_web", os.path.join(ROOT, "bin", "wallpaper-web.py"))
web = importlib.util.module_from_spec(spec)
spec.loader.exec_module(web)
web.regen = lambda *a, **k: None                       # never run gen-status from a test

BROWSER = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/130.0 Safari/537.36"
TAG = re.compile(r"<script\b[^>]*\bdata-usage-beacon\b[^>]*>", re.I)


def start():
    os.makedirs(web.WEBDIR, exist_ok=True)
    with open(os.path.join(web.WEBDIR, "index.html"), "w") as f:
        f.write("<!doctype html><html><head><title>t</title></head><body><p>page</p></body></html>")
    srv = web.ThreadingHTTPServer(("127.0.0.1", 0), web.Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, "http://127.0.0.1:%d" % srv.server_address[1]


SRV, BASE = start()
web.PORT = SRV.server_address[1]                        # same_origin() allows 127.0.0.1:PORT


def req(path, data=None, headers=None, method=None):
    h = {"User-Agent": BROWSER}
    h.update(headers or {})
    r = urllib.request.Request(BASE + path, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(r, timeout=10) as resp:
            return resp.status, resp.headers.get_content_type(), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get_content_type() if e.headers else "", e.read()


def db():
    con = sqlite3.connect(web.USAGE_DB)
    con.row_factory = sqlite3.Row
    return con


def clear():
    con = web.usage_connect()
    con.execute("DELETE FROM page_views")
    con.execute("DELETE FROM usage_events")
    con.commit()
    con.close()


def beacon(vid, ms, actions=0, controls=None, actor=None, origin=None):
    row = {"kind": "view", "page": None, "path": "/", "session": vid, "focus_ms": ms, "actions": actions,
           "detail": controls, "load_ms": 120}
    if actor:
        row["actor"] = actor
    hdr = {"Content-Type": "application/json", "Origin": origin or BASE}
    return req(web.SEEN_PATH, json.dumps({"rows": [row]}).encode(), hdr)


class EveryPage(unittest.TestCase):
    def get_routes(self):
        src = inspect.getsource(web.Handler.do_GET)
        routes = set(re.findall(r'path\s*==\s*"(/[^"]*)"', src))
        for group in re.findall(r"path\s+in\s+\(([^)]*)\)", src):
            routes |= set(re.findall(r'"(/[^"]*)"', group))
        routes |= set(web.USAGE_JS)
        return sorted(routes)

    def test_every_html_route_carries_one_tag(self):
        routes = self.get_routes()
        self.assertIn("/", routes, "the route walk found no page: the do_GET parse is broken")
        html = []
        for path in routes:
            status, ctype, body = req(path)
            if status == 200 and ctype == "text/html":
                html.append(path)
                n = len(TAG.findall(body.decode("utf-8", "replace")))
                self.assertEqual(n, 1, f"{path}: {n} beacon tags (needs exactly 1)")
        self.assertGreaterEqual(len(html), 2, f"expected / and /index.html to serve HTML, got {html}")

    def test_tag_names_a_safe_endpoint(self):
        _, _, body = req("/")
        tag = TAG.search(body.decode()).group(0)
        ep = re.search(r'data-endpoint="([^"]+)"', tag).group(1)
        self.assertEqual(ep, web.SEEN_PATH)
        self.assertIsNone(re.search(r"usage|metric|event|track|analytic|beacon", ep, re.I),
                          "filter lists block endpoints with these words")

    def test_vendored_scripts_are_served(self):
        for path in web.USAGE_JS:
            status, ctype, body = req(path)
            self.assertEqual(status, 200, path)
            self.assertIn(b"UPSTREAM COPY BEGINS", body, path)

    def test_a_non_html_response_is_untouched(self):
        _, _, body = req("/vendor/usage-beacon.js")
        self.assertNotIn(web.BEACON_TAGS, body)


class Store(unittest.TestCase):
    def setUp(self):
        clear()

    def test_one_row_per_view_largest_kept(self):
        beacon("view-aaaa-0001", 5000, 1, {"button#b-next": 1})
        beacon("view-aaaa-0001", 9000, 3, {"button#b-next": 2, "film-use": 1})
        beacon("view-aaaa-0001", 7000, 2, {"button#b-next": 2})        # late, smaller: must not lower anything
        rows = db().execute("SELECT * FROM usage_events").fetchall()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["ms"], 9000)
        d = json.loads(rows[0]["detail"])
        self.assertEqual(d["actions"], 3)
        self.assertEqual(d["controls"], {"button#b-next": 2, "film-use": 1})
        self.assertEqual(d["load_ms"], 120)

    def test_seen_answers_204_and_never_counts_a_page_load(self):
        status, _, _ = beacon("view-aaaa-0002", 4000)
        self.assertEqual(status, 204)
        self.assertEqual(db().execute("SELECT COUNT(*) FROM page_views").fetchone()[0], 0)

    def test_cross_site_post_writes_nothing(self):
        status, _, _ = beacon("view-aaaa-0003", 4000, origin="https://evil.example")
        self.assertEqual(status, 403)
        self.assertEqual(db().execute("SELECT COUNT(*) FROM usage_events").fetchone()[0], 0)

    def test_malformed_bodies_write_nothing(self):
        hdr = {"Content-Type": "application/json", "Origin": BASE}
        for body in (b"not json", b"{}", json.dumps({"rows": [{"kind": "view", "session": "x", "path": "/"}]}).encode(),
                     json.dumps({"rows": [{"kind": "click", "session": "view-aaaa-0004", "path": "/"}]}).encode(),
                     json.dumps({"rows": [{"kind": "view", "session": "view-aaaa-0005", "path": "nope"}]}).encode(),
                     b"x" * 9000):
            status, _, _ = req(web.SEEN_PATH, body, hdr)
            self.assertEqual(status, 204)
        self.assertEqual(db().execute("SELECT COUNT(*) FROM usage_events").fetchone()[0], 0)

    def test_who(self):
        req("/")
        req("/?by=claude")
        req("/", headers={"User-Agent": "python-urllib/3.12"})
        actors = [r[0] for r in db().execute("SELECT actor FROM page_views ORDER BY id")]
        self.assertEqual(actors, ["human", "claude", "automation"])
        beacon("view-aaaa-0006", 3000, actor="claude")
        beacon("view-aaaa-0007", 3000)
        got = dict(db().execute("SELECT view_id, actor FROM usage_events").fetchall())
        self.assertEqual(got, {"view-aaaa-0006": "claude", "view-aaaa-0007": "human"})

    def test_quiet_until_a_beacon_row(self):
        for _ in range(web.QUIET_MIN_VIEWS):
            req("/")
        _, _, body = req("/health.json")
        h = json.loads(body)
        self.assertEqual(h["page_loads"], web.QUIET_MIN_VIEWS)
        self.assertEqual(len(h["usage_quiet"]), 1, h)
        beacon("view-aaaa-0008", 61000, 2, {"set-interval": 2})
        h = json.loads(req("/health.json")[2])
        self.assertEqual(h["usage_quiet"], [])
        self.assertEqual(h["views"], 1)
        self.assertEqual(h["focus_min"], 1.0)
        self.assertEqual(h["controls"], [["set-interval", 2]])

    def test_claude_and_scripts_do_not_trip_quiet(self):
        for _ in range(web.QUIET_MIN_VIEWS + 2):
            req("/?by=claude")
            req("/", headers={"User-Agent": "curl/8.5"})
        self.assertEqual(json.loads(req("/health.json")[2])["usage_quiet"], [])

    def test_prune_after_a_year(self):
        old = (datetime.now(timezone.utc) - timedelta(days=web.USAGE_KEEP_DAYS + 5)).strftime("%Y-%m-%d %H:%M:%S")
        con = web.usage_connect()
        con.execute("INSERT INTO page_views (path, actor, ua, added, updated) VALUES ('/', 'human', '', ?, ?)", (old, old))
        con.execute("INSERT INTO usage_events (view_id, path, ms, actor, added, updated) "
                    "VALUES ('view-old-00001', '/', 1, 'human', ?, ?)", (old, old))
        con.commit()
        con.close()
        web._last_prune = 0
        req("/")
        self.assertEqual(db().execute("SELECT COUNT(*) FROM page_views").fetchone()[0], 1)
        self.assertEqual(db().execute("SELECT COUNT(*) FROM usage_events").fetchone()[0], 0)


class ControlsNamed(unittest.TestCase):
    """Every element the page's own handlers act on (data-set, data-eye, data-sel, data-auto, data-chip, data-img,
    data-fr-act) carries data-usage in the same tag; every <button> has an id, a class or a data-usage."""

    def test_names(self):
        src = open(os.path.join(ROOT, "bin", "gen-status.sh"), encoding="utf-8").read()
        acted = re.compile(r"\bdata-(set|eye|sel|auto|chip|img|fr-act)=")
        tags = re.findall(r"<(?:input|select|span|div|label|a)\b(?:[^<>`]|\$\{[^}]*\})*>", src)
        missing = [t[:100] for t in tags if acted.search(t) and "data-usage" not in t]
        self.assertEqual(missing, [], "controls the page acts on with no data-usage name")
        buttons = re.findall(r"<button\b[^>]*>", src)
        self.assertGreater(len(buttons), 5)
        bare = [b for b in buttons if not re.search(r"\b(id|class|data-usage)=", b)]
        self.assertEqual(bare, [], "a <button> with nothing the beacon can name it by")
        self.assertIn("el.dataset.usage='obj-'+k", src, "the canvas objects are built in JS and must be named there")


class Drift(unittest.TestCase):
    UPSTREAM = {
        "usage-beacon.js": (os.environ.get("WORKSHOP_SERVICE_ROOT") or os.path.join(REAL_HOME, "gits/workshop-service"),
                            "infra/_shared/usage-beacon.js"),
        "usage-names.js": (os.environ.get("SONG_JOURNEY_ROOT") or os.path.join(REAL_HOME, "gits/song-journey"),
                           "static/usage-names.js"),
    }

    def test_vendored_copies_match_upstream(self):
        if os.environ.get("WR_NO_UPSTREAM") == "1":
            self.skipTest("WR_NO_UPSTREAM=1")
        for name, (repo, rel) in self.UPSTREAM.items():
            up = os.path.join(repo, rel)
            self.assertTrue(os.path.isfile(up), f"upstream {up} not found: clone it, or WR_NO_UPSTREAM=1 to skip "
                                                f"(couldn't check is not the same as matching)")
            ours = open(os.path.join(ROOT, "web", "vendor", name), encoding="utf-8").read()
            below = ours.split("/* ─── UPSTREAM COPY BEGINS ─── */\n", 1)[1]
            self.assertEqual(below, open(up, encoding="utf-8").read(),
                             f"web/vendor/{name} has drifted from {rel}: run scripts/vendor-usage-beacon.sh")


if __name__ == "__main__":
    unittest.main(verbosity=1)
