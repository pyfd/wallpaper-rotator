# Changelog

All notable changes to wallpaper-rotator are recorded here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/).
Entry headers carry the date + local time + machine the change was made on
(`## YYYY-MM-DD HH:MM TZ — <host>`).

## 2026-06-03 06:01 BST — Fam3

### Changed
- **Sparklines are now drawn graphics, not unicode block chars.** The old
  `▁▂▃▄▅▆▇█` row read like terminal ASCII-art and clashed with the frosted/scrim
  panels + coloured icons. Replaced with an anti-aliased **line + soft area-fill
  sparkline** drawn with ImageMagick (`draw_spark`), in the accent blue (`#7cc4ff`)
  that ties to the editorial accent bar and weather icon. To place the graphic
  precisely beside the load/mem lines, the stats panel is now assembled
  line-by-line (`stat_label` → fixed-height rows → vertical append) instead of one
  caption. Refactored `emit()` into `style_block()` (positions/styles a ready-made
  block PNG) + `emit()` (builds a text/icon block then calls it), so both text
  overlays and the composite stats block share the panel/positioning/collision
  code. Removed the old unicode `sparkline()` helper.

## 2026-06-03 05:51 BST — Fam3

### Added
- **Coloured weather icons** (new `OVERLAY_WEATHER_ICON_COLOR` + "colour" checkbox
  next to the icon toggle). When on, the condition glyph is rendered in a
  characteristic colour — gold `☀`, soft-amber `☼`, grey `☁`, blue `☔`, pale-blue
  `❄`, yellow `⚡` — instead of the overlay text colour. The glyph is rendered as
  its own trimmed element (always DejaVu-Sans, which has the glyphs) and prepended
  to the text, vertically centred with a small gap; `weather_line` now emits
  `glyph<TAB>colour<TAB>text` so the caller can render the icon separately.
  Monochrome icons (colour off) stay inline in the text as before.

## 2026-06-03 05:44 BST — Fam3

### Fixed
- **Overlay panels carried dead space** (stats panel was ~68% empty to the right).
  `mktext`'s `caption:` pads the block to the full `-size` width regardless of how
  short the text is, and the frosted/chips panel inherited that width. Added
  `-trim +repage` so each block crops to its actual text bbox (measured 598→193px
  on the stats lines); the width arg still bounds wrapping. Panels now hug their
  content; positioning/collision-avoidance key off the (now smaller) `bw/bh` so
  they keep working — the `northeast` block just sits flush to the right edge.

## 2026-06-03 05:35 BST — Fam3

### Fixed
- **Overlays could overlap each other** (weather=north ran into stats=northeast —
  both anchored to the top edge, since each overlay was positioned independently
  with no awareness of the others). Added a collision-avoidance pass: after a
  block's anchor position is computed it's nudged along its anchored axis
  (North*/centre → down, South* → up) until it clears every already-placed block,
  tracked in a `PLACED` rectangle list. Footprint padding (36px) covers the
  largest style panel so frosted/chips panels clear too, not just the text. The
  later-emitted block yields (weather drops below stats); generic — works for any
  position combination, not just this pairing.

## 2026-06-03 05:28 BST — Fam3

### Added
- **Weather overlay icons, with a UI toggle** (`OVERLAY_WEATHER_ICON`, new "icon"
  checkbox next to the weather location). Prepends a monochrome glyph mapped from
  the wttr.in condition — `☀` clear, `☁` cloud/overcast/fog, `☼` partly, `☔` rain,
  `❄` snow, `⚡` thunder. Glyphs are restricted to ones the overlay font (DejaVu
  Sans) actually contains — verified by render-test; `⛅` (partly-cloudy) is NOT in
  DejaVu and renders as tofu, so partly uses `☼`.

### Changed
- **Weather location is now title-cased** ("shoreham" → "Shoreham", "new york" →
  "New York"). wttr.in echoes `%l` in the case it was queried (lowercase); the
  overlay now capitalises it. The weather cache changed to structured fields
  (`loc|condition|metrics`) so location-casing and the icon toggle apply at render
  time without re-fetching; a legacy single-line cache is shown verbatim until it
  refreshes. Also trims the trailing space wttr's `%C` carries.
- **Quotes no longer render in Title Case.** Root cause was the source data, not
  our pipeline: the `dummyjson` API ships some quotes pre-mangled in Title Case
  (tell-tale `Can'T`). `fetch-quotes.sh` now (a) prefers the well-cased sources
  (`zenquotes`, then `quotable`) over `dummyjson`, and (b) runs a conservative
  normaliser that de-Title-Cases only fully title-cased quotes (≥80% of words
  capitalised) into sentence case, preserving ALL-CAPS acronyms and leaving
  properly-cased quotes (incl. proper nouns like "Bay of Bengal") untouched.

### Fixed
- **Font dropdown only ever showed "default".** A pre-existing pipefail bug in
  `gen-status.sh`: the font-availability check was `printf … | grep -qx "$fc"`, and
  under `set -o pipefail` grep -q's early exit SIGPIPEs printf (exit 141), so the
  pipeline reported failure even on a match — every candidate font was rejected.
  Switched to a here-string (`grep -qxF -- "$fc" <<<"$avail_fonts"`); all installed
  fonts (DejaVu/Liberation/Free families) now populate the dropdown.

## 2026-06-03 05:15 BST — Fam3

### Added
- **Web UI is now always-on via a systemd user service** (`wallpaper-web.service`).
  Previously the status + control page only existed while you kept `wallpaper-web`
  running in a terminal. `install.sh` now installs a templated `--user` unit to
  `~/.config/systemd/user/wallpaper-web.service` (substituting `@@WEB_BIN@@` →
  `/usr/local/bin/wallpaper-web`) and runs `systemctl --user enable --now`, so the
  page auto-starts at every login and restarts on crash — `http://127.0.0.1:8787`
  is just always there. A per-user localhost daemon is the natural fit for a
  `--user` unit (mirrors the box's existing `battery-warn` user units). The
  ad-hoc `wallpaper-web` launcher still works for boxes with no systemd user
  session. Optional `loginctl enable-linger` documented for pre-login/boot start.
  Install gracefully degrades (prints the manual `systemctl --user enable` command)
  when run without an active user session.

## 2026-06-02

### Fixed
- **Desktop rotation silently failed under cron on GNOME variants** (Zorin, and
  any setup whose session binary name is suffixed). `set-wallpaper.sh`'s
  no-`XDG_CURRENT_DESKTOP` fallback (the cron case) used `pgrep -x gnome-session`,
  but the running process is `gnome-session-binary` *and* the kernel truncates the
  comm name to 15 chars, so the exact match missed → `de=unknown` → it fell through
  to the `feh` branch → exit 127, wallpaper never set (desktop showed the GNOME
  fallback colour). Now matches the full command line via `pgrep -f` and maps to a
  clean DE keyword (`gnome`/`xfce`/`cinnamon`/`mate`/`plasma`); same hardening
  applied to `install.sh`'s detection fallback.
- **install.sh summary printed a hardcoded "rotates every 10 min"** regardless of
  the configured interval (the cron line itself was always correct). Now reports
  the actual `$CFG_INTERVAL`.

### Changed
- **Overlays completely restyled, with a style chooser.** Replaced the old
  per-line `-undercolor` boxes (ragged, unstyled, clunky) with four polished
  treatments selectable from the web UI ("Overlay style" → `OVERLAY_STYLE`,
  default `scrim`):
  - **scrim** — top/bottom gradient wash + drop-shadowed text, no boxes (default).
  - **frosted** — blurred "glass" rounded card behind each block + hairline
    border; serif-italic quotes.
  - **editorial** — bottom gradient + bold left-aligned text with an accent bar.
  - **chips** — flat translucent rounded panels.
  Text is now rendered via wrapped `caption:` with a soft drop shadow (or a real
  rounded/blurred panel) instead of opaque per-line rectangles. Each style still
  honours the enable toggles, positions, size, text colour (the old "Style"
  dark/light/accent control, relabelled "Text") and font override. Threaded
  through `set-wallpaper.sh`, `gen-status.sh`, `wallpaper-web.py` and the install
  default config.
- **Rotation no longer repeats the last image back-to-back.** The random pick now
  drops the previously-applied original (tracked in `current`) from the candidate
  list before shuffling, so consecutive ticks always change the picture when the
  pool has more than one image. Falls back to the unfiltered shuffle for a
  single-image pool; first run (no `current`) filters nothing.
- **First install now seeds a batch of images** (`SEED_COUNT`, default 15) instead
  of a single one, so random rotation has real variety from the first tick rather
  than repeating one image until cron slowly fills the pool. Each fetch shuffles
  sources so the batch is varied; only runs when the pool is empty (re-installs
  don't re-seed), and stays under the keep-30 prune ceiling.

### Docs
- Corrected the install.sh header and README intro, which still described the
  pool as refilled "from picsum.photos" only — it has been multi-source
  (Wallhaven, Bing, Picsum, local, with fallback) since the sources rework.

### Added (sources, overlays, weather, sparklines)
- **API-sourced quotes with local cache** — `fetch-quotes.sh` refreshes a local
  `quotes.cache` (text|author||) from a quotes API (dummyjson → zenquotes →
  quotable, first that works), cron-refreshed daily; `set-wallpaper.sh` picks a
  random cached quote (so they keep changing), falling back to `fortune`/bundled
  when the cache is empty. Feeds the `+attribution` toggle (author).
- **Local weather overlay** — a third overlay (host/wttr.in, no key), cached ~1h;
  config `OVERLAY_WEATHER` / `WEATHER_POS` / `WEATHER_LOCATION` + web UI toggle,
  position and location field.
- **Backgrounds by theme** — `THEME` config routed to Wallhaven `q=<theme>`
  (read live from config by `fetch-wallpaper.sh`); Bing/Picsum stay as untargeted
  fallback. Web UI background-theme select.
- **Load/RAM sparklines** — `STATS_SPARKLINE` toggle draws unicode block
  sparklines (▁▂▃▄▅▆▇█) beside load/mem from a rolling `metrics.csv` (last 30
  samples; bash/awk, no deps).
- **Fix:** bottom-edge overlays now inset 80px so a quote/stats at the South edge
  clears a desktop panel/taskbar (was hidden behind it). Config values are now
  quoted on write so `WEATHER_LOCATION` with spaces survives shell sourcing.
  Verified in-browser: weather + stats(+sparkline) + API quote(+attribution) +
  themed background all render together on KDE Plasma.

### Docs
- Added `TODO.md` (roadmap): API-sourced quotes w/ local cache, local-weather
  overlay, backgrounds-by-theme, load/RAM sparklines — each with a feasibility note.

### Added (overlay customisation)
- **Quote attribution** — bundled quotes now carry author / source / year; a
  **+attribution** toggle renders e.g. "… — Socrates, Apology (Plato) (~399 BC)".
  (`fortune` still used when attribution is off.)
- **Per-overlay position** — quote and stats can each be placed at any
  corner / edge / centre (`QUOTE_POS` / `STATS_POS` → ImageMagick gravity).
- **Size / theme / font** — text size (small/medium/large → pointsize), theme
  (dark / light / accent → fill + undercolour), and font (any installed
  ImageMagick font from a common set; falls back to default if unavailable).
- New config keys (`OVERLAY_QUOTE_DETAIL`, `QUOTE_POS`, `STATS_POS`,
  `OVERLAY_SIZE`, `OVERLAY_THEME`, `OVERLAY_FONT`); the web UI form gained the
  matching selects/checkboxes (validated server-side). Verified in-browser:
  quote+attribution top-left, stats bottom-right, large accent DejaVu-Serif.

### Added (web UI controls + overlays)
- **Interactive controls in the web UI.** The status page now has a controls form
  (`Apply` → POST `/set`): **rotation interval** (3/5/10/15/30/60 min, rewrites the
  rotate cron line), **quote overlay** toggle, and **system-stats overlay** toggle.
  The static `python3 -m http.server` is replaced by a small `wallpaper-web.py`
  (`BaseHTTPRequestHandler`, 127.0.0.1 only) that serves the page + thumbnail and
  handles the control POST (writes `config`, rewrites crontab, applies immediately,
  regenerates). Config lives at `~/.local/state/wallpaper-rotator/config`.
- **Overlays** (rendered by `set-wallpaper.sh` via ImageMagick onto a *copy* each
  tick, so pool originals stay clean and stats stay live; the derived frame gets a
  unique name so KDE repaints): **quote** (bottom; `fortune` if present, else a
  bundled list) and **system stats** (top-right: host, uptime, load, mem, disk).
  Rotate log gains an `overlay=…` tag.
- **Fixed** a status-page tally bug: `grep -c … || echo 0` printed `0\n0` for
  zero-count rows (e.g. `local 0 0`, `fails 0 0`) — `grep -c` already prints `0` and
  exits non-zero, so the `|| echo 0` doubled it. Capture directly + default instead.
- Rotate interval is now config-driven in the cron template (`*/@@INTERVAL@@`),
  preserved across re-installs. `uninstall.sh` removes the new bins + (on `--purge`)
  the state dir. (All verified live in-browser on KDE Plasma 5.24.7.)
- **Fixed overlay clipping.** Overlays were annotated onto the source image, which
  the DE then crop-fills to the screen — pushing the top-right stats / bottom quote
  off-screen. The overlay frame is now first resized + center-cropped to the screen
  resolution (`set-wallpaper.sh` gains `@@RES@@`), so text lands where it's visible.
- **Apply no longer shuffles the picture.** The control POST re-applied a *random*
  image, so changing an interval/overlay also jumped to a new wallpaper.
  `set-wallpaper.sh` now records the current pool original (`…/current`) and the
  server re-applies *that* on Apply — only overlays/interval change, not the image.
  (Scheduled cron rotations still pick a fresh random image.)

### Added (web UI)
- **Local status web front end.** New `bin/gen-status.sh` builds a self-contained
  status page (current wallpaper thumbnail, pool size/disk, per-source download
  tallies, miss/fail counts, prune totals, recent activity, config) from the
  activity log + pool. `bin/wallpaper-web.sh` (installed as `wallpaper-web`) serves
  it **on demand** via `python3 -m http.server` bound to `127.0.0.1:8787` — no
  always-on process, no network exposure. Cron regenerates the page each tick so it
  stays fresh while the server runs; the page auto-refreshes every 30s. `python3`
  added as a dependency; port configurable via `WEB_PORT` in `install.sh`.

### Added (image sources)
- **Multi-source fetcher with fallback** — new `bin/fetch-wallpaper.sh` replaces the
  single hardcoded picsum download. Pulls from **Wallhaven** (purpose-built wallpapers,
  screen-ratio matched via `atleast=<RES>`, SFW), **Bing** (curated daily images),
  **Picsum** (random floor), and an optional **local folder** (`LOCALDIR`). Each run
  shuffles the enabled sources (variety) and tries them in order until one yields a
  *valid* image — validated as non-trivial + `identify`-decodable, so tiny HTML error
  bodies are rejected (resilience). If all fail, the pool is left unchanged and rotation
  continues. Sources/priority configurable via `SOURCES`/`LOCALDIR` in `install.sh`;
  JSON parsed with `jq` (added as a dependency). Each fetch logs `src=<name> ok|miss` /
  overall `fail`. Cron now calls the fetcher instead of an inline curl.
- *Note:* the `@@...@@` substitution guards in the templated scripts use split string
  literals (`"@@X""@@"`) so `install.sh`'s sed doesn't rewrite the fallback checks
  themselves (an earlier `case *@@X@@*` form broke post-substitution on values with
  spaces and wrongly blanked `LOCALDIR`).

### Added
- **KDE Plasma desktop support.** `set-wallpaper.sh` now sets the desktop on KDE
  Plasma via `plasma-apply-wallpaperimage`, with a `qdbus`
  `org.kde.PlasmaShell.evaluateScript` fallback for older Plasma that lacks it.
  No `feh` needed. Plasma is detected from `XDG_CURRENT_DESKTOP`/`plasmashell`,
  and the cron path reuses the existing session-bus/`DISPLAY` re-establishment.
  `install.sh` adds a soft dependency check (warns if neither
  `plasma-apply-wallpaperimage` nor `qdbus` is present; no package is force-installed,
  as the setter ships with `plasma-workspace`). Support matrix updated.
  `set-wallpaper.sh` also now exports `XDG_RUNTIME_DIR` (derived from the uid) when
  unset and bases the D-Bus session address on it — X11 Plasma works without it,
  but Wayland sessions locate the bus via `XDG_RUNTIME_DIR`, so cron ticks there
  would otherwise fail to reach plasmashell.
  *Verified live on KDE Plasma 5.24.7 + SDDM (X11):* desktop rotates (incl. from a
  stripped cron-like env), login correctly skipped, install idempotent on re-run.

### Fixed
- **KDE wallpaper now actually changes on the live desktop.** The KDE backend
  preferred `plasma-apply-wallpaperimage`, which on Plasma 5.x only updates the
  config file and does **not** repaint the running session — so the cron rotation
  silently changed config and the desktop never visibly updated. The setter now
  **prefers `qdbus … org.kde.PlasmaShell.evaluateScript`** (runs inside plasmashell,
  applies live across all desktop containments and persists config), falling back
  to `plasma-apply-wallpaperimage` only when no `qdbus`/`qdbus6` is present.
  Verified the live flip both interactively and from a stripped cron-like env.

### Added (logging)
- **Activity log** at `${XDG_STATE_HOME:-~/.local/state}/wallpaper-rotator/wallpaper.log`
  (off `/tmp`, so it survives reboots). `set-wallpaper.sh` logs each rotate with the
  detected DE, backend, image, and the backend's **real exit status** (backend stderr
  is appended to the log instead of being discarded). Cron logs download ok/fail and
  prune counts; the login generator logs ok/fail/skip. Self-trimming to the last ~1000
  lines so it can't grow unbounded. README troubleshooting/verify updated to the new path.

### Notes
- Login background remains **LightDM-only**. KDE's default display manager is
  **SDDM**, which is theme-bound and intentionally out of scope — on a KDE+SDDM
  box the desktop rotates but the login screen is skipped.

## Baseline (prior to 2026-06-02)

- Portable, idempotent installer for an auto-rotating **desktop wallpaper**
  (XFCE / GNOME / Cinnamon / MATE, `feh` fallback) and a **LightDM login
  background**, fed by a single image pool that cron refills from picsum.photos.
- Multi-distro dependency install (`apt` / `dnf` / `pacman` / `zypper`) and a
  `curl | bash` bootstrap.
- Detects an actively-running rotator (Variety / Wallch / GNOME slideshow) and
  offers to disable it, else coexists (installs pool + login only).
