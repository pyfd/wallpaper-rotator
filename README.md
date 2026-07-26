# wallpaper-rotator

Auto-rotating **desktop wallpaper** (XFCE, GNOME, Cinnamon, MATE, or a `feh`
fallback) and **login background** (LightDM or GDM), fed from a single image pool that
cron refills every 10 minutes from several sources ([Wallhaven](https://wallhaven.cc),
Bing, [Picsum](https://picsum.photos), or a local folder) with fallback.

Works on any Linux desktop — no dotfiles, no clone, no USB stick needed.

---

## Install (one command, any Linux)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/pyfd/wallpaper-rotator/main/bootstrap.sh)
```

That downloads the repo and runs `install.sh`. Run it **as your normal user**
(not root) — it uses `sudo` only for the system bits and will prompt once.

Prefer to inspect first? Clone and run it yourself:

```bash
git clone https://github.com/pyfd/wallpaper-rotator.git
cd wallpaper-rotator && ./install.sh
```

The installer is **idempotent** — safe to re-run.

---

## How it works

One **image pool** (`~/Pictures/online-wallpapers/`) feeds two consumers:

```
                    ┌─ cron 10-minutely : fetch-wallpaper.sh (multi-source) → pool
   IMAGE POOL  ◄────┼─ cron hourly      : prune to 30 newest
   ~/Pictures/      └─ cron 10-minutely : set-wallpaper.sh → desktop (random pick)
   online-wallpapers
        │
        ├──► DESKTOP : set-wallpaper.sh picks the right backend for your DE
        │             (xfconf / gsettings / feh). Driven by cron, so it works
        │             the same on every desktop — no DE slideshow config.
        │
        └──► LOGIN   : random-login-bg.sh resizes a random image to your screen
                       and writes /usr/share/backgrounds/login-random.jpg; the
                       LightDM greeter or GDM gresource points at it. (see below.)
```

---

## Support matrix

| Desktop environment | Desktop wallpaper | How |
|---------------------|:-----------------:|-----|
| XFCE                | ✅ | `xfconf-query` (native cycler disabled; cron drives) |
| GNOME / Ubuntu / Budgie | ✅ | `gsettings … picture-uri[-dark]` |
| Cinnamon            | ✅ | `gsettings org.cinnamon.desktop.background` |
| MATE                | ✅ | `gsettings org.mate.background` |
| KDE Plasma          | ✅ | `plasma-apply-wallpaperimage` (qdbus `evaluateScript` fallback) |
| Other (i3/openbox/…) | ☑️ | `feh --bg-fill` if `feh` is installed |

| Display manager | Login background |
|-----------------|:----------------:|
| **LightDM** (gtk or slick greeter) | ✅ supported (`background=` greeter key) |
| **GDM** (GNOME) | ✅ supported (rebuilt theme gresource — needs `libglib2.0-dev-bin`) |
| SDDM / none | ⏭️ skipped (desktop rotation still works) |

GDM has no plain config key for the greeter background — the login wallpaper is
the GNOME-Shell theme's `#lockDialogGroup` rule baked into a `*.gresource`.
`bin/build-gdm-greeter.sh` rebuilds the active theme's gresource with a random
pool image **embedded** as the login-background asset and selects it via
`update-alternatives` (manual, reversible). Embedding (rather than pointing at an
external file) is required — St silently fails to load an external `file://`
background in the greeter, so the image must live inside the gresource, exactly
like the stock theme. Rotation therefore rebuilds the gresource (`--refresh`),
which the login autostart does each login (~1-2s) so the next login is fresh.
Re-run the script after a major `gnome-shell`/theme update to rebase on the new
theme. (The GNOME **lock screen** already mirrors your current desktop wallpaper
blurred, independent of this.) SDDM stays out of scope; desktop rotation works
regardless.

### Existing wallpaper managers (Variety, Wallch, GNOME slideshow…)

If another rotator is **actively running**, ours would fight it over the desktop
(both set the same wallpaper property). On install, if one is detected you're
asked:

```
! existing wallpaper rotator detected: variety
Disable it so wallpaper-rotator owns the desktop? [y/N]
```

- **Yes** — it's stopped and its autostart disabled (user entry renamed to
  `.desktop.disabled`; a system entry masked with `Hidden=true`), so we own the desktop.
- **No** (default) — we **coexist**: the existing tool keeps the desktop, and we
  install only the image pool + LightDM login background (Variety etc. don't touch
  the login screen, so that combo is conflict-free).

Non-interactive: pass `--yes-disable` or `--no-disable`. With no terminal, it
defaults to coexist. A *dormant* (installed but not running) rotator isn't
flagged — only a live one can conflict.

Pass `--no-seed` to skip the one-time bulk quote-pool seed (~144MB) and the
image seed-burst — useful for routine re-installs/updates where the pools are
already populated and you just want to redeploy the latest scripts + cron.

### Distros
Dependency install auto-detects `apt` / `dnf` / `pacman` / `zypper`. Core deps:
`imagemagick` (`convert`), `curl`, a cron daemon. XFCE also needs `xfconf`.
If no package manager is recognised, the installer tells you what to install.

---

## Verify

```bash
ls -t ~/Pictures/online-wallpapers/ | head      # pool filling
crontab -l | grep -A4 wallpaper-rotator          # cron jobs present
/usr/local/bin/set-wallpaper.sh                  # force a desktop change now
/usr/local/bin/set-wallpaper.sh --version        # installed version + when/where installed
identify /usr/share/backgrounds/login-random.jpg # login image (LightDM or GDM)
tail -f ~/.local/state/wallpaper-rotator/wallpaper.log  # activity log (rotate/download/prune + errors)
```

The desktop changes within ~10 min (or immediately at install). The login
background updates on your next login.

---

## The canvas-editor web UI

The wallpaper is an **editable canvas** (2026-06-05 redesign): the current
image fills the page, every overlay (quote / weather / stats / clock / pulse)
is a **draggable object** sitting exactly where it renders — drag one to a
different part of the screen and that IS its position setting. Click an
object (or its layers-panel row) for a floating **inspector** with just that
overlay's controls; the eye toggles it on/off; an **auto-placed tray** above
the canvas holds overlays the renderer positions itself. The pool is a
**filmstrip** along the bottom — click a frame to set it as the wallpaper,
hover for ★ keep / 🚫 ban; ✦ badges mark AI-dreamed images. **Every change
applies instantly** to the real desktop (no Apply button) — the top bar shows
"rendering…" and the canvas refreshes when the new frame is up.
`install.sh` runs it as an **always-on systemd user service**
(`wallpaper-web.service`): auto-starts at login, restarts on crash, always at:

```
http://127.0.0.1:8787
```

Manage it like any user unit:

```bash
systemctl --user status  wallpaper-web      # is it up?
systemctl --user restart wallpaper-web      # after a code update
systemctl --user disable --now wallpaper-web  # turn always-on off
sudo loginctl enable-linger $USER           # optional: also start before login (at boot)
```

To run it ad-hoc instead (foreground, Ctrl-C to stop) — e.g. on a box with no
systemd user session — just call the launcher directly:

```bash
wallpaper-web                       # -> http://127.0.0.1:8787  (Ctrl-C to stop)
```

**What the inspectors control** (each change writes the config, rewrites the
rotate cron line where relevant, and re-renders immediately):

- **Change every** — rotation interval (3 / 5 / 10 / 15 / 30 / 60 min).
- **Quote** — composites a quote onto each wallpaper; **+attribution** adds author /
  source / year. Quotes come from an API cache (`fetch-quotes.sh`, refreshed daily),
  falling back to `fortune`/a bundled list offline. Drawn from a **shuffle-bag** so
  none repeats until every one has been shown; when the bag empties it downloads a
  fresh batch, and a persistent **seen-list** stops a re-download from re-showing a
  quote you've already had (until the whole known set is exhausted, then it cycles).
- **System stats** — composites host / uptime / load / mem / disk / net (primary
  IP + interface, rx/tx throughput from `/proc/net/dev` deltas between renders);
  **sparklines** toggle adds anti-aliased line + area trend graphs (accent
  colour) beside load/mem/rx/tx, drawn from a rolling history.
- **Weather** — a local-weather overlay (wttr.in, no key) showing **current**
  conditions, with a location field (title-cased on display) and an **icon** toggle
  that prepends a condition glyph (`☀ ☁ ☼ ☔ ❄ ⚡`); a **colour** toggle renders that
  glyph in a condition colour (gold sun, blue rain, grey cloud, …). A **forecast**
  toggle adds a second, smaller line with a compact 3-day outlook
  (`Today ☀ 24/14 · Thu ☀ 24/16 · Fri ☀ 24/17`, hi/lo °C, cached ~3h).
- **Clock** — **digital** (big time, optional date, 12/24h) or **analogue** (drawn
  dial with a choice of **faces**: classic ticks, minimal quarter-ticks, dots, or
  12/3/6/9 numerals). Since the wallpaper is a static render, a 1-minute cron
  re-renders the *current* image while the clock is on, so it stays accurate to the
  minute (also keeps weather/stats fresh); no extra render churn when it's off.
- **Background themes** — bias new downloads to one or MORE themes (checkbox
  chips: nature, city, cars, cycling, …); each fetch picks one of the ticked
  themes at random so the pool converges to a mix. Only Wallhaven is theme-aware
  (`q=`), so when themes are set it's tried **first** (Bing/Picsum are untargeted
  fallback). Changing themes fetches a matching image immediately and tops up +
  trims the pool in the background.
- **Overlay style** — the visual treatment for all overlays:
  - **scrim** *(default)* — top/bottom gradient wash + drop-shadowed text, no boxes.
  - **frosted** — blurred "glass" rounded card behind each block + hairline border;
    serif-italic quotes.
  - **editorial** — bottom gradient + bold left-aligned text with an accent bar.
  - **chips** — flat translucent rounded panels.
- **AI dreamed** — new downloads are AI-*generated* (AI Horde, free + anonymous;
  add `AI_TOKEN` to the config for pollinations.ai as a faster path). The prompt
  builds itself from live context — time of day, season, today's weather, your
  background themes — plus optional style words. Normal sources remain the
  fallback whenever generation is slow or down.
- **Pulse** — point a URL at ANY JSON endpoint (http/https/`file://`) and shape
  it with a jq template; each output line renders as a stats-style overlay line.
  Business dashboard, CI status, home automation — your call. The full-width
  control section has a refresh-interval select (1-30 min), a **Test** button
  that dry-runs the URL + template and previews the lines before you Apply,
  and shows what the overlay is currently displaying. Tip: if your endpoint
  returns `{"lines": ["…", "…"]}`, the template is just `.lines[]`.
- **Alerts badge** — set `ALERTS_URL` in the config to any JSON endpoint
  returning `{active:[{severity,title,…}]}`. A one-minute `check-alerts.sh` cron
  polls it; an active **critical** (red) or **warn** (amber) alert renders a loud
  top-centre badge over the wallpaper (re-rendered within ~60s of a change) until
  it clears. Config-file only, empty = off. Turns the desktop into a passive
  status surface for infra/CI/home-automation alerts.
- **Position** — place each overlay at any corner/edge/centre (per-overlay), or
  **auto**: the renderer ranks the image's 9 anchor regions by visual busyness
  and gives each auto overlay the calmest remaining spot (explicit positions
  are reserved first), so text never sits on busy detail.
- **Size / Text / Font** — text size (small/medium/large), text colour (dark /
  light / accent), and font (any installed ImageMagick font from a common set).

**Curation** — three buttons under the thumbnail: **⏭ Next** rotates immediately,
**★ Keep** moves the current image to `favourites/` (a pool subdir that stays in
rotation but is exempt from every pruner, so kept images never age out), and
**🚫 Ban** deletes it and rotates (a replacement is fetched in the background).
A **Favourites** gallery lists everything kept — click a thumbnail to set it as
the wallpaper, ✕ to return it to the prunable pool.

Overlays are rendered onto a *copy* each tick (pool originals stay clean; stats
stay live). State lives in `~/.local/state/wallpaper-rotator/config`, read by
`set-wallpaper.sh` and rewritten atomically by the web UI (cron sources it every
minute, so a half-written config would silently fall back to defaults).

Rendering is spawn-bound — a full composite is ~160 ImageMagick invocations — so
finished layers are cached beside the config: `textcache/` (content-addressed, one
entry per rendered text line, LRU-pruned at 2 days) and `layers/` (the pulse panel
and forecast strip). The quote, weather and pulse blocks are rebuilt only when their
inputs change; stats, the clock and the alert badge are never cached because they are
live. This is what keeps the 1-minute clock refresh affordable. Both caches are
disposable — delete them and the next render repopulates.

`wallpaper.log` is capped at 5,000 lines. The trim banks the per-source download
tallies it drops into `dl-counts`, which `gen-status.sh` adds back, so the UI's source
counters survive a roll.

**Version** — the page shows the installed version in the header (`v2026.06.03`) and
the full id + install date/host in the footer. The version is **derived from the
CHANGELOG** (the newest `## YYYY-MM-DD HH:MM TZ — host` entry), stamped into
`~/.local/state/wallpaper-rotator/version` by `install.sh` — so every CHANGELOG
entry auto-bumps it and each machine's page tells you what it's running. Query it
from the shell with `set-wallpaper.sh --version`.

It binds to `127.0.0.1` by default (no auth — localhost trust; `WEB_BIND` can add the
tailnet IP or an explicit address, which is the only way it reaches the network), needs
`python3`, and the page soft-refreshes its status every 30s (no full reload; form edits
survive). State-changing POSTs are same-origin-checked — localhost trust does not cover
a browser being pointed at `127.0.0.1` by whatever site you happen to be visiting — and
`file://` pulse feeds are confined to `~/.local/state/wallpaper-rotator/feeds`. It runs always-on under the `wallpaper-web`
systemd user service (above); after pulling a code update,
`systemctl --user restart wallpaper-web`. Change the port via `WEB_PORT` in
`install.sh`.

**Remote access (optional)** — flip the **Remote access** toggle in the
controls (or set `WEB_BIND="tailscale"` in the config) to ALSO bind this
machine's Tailscale IP, so you can curate from a phone on your tailnet — the
page and footer show the reachable URL. Applying the toggle restarts the
server (back in ~2s). Any explicit IP works too via the config. There's still
no auth — only open it to networks where everyone is allowed to control the
wallpaper.

---

## Image sources

The pool is filled by `bin/fetch-wallpaper.sh`, which pulls from several sources
for **variety** and falls through on failure for **resilience**. Each run shuffles
the enabled sources and tries them in that order until one yields a valid image
(non-trivial, decodable — tiny HTML error bodies are rejected); if all fail, the
pool is left unchanged and rotation continues on what's there.

| Source | Key? | Notes |
|--------|:----:|-------|
| `wallhaven` | none | Purpose-built wallpapers, screen-ratio matched (`atleast=<RES>`), SFW. |
| `bing`      | none | Bing's curated daily images (1920×1080). |
| `picsum`    | none | Random photos — the always-works fallback floor. |
| `local`     | n/a  | A local folder (`LOCALDIR`), used only if it exists and has images. |

The JSON sources (`wallhaven`, `bing`) need `jq` (installed automatically).

## Customise

- **Sources / priority** — edit `SOURCES` (space-separated) and `LOCALDIR` near the
  top of `install.sh`, then re-run it. Or edit the substituted values at the top of
  `/usr/local/bin/fetch-wallpaper.sh` directly.
- **Rotation/download frequency** — change the `*/10` schedules in `cron/wallpaper.cron`.
- **Pool size** — change `tail -n +31` (keep-30).
- **Login resolution** — auto-detected via `xrandr` (falls back to 1920×1080); override `RESOLUTION=` in `/usr/local/bin/random-login-bg.sh`.

---

## Uninstall

```bash
./uninstall.sh            # remove cron, scripts, autostart, sudoers, login image; keep the pool
./uninstall.sh --purge    # also delete ~/Pictures/online-wallpapers/
```

---

## Repo layout

```
wallpaper-rotator/
├── README.md
├── CODE_AUDIT.md                          # 2026-07-26 full-codebase review: findings, measurements, what was deliberately left alone
├── bootstrap.sh                           # curl one-liner entrypoint
├── install.sh                             # idempotent, DE/DM/distro-aware installer
├── uninstall.sh
├── bin/
│   ├── fetch-wallpaper.sh                   # multi-source pool fetcher w/ fallback (templated)
│   ├── set-wallpaper.sh                    # DE-aware desktop wallpaper setter (templated)
│   ├── random-login-bg.sh                  # login-image generator (templated)
│   ├── build-gdm-greeter.sh                # rebuilds the GDM theme gresource → login bg
│   ├── gen-status.sh                        # builds state.json + the canvas-editor app shell (templated)
│   ├── wallpaper-web.py                      # status + control server (serve, POST /set) (templated)
│   └── wallpaper-web.sh                     # launcher: execs the Python server (templated)
├── cron/wallpaper.cron                     # download + prune + rotate (templated)
├── systemd/user/wallpaper-web.service       # always-on web UI as a user service (templated)
├── autostart/random-login-bg.desktop       # refresh login image at login
├── sudoers.d/random-login-bg               # passwordless sudo for the login generator
└── greeter/lightdm-gtk-greeter.conf.snippet
```

Templated files use `@@POOL@@`, `@@SETWP@@`, `@@FETCH@@`, `@@GENSTATUS@@`,
`@@PYBIN@@`, `@@WEB_BIN@@`, `@@LOG@@`, `@@WEBDIR@@`, `@@PORT@@`, `@@CONFIG@@`, `@@INTERVAL@@`,
`@@RES@@`, `@@SOURCES@@`, `@@LOCALDIR@@`, `@@TARGET@@`, `@@RESOLUTION@@`,
`@@USER@@` placeholders that `install.sh` substitutes per-machine. (The scripts
guard the un-substituted form with split literals like `"@@POOL""@@"` so the
substitution can't rewrite the guard.)

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Desktop not changing | Run `/usr/local/bin/set-wallpaper.sh` by hand. If that works but cron doesn't, cron lacks your session bus — confirm `/run/user/$(id -u)/bus` exists and `DISPLAY=:0` is correct for your box. |
| Wrong DE detected | `echo $XDG_CURRENT_DESKTOP`; the setter also sniffs running `*-session` processes when run from cron. |
| Login bg never changes | Is `~/.config/autostart/random-login-bg.desktop` present and `sudo /usr/local/bin/random-login-bg.sh` passwordless? On GDM also confirm `update-alternatives --query gdm-theme.gresource` shows the `-wr` gresource selected; re-run `bin/build-gdm-greeter.sh` after a `gnome-shell`/theme update. |
| Pool not filling | `grep download ~/.local/state/wallpaper-rotator/wallpaper.log`; test `curl -fsL https://picsum.photos/1600/900 -o /tmp/t.jpg`. |
| Desktop config changes but screen doesn't (KDE) | The setter prefers `qdbus … evaluateScript` (applies live); `plasma-apply-wallpaperimage` only updates config and won't repaint a running Plasma 5.x session. Check `backend=` in the log — `plasma-apply(config-only)` means no qdbus was found. |
| No package manager | Install `imagemagick`, `curl`, and a cron daemon manually, then re-run. |
