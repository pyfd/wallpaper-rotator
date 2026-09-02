# Changelog

All notable changes to wallpaper-rotator are recorded here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/).
Entry headers carry the date + local time + machine the change was made on
(`## YYYY-MM-DD HH:MM TZ — <host>`).

## 2026-09-02 04:22 BST — Fam3

alerts: staleness fails loud, and names the cause (tailscale) instead of blanking

### Fixed
The infra-alert badge suppressed itself whenever alerts.json went stale (>10 min), so an unreachable ALERTS_URL painted a BLANK desktop — and on an alerting surface "nothing on screen" is indistinguishable from "nothing wrong". Found on Fam3 2026-09-02: the local Tailscale node was stopped, every check-alerts.sh poll failed silently, and a live critical (btn-beryl-laravel at 10.79/core) went unshown for hours. The :8787 web UI still listed it the whole time — it reads the same file with NO freshness gate, so the two surfaces disagreed about the same data.

set-wallpaper.sh: a stale or never-fetched cache now draws a muted grey band ("infra alerts STALE — last good fetch 2 Sep 03:40") instead of skipping the block. Gated on ALERTS_URL being set, so machines not using alerts stay clean; ALERTS_URL added to the defaults block.

check-alerts.sh: on failure it now records WHY into $STATEDIR/alerts.fail (cleared on success) — it is the only component that actually observes the failure, so the renderer displays a recorded reason rather than re-deriving one a minute later. Since these aggregator URLs are tailnet-only, it checks the local node via `tailscale status --json .BackendState` (82ms, once/min) and reports "tailscale stopped" / "tailscale needs login" — phrased as an observation, not a diagnosis, because ALERTS_URL need not be a tailnet host. The badge appends it: "… · tailscale stopped".

Verified on Fam3 by back-dating alerts.json: grey band with and without a recorded reason, then a real refresh restoring the red critical band unchanged. bash -n clean on both scripts.

## 2026-08-03 16:54 BST — Fam1

### Added
- **Weather: "use current location"** (`WEATHER_AUTO_LOCATION`, default off) — the
  overlay can now follow a machine that travels instead of a town pinned months
  ago. Resolves the location by IP (ipinfo.io over HTTPS; ip-api.com as fallback,
  which is HTTP-only without a key, hence second), caches the fix ~6h in
  `geoip.txt` as `lat,lon|Town` with the same `.fail` backoff the weather
  fetchers use, and asks wttr.in by **coordinates**. The resolved town name is
  carried separately for display because wttr.in, asked by coordinates, echoes
  those coordinates back as `%l` — "50.83,-0.27" is no use on a wallpaper.
  Both current-conditions and 3-day forecast honour it. The typed location stays
  editable and is the fallback whenever the lookup fails, so an offline or
  rate-limited machine degrades to its old behaviour rather than a blank overlay.
- The web UI shows the fix it resolved (`geo-IP · London (51.5085,-0.1257)`) next
  to the toggle, and the canvas object labels itself with the resolved town.
  Deliberately visible, because **IP geolocation locates the connection, not the
  machine**: measured from a Shoreham line, ipinfo returned London and wttr.in's
  own built-in geo-IP returned Granborough — 75–110km out, carrier egress rather
  than the premises. Auto is right for a machine that moves; a machine that stays
  put is better off pinned, which is why the default is off.

### Fixed
- **Changing the weather location kept showing the old town** — pre-existing, and
  it would have made auto-location look broken. `weather.txt` (~1h) and
  `forecast.raw` (~3h) are keyed by nothing on disk, so editing the field in the
  web UI left the previous town's conditions on the wallpaper until the TTL
  expired. Each fetcher now stamps the location it used (`weather.loc`,
  `forecast.loc`) and refreshes when that differs — which is also what makes a
  moving machine's overlay follow it. Verified: a warm Shoreham cache switched to
  Manchester on the next render, while an unchanged location still reused its
  cache (no extra fetch).

## 2026-07-26 06:14 BST — Fam3

Started from a UI bug ("dragged overlays spring back after a delay"), which turned
into a full read of the codebase. Findings, measurements and the reasoning behind
each fix are written up in `CODE_AUDIT.md`.

### Fixed
- **Dragged overlays sprang back to their old zone.** Three compounding defects.
  (1) `gen-status.sh` forked `jq -n` once per pool image — 48.7s of its 54s runtime
  with 369 images. (2) `regen()`'s 30s timeout therefore killed it every time, and
  since `state.json` is written atomically at the very end, the poll path could never
  refresh state at all. (3) The client had no optimistic state: `refresh()` replaced
  `S` wholesale and rebuilt every overlay from `S.cfg`, so any `state.json` arriving
  before the server caught up reverted the drop. Measured: drop at 05:26:03, revert
  05:26:11, correct again 05:27:08. Now the pool list is one `jq` per folder
  (byte-identical output, differential-tested over 370 files incl. 50 `.ai.jpg`),
  the regen timeout is 90s, `/state.json` also regenerates when the config is newer
  than the snapshot, and `/setone` pins written keys over incoming state until the
  server echoes them back. Verified in a real browser: zero reverts across 5 minutes
  and ~15 poll cycles, including rapid successive drags. **gen-status 54.1s → 1.9s.**
- **The 1-minute clock cron re-rendered everything: 10.4s wall / 9.3s CPU** — a trace
  counted 118 `convert` + 42 `identify` spawns at ~60ms each, rebuilding blocks whose
  inputs had not moved. Added layer caching: a content-addressed store behind
  `mktext`/`stat_label` (covers the quote caption, weather line, every stats row and
  every pulse row; LRU-pruned at `-mtime +2`), block-level caches for the pulse panel
  and forecast strip, and a memoised framed base. **10.4s → 3.9s**, spawns 118 → 61.
  Placement is untouched — `avoid()` makes block order significant to layout, so the
  blocks were deliberately *not* reordered into static/dynamic phases. Verified: base
  cache pixel-identical to a fresh convert (AE=0); cold vs warm renders differ only
  inside the stats block, which is live by design.
- **`write_config()` could be read half-written.** It truncated the config in place
  while cron sources it every minute, so a render landing mid-write silently fell back
  to defaults. Now writes a temp file and `os.replace()`s it, and the read-modify-write
  in `/set` and `/setone` is serialised (two rapid saves could previously lose one).
- **Temp directories leaked.** `_pl.$$`/`_fc.$$` were removed only on the happy path;
  7 orphans had accumulated. Added a `trap ... EXIT INT TERM` plus a startup sweep.
- **A dead `PULSE_URL` cost a 6s curl on every render** (once a minute). Given the same
  `.fail` back-off fence the weather fetch already had.
- **`exec 9>lock 2>/dev/null` silenced stderr for the whole script.** `exec` with no
  command applies its redirections permanently, so the suppression meant to hide a
  failed lock-open discarded every unredirected error for the rest of the run. Scoped
  to the lock-open with braces.

### Security
- **Cross-site POSTs are rejected.** There was no `Origin`/`Referer`/token check, so
  any site the user visited could POST to `127.0.0.1:8787` on their behalf — including
  `/ban`, which deletes the on-screen pool image and needs no filename. Same-origin (or
  header-less, i.e. curl) requests still pass.
- **`file://` pulse feeds are confined to `$STATE/feeds`.** `/pulse_test` returns the
  fetched body, so an unrestricted `file://` scheme was an arbitrary local file read for
  anyone who could reach the port — inert at the default localhost bind, but `WEB_BIND`
  can put this on the tailnet. `http(s)` feeds are unaffected.
- **Image paths are `shlex.quote`d** before going into detached shell chains. Pool names
  are generated so this was latent, but a hand-added `Paul's photo.jpg` would have broken
  straight out of the quoting.

### Changed
- **`wallpaper.log` is capped** at 5,000 lines (trimmed in batches). It had no rotation
  at all while `gen-status` scanned it several times per UI poll. The trim banks the
  per-source download tallies it drops into `dl-counts` and `gen-status.sh` adds them
  back, so the UI's source counters don't walk backwards; verified on a synthetic
  8,000-line log across two trims.
- **`regen()` coalesces** instead of letting a poll burst spawn concurrent runs — but a
  waiter only reuses an in-flight run that finished *after* its own request.

## 2026-07-23 18:49 BST — Fam1

### Fixed
- **Tall overlay teleported to the opposite edge (pulse rendered northeast over
  stats, config said southeast).** `avoid()` nudges a colliding block along its
  anchored axis; the taller sectioned pulse board grazed the centred quote's
  *padding* at southeast, got nudged up past the quote, then past northeast
  stats, ended off-screen (`y=-658`) — and the final clamp slammed it to `OY=0`:
  top-right, straight over the stats it had been dodging. Now, if clearing every
  placed block walks the candidate off-screen, it reverts to its configured
  anchor and accepts the residual (usually pad-vs-pad) overlap instead of
  clamping onto the opposite edge. Applies to all overlays, both axes.

### Changed
- **`install.sh` auto-migrates `PULSE_JQ` to the sectioned feed.** Machines that
  configured the pulse overlay before the section-headings release (14:15 entry
  below) still had `PULSE_JQ='.lines_kv[]'` in local config, so the new board
  never appeared — each box needed a hand edit. The installer now does the
  one-time upgrade itself: if config holds the old `.lines_kv[]` template it
  probes the configured `PULSE_URL`, and only when the feed actually serves a
  `.display[]` array rewrites the template and drops the cached `pulse.txt` so
  the next rotate renders sections. Unreachable/legacy feeds are left untouched
  (retried at the next install). Net effect: a plain `wr-update` is enough to
  get the sectioned pulse everywhere. Follows the existing ALERTS_URL /
  LOGIN_ROTATE config-migration pattern.

## 2026-07-23 14:15 BST — Pixel-8

### Added
- **Pulse overlay: section headings + a lifted line cap.** The SCB pulse feed
  (`workshop-service /api/pulse`) now emits Today / This week / This month
  sections, so the overlay needed to (a) render group headings and (b) show more
  than the old hard-coded 8 lines.
  - **`## Section` header lines** — a pulse line beginning `## ` renders as an
    accent-coloured heading (a touch larger than the rows, small top gap) instead
    of a `label|value` row (`set-wallpaper.sh`). Point `PULSE_JQ` at `.display[]`
    for the sectioned feed; `.lines_kv[]` still gives the flat today-only digest.
  - **`PULSE_MAX` config knob (default 20)** replaces the hard-coded 8-line cap
    in the render loop — the old `8` was only a protective guard, not a real
    limit; the true limit is screen height + font size. Settable from the web UI
    (Pulse panel → *max lines*: 8/12/16/20/24) and whitelisted in
    `wallpaper-web.py`. `gen-status.sh`'s live preview reads up to `PULSE_MAX`
    too. Raise it for a taller board, lower it to keep the overlay compact.

### Fixed
- **Deselecting the last theme chip now saves as "any".** Clicking the sole
  active theme chip (e.g. `nature`) to clear all themes returned
  `400 "no valid setting in request"` and the toast read *save failed*. Two
  faults compounded, both fixed:
  - **Client (`gen-status.sh`):** an empty theme array serialised to an *empty*
    POST body — `setone()` now appends the key with an empty value, so the
    request carries `theme=""`.
  - **Server (`wallpaper-web.py`):** `/setone` parsed the body with
    `parse_qs`'s default `keep_blank_values=False`, which *dropped* `theme=""`
    before the theme branch could see it — still an empty form → same 400. Now
    parsed with `keep_blank_values=True`, so the blank survives, filters to no
    themes, and stores `THEME=""` (= "any"). Verified end-to-end in-browser
    (200 `{"ok":true}`, toast "themes: any", `THEME=''` persisted).

## 2026-07-17 07:12 BST — Fam1

### Changed
- **No-repeat cycle stretched from hours to months.** The real cause of the
  recurring déjà vu was never the shuffle-bag — it was a hard **60-image pool
  cap** (hourly cron prune) plus web-UI theme/AI flushes that pruned to **12**.
  At a 10-min rotation the whole pool cycled in well under a day, so the same
  wallpaper reappeared daily. Three coordinated changes remove the ceiling:
  - **`POOL_MAX` config knob (default 5000).** The hourly cron prune and every
    web-UI flush now cap at `POOL_MAX` instead of 60/12; favourites/ stays
    excluded. 5000 images ≈ **2+ months** of no-repeats at a 10-min rotation
    (~72 picks/day); raise it for longer, lower to reclaim disk (~1.5 MB/image).
    Read live from the config, so no reinstall needed to retune. The prune now
    also counts `.jpeg`/`.png`, not just `.jpg`.
  - **`images.seen` cap 500 → 50000** (`set-wallpaper.sh`). With a large pool
    the 500-entry memory would let images shown early in a cycle resurface
    before the cycle ended; the cap must exceed `POOL_MAX` for the
    once-per-cycle guarantee to hold.

### Added
- **Perceptual (aHash) de-duplication at fetch** (`fetch-wallpaper.sh`). The
  existing md5 guard only catches byte-identical re-downloads; curated feeds
  re-serve the *same picture* at a different resolution/quality/crop (different
  bytes → md5 sees it as new → the bag shows it as a "different" wallpaper). An
  8×8 average-hash is resolution/quality-independent: candidates within
  `PHASH_MAXDIST` (default 6 of 64 bits) of any pool image are discarded. Backed
  by a synced `images.phash` fingerprint index (drops pruned files, hashes new
  ones — cheap in steady state). Verified: a resized+recompressed copy hamming=0
  (caught) vs 22 between two genuinely different images. Falls back to md5-only
  when ImageMagick is absent.

**Deploy:** run `wr-update` on each machine — the new 60→`POOL_MAX` cron only
takes effect after `install.sh` regenerates the crontab; until then the old
60-cap is still pruning. Pool then grows ~50-140/day toward `POOL_MAX` over a
few weeks, with the no-repeat window lengthening as it fills.

## 2026-07-14 06:45 BST — Fam1

### Added
- **Desktop badge now carries the alert date/times too** (the 05:56 change only
  covered the web UI). Each badge line appends when the alert fired
  (`13 Jul 19:49`) and, for a cleared-but-unacked critical,
  `· cleared 19:51` (date included when it cleared on a different day).
  Title cap trimmed 80→64 chars to make room. GNU-`date`-formatted; the suffix
  is silently omitted where `date -d` is unavailable.

## 2026-07-14 05:56 BST — Fam1

### Added
- **Alert banners now carry their date/time.** Each infra-alert banner in the web
  UI shows when the condition first fired (`13 Jul 18:49`, UK-style, year only
  when not current) — and, for a cleared-but-unacked critical, `· cleared HH:MM`.
  Previously a 2-minute blip that auto-recovered was indistinguishable from an
  ongoing outage until you checked the aggregator.
- **Per-alert "Copy a Claude investigation prompt" button** (same copy/tick icon
  pattern as the infra-heatmap's Needs-attention cards): copies a ready-to-paste
  brief built from the live alert entry — host/check/severity/title/body/value,
  first/last seen, ACTIVE vs CLEARED-until-acked status, dashboard links, and
  assess-first instructions. `navigator.clipboard` on secure contexts
  (127.0.0.1), hidden-textarea `execCommand` fallback for plain-http LAN visits.

## 2026-07-05 19:44 BST — pixel-8

### Fixed
- **GDM login-background build now handles self-contained `gdm.css`-only greeter
  themes (#312 — completes the 2026-06-27 fix).** With Fam3 back online the actual
  root cause was confirmed: its GDM greeter theme (`gdm-theme.gresource` →
  `ZorinBlue-Dark/gnome-shell-theme.gresource`, auto-selected at priority 20) ships
  **only `gdm.css`** — there is no `gnome-shell.css` or any `gnome-shell*.css`
  member at all (Zorin flattens the full rule set into the greeter's own
  `gdm.css`). So the previous discovery, which searched only for
  `gnome-shell*.css`, still hit the `no gnome-shell stylesheet` error on the box
  that originally reported the bug. `build-gdm-greeter.sh` now adds a third
  discovery tier — falling back to **`gdm.css`** (the greeter stylesheet itself)
  when no in-session sheet is present — and injects the `#lockDialogGroup`
  background rule there. Unchanged on Fam1/stock (still prefers `gnome-shell.css`,
  which the greeter's `gdm.css` `@import`s). Verified the 3-tier discovery resolves
  to `gdm.css` against Fam3's real ZorinBlue-Dark gresource; `bash -n` clean.

## 2026-06-27 06:29 BST — paul-e210

### Fixed
- **GDM login-background build no longer assumes a flat `gnome-shell.css`
  (#312).** `build-gdm-greeter.sh` hardcoded the shell stylesheet at
  `$BUILD/gnome-shell.css` after extracting the source theme gresource, and bailed
  with `gnome-shell.css not in source gresource` when a distro theme didn't ship it
  at exactly `/org/gnome/shell/theme/gnome-shell.css` (reported on Fam3, wr-update
  2026.06.15, ZorinBlue-Dark). It now **discovers** the stylesheet from the
  extracted tree — preferring an exact `gnome-shell.css` (shallowest match), then a
  `gnome-shell*.css` variant — so a nested (`<Theme>/gnome-shell.css`) or renamed
  (`gnome-shell-dark.css`) layout works too. The embedded login-background asset is
  now placed **alongside the stylesheet** (`CSS_DIR/assets/…`) so its CSS-relative
  `url()` resolves whether the CSS is flat or nested. On total failure the error now
  **dumps the actual gresource entry list + source path** instead of a blind
  message, so a still-unhandled layout is self-diagnosing on the next run.
  Verified no-regression against Fam1's real ZorinBlue-Dark gresource (Zorin 17.3 —
  flat `gnome-shell.css`, discovery + paths byte-identical to before) plus synthetic
  flat/nested/variant/both/none cases. The originating box (Fam3) is offline, so the
  exact Fam3 layout is still unconfirmed — its next wr-update will either just work
  or print the real entry list. `bash -n` clean.

## 2026-06-15 06:32 BST — Fam1

### Added
- **"Randomise on each login" toggle in the login-background panel (`:8787`).** The
  login background previously *always* re-rolled at each login; now it's a setting.
  New `LOGIN_ROTATE` config key (default `1` = rotate, matching prior behaviour).
  The per-login autostart entries now pass a **`--login`** flag, and
  `random-login-bg.sh` / `build-gdm-greeter.sh` read `LOGIN_ROTATE` and no-op on the
  `--login` path when it's `0` — so login keeps the last image. Crucially the
  manual **"Refresh now"** button (and `install.sh`) omit `--login`, so an explicit
  refresh always rebuilds regardless of the toggle. Web side: `LOGIN_ROTATE` added to
  `CFG_KEYS`/defaults + the `/setone` BOOLS map (`login_rotate`); `/loginbg.json`
  returns `rotate`; toggling it is config-only (no desktop-wallpaper re-render). The
  scripts gain a `@@CONFIG@@` placeholder (substituted by `install.sh`) so they can
  read the toggle when run as root at login. Files: `bin/wallpaper-web.py`,
  `bin/gen-status.sh`, `bin/random-login-bg.sh`, `bin/build-gdm-greeter.sh`,
  `autostart/{random-login-bg,gdm-login-bg}.desktop`, `install.sh`.

## 2026-06-15 06:15 BST — Fam1

### Added
- **Login-background panel in the web UI (`:8787`).** The canvas-editor settings
  menu gains a **🔐 Login background** card: display manager (GDM / LightDM /
  unsupported), active status, the current source image + last-refresh time, a
  live thumbnail preview, and a **Refresh now** button that re-rolls the next
  login image on demand. Backend (`bin/wallpaper-web.py`): `GET /loginbg.json`
  (DM detected via `/etc/X11/default-display-manager` + `systemctl`; source image
  + timestamp parsed from the `[login]`/`[gdm]` lines in `wallpaper.log`; target
  mtime), `GET /loginbg.jpg` (serves the current
  `/usr/share/backgrounds/login-random.jpg` for the preview), and
  `POST /loginbg-refresh` (runs the *same* refresh the per-login autostart uses —
  `sudo build-gdm-greeter.sh --refresh` on GDM, `sudo random-login-bg.sh` on
  LightDM — via the passwordless `/etc/sudoers.d` rule, so no password prompt).
  Frontend (`bin/gen-status.sh`): new `login` entry in `CANVAS_ITEMS`, rendered by
  an async `loadLoginBg()` since the state isn't carried in the polled
  `state.json`. No new config keys — login rotation remains install-managed; the
  panel is status + on-demand refresh.

## 2026-06-15 04:00 BST — Fam1

### Added
- **GDM (GNOME) login-background support.** Until now the rotating login
  background only worked on LightDM (a plain `background=` greeter key). GDM has
  no such key — the login wallpaper is the GNOME-Shell theme's `#lockDialogGroup`
  rule, compiled into a `*.gresource`. New `bin/build-gdm-greeter.sh` rebuilds the
  *active* theme gresource (rebased on the highest-priority real theme, e.g.
  ZorinBlue-Dark — not stock GNOME) with our image **embedded** as the
  `assets/login-background.png` asset, then selects it via `update-alternatives`
  (manual mode, fully reversible with `--remove`). The image is embedded — not
  referenced by path — because St (the shell CSS engine) silently fails to render
  an external `file://` background in the greeter sandbox; embedding is exactly
  how the stock theme ships its own login image, so it renders reliably. Rotating
  the login image therefore means rebuilding the gresource (`--refresh` picks a
  random pool image), which the login autostart does each login (~1-2s) so the
  next login shows a fresh image. We always rebase on the stock theme, never on
  our own output, so re-runs don't compound.
- `install.sh` now detects GDM and wires the GDM path (install
  `build-gdm-greeter.sh` to `/usr/local/bin`, build+select once, passwordless
  sudoers + login autostart that re-runs `--refresh`). LightDM keeps its existing
  `random-login-bg.sh` + `background=` path. GDM requires `gresource` +
  `glib-compile-resources` (`libglib2.0-bin` + `libglib2.0-dev-bin`) and
  ImageMagick; if absent it skips the login background with a hint and leaves
  desktop rotation working.
- `uninstall.sh` reverts the alternative, removes the custom gresource, the GDM
  build script, its sudoers entry and autostart.

### Notes
- The GNOME **lock screen** (locking an active session) already shows the current
  desktop wallpaper blurred on GNOME 40+, so it tracks the desktop rotation for
  free — this feature is specifically about the **GDM greeter** (boot / logout /
  switch-user). A fresh greeter is needed to pick up a rebuilt gresource (log out
  / reboot; a resident switch-user greeter may show the previous image).
- An external `file://` background was tried first and rendered only the CSS
  fallback colour (St limitation) — embedding is the fix.
- Re-run `build-gdm-greeter.sh` after a major `gnome-shell`/theme package update
  to rebase on the new stock theme. A postinst running `update-alternatives --auto`
  could in theory revert the manual selection; the one-line fix is to re-run the
  script (or `update-alternatives --set`). An apt-hook guard is a possible future
  hardening, not yet implemented.
- First shipped on Fam1 (Zorin OS, GNOME Shell 43.9, Wayland, GDM3).

## 2026-06-13 07:28 BST — Fam1

**TODO.md flipped to a generated mirror (todo-system cutover).** `TODO.md` is now
a generated read-only mirror of the DB-backed todo system (SQLite + audited API
on scb-ubuntu; see dotfiles `TODO_SYSTEM_DESIGN.md`). Don't hand-edit — manage
items via `~/cldev/scripts/todo` (regenerated on `go`/`sg`). This repo's 2 todo
items were migrated into the store.

## 2026-06-10 06:08 BST — Fam1

### Changed
- **Public-hygiene scrub: removed the last internal-infra references.** A prior
  scrub cleaned the GUI mockups but left a few stragglers: an example comment in
  `install.sh` (the `ALERTS_URL` hint), the same internal hostname/endpoint
  echoed in two older changelog entries, and the author's pulse jq template
  (`value="…"`) hard-coded in three mockups. Genericised the comment to a
  `your-aggregator-host` placeholder, redacted the changelog mentions, and
  swapped the mockup template to a neutral `.items[]`. No installed-code or
  behaviour change. (Per-machine SCB endpoints live only in the author's private
  dotfiles, never here.) Working tree now clean of internal hostnames.

## 2026-06-09 05:06 BST — Fam3

### Fixed
- **Wallpaper alert badge overflowed with multiple alerts.** It joined every
  alert title into one line that ran off both screen edges and was unreadable.
  Now each alert renders on its **own line** (criticals first, ⚠ per line), the
  badge is capped at 5 lines with a **"+N more"** summary, and the band colour is
  red if any critical else amber. A static wallpaper can't scroll, so stacking is
  the fix. `set-wallpaper.sh`.
- **Acked banner lingered.** `/alerts.json` served the on-disk cache that
  `check-alerts.sh` only refreshes every 60s, so after an Ack (which succeeds at
  the aggregator → toast fires) `pollAlerts()` re-read the stale cache and
  re-drew the banner for up to a minute. The web server now fetches `/alerts.json`
  **live from the aggregator** (3s timeout, falls back to the cache if
  unreachable, and refreshes the cache so the wallpaper badge stays current too);
  the Ack handler also removes the banner optimistically for instant feedback.
- **Alert banner / overlays-menu overlap.** The infra-alert panel (Phase 3) sits
  in normal flow at the top, but the overlays menu (`.layers`) is `position:fixed`
  at `top:60px` and was drawing over the **left half of the alert banners** (only
  the right-hand "…GB free" was visible). `pollAlerts()` now pushes `.layers`
  down to just below the banner while any alert is active (handles variable
  banner height) and restores the CSS default when clear — both the banners and
  the menu are fully visible. Verified in-browser on Fam3.

## 2026-06-08 22:40 BST — Fam3

### Added
- **Infra-alert panel + Ack in the web UI (Phase 3 of the alerting channel).**
  The `:8787` page now shows active **critical** (red) / **warn** (amber) alerts
  as a banner under the top bar, each with an **Ack** button — so an alert is
  visible and dismissible from the browser, not only as the wallpaper badge.
  New server endpoints in `wallpaper-web.py`: `GET /alerts.json` serves the live
  cache `check-alerts.sh` maintains; `POST /ack` proxies the browser's ack to the
  aggregator's keyless `/api/alerts/ack` (derived from `ALERTS_URL`), stamping
  this machine's hostname. The panel polls every 20s, independent of the main
  render loop. Cross-machine ack is automatic — every wr polls the same
  aggregator, so an ack on one box clears the badge everywhere next cycle.

## 2026-06-08 19:33 BST — Fam3

### Added
- **Infra-alert badge (subscriber side of an external alerting channel).** New
  `bin/check-alerts.sh` polls a JSON alerts endpoint (set `ALERTS_URL` in the
  config to enable — empty = off, the default) once a minute and caches the
  active set to `~/.local/state/wallpaper-rotator/alerts.json`. When an active
  **critical** (red) or **warn** (amber) alert is present and the cache is fresh
  (<10 min), `set-wallpaper.sh` renders a loud top-centre badge with a ⚠ glyph
  and the alert title(s), drawn over every other overlay. The poller re-renders
  the current image when the active set changes, so a badge appears within ~60s
  independent of the rotate/clock crons. `install.sh` deploys the poller, wires
  the 1-min cron, and seeds the `ALERTS_URL=` config key (back-filled into
  existing configs). No new dependencies (reuses ImageMagick + jq + curl).
  Generic by design — point `ALERTS_URL` at any endpoint returning
  `{active:[{severity,title,...}]}`. `ALERTS_URL` is also listed in the web
  UI's `CFG_KEYS` (config-file-only, like `WEB_BIND`/`AI_TOKEN`) so a settings
  save preserves it instead of silently dropping the badge. README documents the
  badge under the web-UI feature list.
- **`install.sh --no-seed`** — skips the one-time bulk quote-pool seed (~144MB
  Quotes-500K download, runs in background) and the image seed-burst. Intended
  for routine re-installs/updates where the pools are already populated and you
  only want to redeploy the latest scripts + cron. Both seed steps now print a
  "skipping … (--no-seed)" line instead of running. Documented in README under
  the non-interactive flags. Pairs with the new dotfiles `wr-update` alias
  (`git pull && install.sh --no-disable --no-seed`).

### Changed
- **Scrubbed internal details from the 6 GUI design mockups** (`mockups/gui-*.html`).
  They used the author's real setup as the pulse example — a real internal
  hostname + pulse URL, real branding, and live-shaped business metrics — none
  secret, but internal-infra/business details with no place in a public repo.
  Genericised to `example.com/status.json` + neutral queue/server stats. Mockups
  only; no installed-code or behaviour change.

## 2026-06-06 04:57 BST — Fam1

### Fixed
- **"Same image again" on freshly-installed machines** (Paul, Fam1, ~04:45) —
  NOT the duplication bug: the 06-05 md5 dedup was verified working here
  (dup-discard lines in the log, zero duplicate hashes in the pool). The
  actual cause: Fam1's pool held only **18 images, all <90 min old**, so the
  5-min rotation legitimately cycled every ~90 min. Root cause in install.sh:
  the seed step only ran on a COMPLETELY empty pool — a machine with a
  handful of images skipped it and waited ~10h for the 10-min cron to
  drip-fill to the keep-60 ceiling.
  - **Seed-burst**: install.sh now tops the pool up to `SEED_TARGET=55`
    whenever it holds fewer than `SEED_MIN=30` at install time (was: 15
    fetches, empty-pool-only). The loop counts pool GROWTH, not fetch
    attempts — sources re-serve pictures during a burst and the md5 dedup
    discards them (observed live: wallhaven/bing dups discarded, fell
    through to picsum) — capped at 3× the shortfall. Sandbox-tested with a
    simulated 33% dup rate.
  - Fam1's pool hand-seeded 18 → 63 the same minute; the install.sh change
    makes that automatic for the next machine.

## 2026-06-05 19:57 BST — Fam3

### Fixed
- **Image duplication** (Paul: "sooo much duplication with the images — I
  thought we'd fixed?"). The 06-04 shuffle-bag DID stop pick-repeats, but the
  duplication was upstream: curated feeds re-serve the same picture for hours
  (Bing's 8-image daily archive especially — 23 bing fetches today), and every
  re-download landed as a NEW pool file under a fresh timestamped name. By
  tonight 13 of 84 pool files were byte-copies of just 4 pictures, so the bag
  honestly rotated through "different" files showing the same wallpaper.
  - **fetch-wallpaper.sh now content-hash dedups at accept time**: candidate
    md5 checked against the whole pool (favourites included); matches are
    discarded and the fetcher moves to the next source.
  - **Logging for future verification** (Paul's ask): every discard logs
    `[download] src=X dup (md5 matches <file>) -- discarded, trying next
    source` — verified live the same minute (two forced bing fetches both
    matched + discarded). Health check: `md5sum pool/* | sort | uniq -cd`
    should stay empty while dup-discard lines appear in the log.
  - **Rotate log now carries `bag=N/M`** (unseen-in-bag / pool size) so bag
    resets and pool churn are visible in the history too.
  - One-time cleanup: the 9 redundant copies deleted from Fam3's pool
    (84 → 75 files, 0 duplicate hashes; bag self-heals — missing files are
    skipped at pop time).

## 2026-06-05 19:33 BST — Fam3

### Fixed
- **"Next still not working" follow-up** — the 19:14 fix was live server-side
  but the browser kept running the OLD poll JS: the web server sent no cache
  headers, so Chrome heuristically cached `index.html` and a plain reload
  didn't fetch the regenerated page (old 4-tick poll expired before the ~12s
  render landed → canvas never updated). `_send()` now sets
  `Cache-Control: no-cache` on everything (it's all server-regenerated), so
  fixes reach the browser on a normal reload. One last hard refresh
  (Ctrl+Shift+R) is needed to shed the already-cached copy.

## 2026-06-05 19:14 BST — Fam3

### Fixed
- **⏭ Next felt dead** (Paul: "clicking Next but wr isn't changing"). Two
  causes, both fixed:
  1. **Action POSTs ran the full render synchronously** — a rotate is
     CPU-bound (~11.5s overlay composite on Fam3, more when wttr.in is slow)
     and `/next` blocked until it finished (measured 15.6s), so the button
     looked like a no-op. `/next`, `/ban` and `/use` now fire
     `set-wallpaper.sh` detached (`Popen`, the same pattern the canvas editor
     already used) and skip the synchronous `_done()` regen (~6s of
     gen-status producing state that was stale the moment the rotate landed).
     `/next` now responds in ~3ms; the UI polls `/state.json` until the new
     wallpaper appears. Poll window extended 4→10 ticks (~27s) to cover the
     render; toasts reworded to "rotating…" so they don't claim completion.
  2. **Failed wttr.in fetches retried inline on every render** — a fetch
     failure leaves the cache mtime old, so while wttr.in was flaky (20s
     timeout seen in tonight's log) every rotate paid up to 12s (weather) +
     15s (forecast) of curl. Both fetchers now drop a `.fail` marker and back
     off for 10 minutes, serving the stale cache meanwhile.

### Fixed
- **Quote theme "any" rejected by instant-apply** — the inspector's select
  says "any" but the config stores "" for it; `/setone` validated against the
  raw value and 400'd ("no valid setting"), surfacing as a fleeting toast
  error (Paul's catch, minutes after ship). Server now maps any→"" .
  Error toasts also linger 4.5s (were 1.7s — too quick to read).

## 2026-06-05 07:00 BST — Fam3

### Changed
- **Web GUI rebuilt as a "canvas editor"** (Paul: the old two-column page was
  "a mess — spread over two pages, disjointed"; chosen from 6 mockups, E).
  The wallpaper IS the page: overlays are draggable objects positioned where
  they really render — dropping one on the 3×3 snap grid sets its `*_POS`;
  clicking opens a floating per-overlay inspector; the layers panel's eye
  toggles features; an auto-placed tray holds `auto`-positioned overlays; the
  pool is a filmstrip (click = set wallpaper, hover ★/🚫, ✦ = AI). **Every
  control applies instantly** — no Apply button, no form drift; the page
  polls `state.json` and shows a "rendering…" pill while the desktop updates.
  - `gen-status.sh` now emits `state.json` (config + pool + live overlay
    content + counters) and a static app shell that renders entirely
    client-side, plus a clean-original `canvas.jpg` for the editor backdrop.
  - `wallpaper-web.py` gains `/setone` (instant per-control apply with the
    full `/set` side-effect parity: cron rewrite, AI-converge, themed-fetch,
    web-bind restart, pulse-cache drop — all detached so responses are
    instant), `/img-act` (use/fav/unfav/ban any named pool image),
    `/dream` (one-shot forced AI gen via `WR_FORCE_SRC=ai`), `/thumb`
    (cached filmstrip thumbnails), `/state.json` (throttled regen) and
    `/canvas.jpg`. Legacy `/set` kept for rollback.
  - `fetch-wallpaper.sh`: `WR_FORCE_SRC` env forces a single source, no
    fallback (the Dream button's contract).
  - Verified live on Fam3: drag Quote south→west→south wrote `QUOTE_POS` and
    re-rendered the real desktop each time; eye-toggled Clock on/off;
    inspector reflects live state (incl. 30k quote pool / bag counts);
    filmstrip thumbs + current ring + ai badges all live. Design mockups
    (3 conventional + 3 paradigm) kept in `mockups/`.

## 2026-06-05 05:30 BST — Fam1

### Added
- **Network info + sparklines in the system-stats overlay** — three new lines
  under disk/bat: `net <ip> (<iface>)` (primary-route interface + IPv4 from
  `ip route get`), then `rx <rate>/s` and `tx <rate>/s` computed from
  `/proc/net/dev` byte-counter deltas between renders (state in
  `$STATEDIR/net.prev`; rate lines appear from the second render, counter
  resets after reboot are skipped). With **Sparklines** on, rx/tx each get the
  same accent line+area trend graph as load/mem — `metrics.csv` grows to 4
  columns (`load,mem%,rx_Bps,tx_Bps`; old 2-column rows are tolerated).
  Degrades to no net lines where `ip`/`/proc/net/dev` aren't available
  (Termux). No new config — rides the existing stats/sparkline toggles.

## 2026-06-04 21:22 BST — Fam3

### Added
- **Quote-linked AI images ("Match image to quote")** — new Quote-group toggle
  (`QUOTE_MATCH_IMAGE`): each AI generation draws a random quote from the
  shuffle-bag (cache fallback) and builds its prompt from the quote text
  instead of THEME ("an evocative, beautiful scene inspired by the quote:
  ..., no text, no words"); on success the quote is saved as a
  `<image>.quote` sidecar. The renderer prefers the sidecar when that image
  is on screen (marks it seen + pulls it from the bag so it doesn't repeat
  unlinked). Orphaned sidecars swept every fetch (prune/Keep/Ban only touch
  the jpg). Verified on Fam3: gratitude quote → serene golden-meadow gen.
- **Kudos-adaptive Horde frame** — registered keys: 704x448 (the KudosUpfront
  ceiling moved to 705px for registered) or full 1024x576+ when the account
  holds ≥15 kudos (balance checked per gen via `find_user`); anonymous stays
  640x384. `AI_HORDE_KEY` set on Fam3 (registered, queue priority).

### Fixed
- **Tags leaked into quote attribution** — 5-field cache lines spilled the
  tags field into `year`, rendering "(education, happiness, ...)" after the
  author. The detail parser now reads the 5th field explicitly.

## 2026-06-04 21:04 BST — Fam3

### Fixed
- **AI dreamed gens all silently missing (Horde KudosUpfront)** — AI Horde now
  403s anonymous requests over 665px ("KudosUpfront" policy), so every
  1024x576 submit failed in ~1s (`src=ai miss`). Anonymous gens now use
  640x384 (largest allowed 64-multiple frame; renderer crop-fills up); new
  optional `AI_HORDE_KEY` config (free stablehorde.net registration) restores
  full-res. Verified: first-ever `.ai.jpg` landed on Fam3 ~70s after the fix.
- **First-ever quote seed/refresh failed with no cache file** — the merge
  began `cat "$TMP" "$CACHE"`; with no cache yet, cat exits 1 and pipefail
  skipped the `mv`, so no cache was ever written (self-perpetuating). Inner
  cat now tolerates a missing cache.

### Added
- **Quote themes in the web UI** — new "theme" select in the Quote group
  (any / love / life / inspirational / humor / philosophy / wisdom /
  happiness / hope / success / romance / friendship / science). The bulk seed
  now keeps each quote's Quotes-500K category tags as a 5th cache field;
  `QUOTE_THEME` filters the shuffle-bag by tag substring (falls back to the
  whole pool when nothing matches, e.g. unseeded cache); theme changes
  rebuild the bag on the next render via a marker file.

## 2026-06-04 20:50 BST — Fam3

### Added
- **Bulk quote seeding (`fetch-quotes.sh --seed`)** — answers "the ~1450-quote
  pool will exhaust eventually": samples 30k length-filtered quotes from the
  Quotes-500K dataset (HuggingFace mirror, 144MB CSV, python3-parsed; fallback
  ~9k from dwyl/JamesFT/quotable GitHub sets), merged into the cache. Cache cap
  raised 500 → 50k, seen-history bound 1k → 60k to match. install.sh
  auto-seeds in the background when the cache is unseeded (<2000 lines).
  ~2 months of 3-min rotations with zero repeats; daily refreshes merge on
  top, and a future exhausted bag tops up before any history reset.

## 2026-06-04 20:41 BST — Fam3

### Fixed
- **Quote repetition (round 2)** — the shuffle-bag was sound but the refetch
  path defeated it: `fetch-quotes.sh` OVERWROTE the cache with each batch, and
  both fallback sources serve near-static batches (dummyjson without `skip` is
  literally the same 30 every call; zenquotes' free endpoint returned an
  identical 50 twice in a row when tested). A batch fully covered by the seen
  history emptied the bag and triggered the run-dry history reset — hence
  visible repeats. Now: dummyjson random-pages (`skip=$((RANDOM%1400))`) and
  refreshes MERGE into the cache (dedupe by text, newest first, cap 500), so
  the known pool grows toward hundreds and the no-repeat cycle stretches with it.

## 2026-06-04 20:37 BST — Fam3

### Changed
- **Pulse overlay restyled** — was 8 flat mono lines ("ready 8"), now: lines
  containing `|` render as two aligned columns (muted label left, ACCENT
  value right-aligned) so the numbers pop and carry context; new optional
  `PULSE_TITLE` config renders a header with a freshness time (cache mtime,
  `@ HH:MM`) over a thin accent rule. Plain lines unchanged — the overlay
  stays generic for any JSON endpoint. Web UI gains a Pulse "title" field
  (persisted via wallpaper-web; gen-status renders it). Pair with any
  key-value JSON status endpoint (e.g. `.items[]`) for this shape.

## 2026-06-04 20:25 BST — Fam3

### Added
- **Battery line in the stats overlay** — `bat 76% discharging` (capacity +
  status from the first `/sys/class/power_supply/BAT*`) appended under the
  disk line. Machines with no readable battery (desktops, Termux) skip the
  line entirely; the panel build now uses a file array instead of the fixed
  0–4 list so optional lines can join.

### Fixed
- Removed a stray root-level `set-wallpaper.sh` duplicate that the 14:08
  mirror committed to the standalone repo (the real script lives in `bin/`).

## 2026-06-04 14:08 BST — paul-HP-ProDesk-400-G4-SFF

### Changed
- **No-repeat image rotation (shuffle-bag)** — the 5-min rotate now draws from
  a shuffled queue (`images.bag` + `images.seen`, the same mechanism the quote
  overlay uses) so no image repeats until every pool image has shown once,
  then the cycle reshuffles. Replaces the plain `shuf -n1` pick, which
  produced obvious deja vu well inside a cycle. Pruned files are skipped at
  pop time; new downloads join at the next bag rebuild; single-image pools
  degrade gracefully.
- **Pool ceiling raised 30 → 60** (hourly prune keeps the 60 newest) — paired
  with the bag this gives a ~5-hour no-repeat cycle at the default 5-min
  rotation. Disk cost ~25 MB.

## 2026-06-04 11:51 BST — paul-HP-ProDesk-400-G4-SFF

### Fixed
- **"✦ dreamed" badge hidden behind the desktop panel** — it composited
  +12+8 from the image's bottom-right, and KDE/Cinnamon taskbars (~44-48px)
  cover exactly that strip, so on panel-at-bottom desktops the signature was
  never visible. Raised to +14+72 (clears typical panels with breathing room — Paul's
  eyeball after seeing +50 sit tight against the taskbar).

## 2026-06-04 11:34 BST — paul-HP-ProDesk-400-G4-SFF

### Fixed
- **KDE desktop frozen: cron runs misdetected the DE as GNOME** — with no
  `XDG_CURRENT_DESKTOP` under cron, the process-sniff fallback's bare
  `pgrep -f 'gnome-session'` matched **`at-spi2-registryd --use-gnome-session`**
  (the accessibility daemon, present on every desktop) and GNOME was checked
  before plasma — so on a KDE box every cron rotate set gsettings keys Plasma
  never reads, logging `status=ok` while the visible wallpaper never changed
  (875 such runs on paul-HP; only env-carrying manual/web-UI runs worked).
  Detection now checks the unambiguous sessions first (xfce, cinnamon, mate,
  plasma) and GNOME last with an anchored `(^|/)gnome-session` pattern that
  can't match the at-spi2 flag. Same fix applied to install.sh's cosmetic
  detection. (Surfaced as "rotator stopped working" right after the Pulse
  overlay was saved — coincidental; Pulse also needed a `PULSE_URL`.)

## 2026-06-04 07:42 BST — Fam1

### Fixed
- **Minute clock-refresh cron silently died after the config switched to
  single-quote escaping** (06:26): the cron line matched `OVERLAY_CLOCK="1"`
  literally, so once an Apply rewrote the config as `'1'` the every-minute
  re-render stopped (clock could lag up to the rotate interval). The match is
  now quote-agnostic (`=.?1`).

## 2026-06-04 07:37 BST — Fam1

### Changed
- **AI generation requests are now uncensored** (`nsfw:true, censor_nsfw:false`)
  per user preference — the worker returns the image as generated instead of
  substituting the card on a classifier false-positive. The censored-flag
  rejection stays as a net for workers that force-censor regardless.

## 2026-06-04 07:36 BST — Fam1

### Fixed
- **AI Horde "CENSORED" card no longer saved as a wallpaper.** A worker NSFW
  false-positive (on a sky prompt!) replaces the generation with a black
  text card and sets `generations[].censored` — one landed on the desktop.
  fetch_ai now checks the flag and rejects the card (falling through to the
  normal sources); the response was otherwise indistinguishable from a valid
  image.

## 2026-06-04 07:29 BST — Fam1

### Added
- **Subtle "✦ dreamed" signature on AI-generated wallpapers** — tiny, ~40%
  opacity, bottom-right edge. AI fetches are now named `*.ai.jpg` so
  provenance travels with the file (including into `favourites/`) with no
  manifest; the GUI's Current-image card also tags them "✦ AI dreamed".

## 2026-06-04 06:57 BST — Fam1

### Changed
- **Pulse gets a full-width control section** in the form: position + refresh
  interval (1/5/15/30 min, new `PULSE_TTL`), wide URL + jq-template fields, a
  **Test button** that dry-runs the URL + template server-side (new
  `/pulse_test` endpoint) and previews the lines without applying, and a live
  view of what the overlay is currently showing. Changing the URL/template
  also drops the cached lines so the Apply re-render fetches fresh.

## 2026-06-04 06:49 BST — Fam1

### Fixed
- **Apply hung on "Applying…" when switching AI dreamed on** — the convergence
  fetch ran synchronously inside the POST, and an AI generation takes minutes.
  The AI-on path now converges entirely in the background (generate → show →
  top up 3 more → prune → regen page); Apply returns immediately and the first
  dreamed image appears on the desktop when ready (~1-3 min).

## 2026-06-04 06:26 BST — Fam1

### Added
- **AI-dreamed wallpapers**: an `AI dreamed` toggle makes every new download try
  image *generation* first (normal sources stay as fallback). The prompt builds
  itself from live context — time of day, season, today's weather from the
  forecast cache, the picked background theme — plus optional user style words.
  Backend is **AI Horde** (stablehorde.net): free, anonymous, ~30s-few-minutes
  per image (pollinations.ai was tried first but its anonymous tier is
  rate-limited away; set `AI_TOKEN` in the config to use it as a fast path).
  Turning the toggle on fetches + shows one immediately, then tops up in the
  background.
- **Pulse overlay**: point `PULSE_URL` at ANY JSON endpoint (http/https/file://)
  and shape it with a `PULSE_JQ` template — each output line renders as a
  stats-style overlay line (max 8, cached 5 min). Business dashboards, CI
  status, home automation — whatever JSON you have.
- **Auto overlay placement**: every position select gains **auto** — the
  renderer ranks the 9 anchor regions of the current image by visual busyness
  (grayscale std-dev, cached per image) and gives each auto overlay the calmest
  remaining spot, reserving explicitly-placed overlays first. Text stops
  landing on busy detail.
- **Remote access controls in the GUI**: a `Remote access` toggle binds/unbinds
  the tailnet IP (config `WEB_BIND`; applying a change self-restarts the
  server), and the page + footer show the reachable tailnet URL when active.

### Changed
- Config is now written with single-quote shell escaping so jq templates,
  quotes and `$` in values survive sourcing verbatim.

## 2026-06-04 06:14 BST — Fam1

### Fixed
- **Stale-tab Apply no longer reverts settings changed elsewhere.** The form in
  an open tab never updated (soft refresh deliberately leaves it alone), so an
  Apply from a long-open tab silently submitted old state over newer config.
  Untouched fields now self-sync to the saved config on every soft refresh;
  fields the user has actually edited stay put (and count as in-sync again
  after a successful Apply).

## 2026-06-04 06:09 BST — Fam1

### Added
- **Curation buttons** under the web UI thumbnail: **⏭ Next** (rotate now),
  **★ Keep** (move to `favourites/` — stays in rotation forever: the pool
  subdir is found by set-wallpaper's recursive pick but every pruner globs
  only the top level), **🚫 Ban** (delete from pool + rotate; a replacement
  fetch tops the pool back up in the background). Pool card shows `★ N kept`.
- **Favourites gallery** in the web UI (collapsible, open by default):
  thumbnails of everything kept — click one to set it as the wallpaper,
  ✕ to move it back to the prunable pool. Served via the new `/fav/<name>`
  route; `/use` and `/unfav` endpoints.
- **Tailnet remote access**: new `WEB_BIND` config key (not in the form;
  service restart to apply). `WEB_BIND="tailscale"` also binds this machine's
  tailnet IP — control any machine's wallpaper from a phone; an explicit IP
  works too; default stays localhost-only. No auth — only open it to networks
  where everyone may control the wallpaper.
- **Multi-theme rotation**: the Background theme select is now a row of
  checkbox chips — tick several (e.g. forest + ocean + space) and each fetch
  picks one at random, so the pool converges to a mix. `THEME` becomes a
  space-separated list; none checked = any.
- **Analogue clock faces**: new `face` select in the Clock card —
  **classic** (12 ticks), **minimal** (quarter ticks), **dots** (12 dots,
  larger at quarters), **numbers** (12/3/6/9 numerals). `CLOCK_FACE` config
  key, default classic.

### Changed
- **Recent activity is collapsed by default** behind a chevron (native
  `<details>`); click to expand.

## 2026-06-04 05:54 BST — Fam1

### Changed
- **"Text" select relabelled "Text colour"** with options displayed as
  **white / black / accent** (stored values stay `light`/`dark`/`accent` for
  config + allow-list compat) — the theme-flavoured words were still easy to
  misread even after the inversion fix.

## 2026-06-04 05:52 BST — Fam1

### Fixed
- **"Text" colour select was inverted**: `OVERLAY_THEME` carried UI-theme
  semantics (dark theme → white text), so picking "dark" gave light text and
  vice versa. It now names the text colour itself — dark = black text,
  light = white text — and the shipped default flips from `dark` to `light`
  so the out-of-box look (white text) is unchanged. **Note for existing
  installs**: a saved `OVERLAY_THEME="dark"` now renders black text — re-pick
  in the web UI (or edit the config) if you want to stay white.

## 2026-06-04 05:47 BST — Fam1

### Changed
- **Two-column layout alignment polish**: controls panel now sits flush with
  the thumbnail top (heading hidden on wide screens), status cards render a
  neat 3+3 instead of auto-fit's ragged 4+2, and the odd-count Appearance
  group spans the full row instead of leaving an orphan gap.

## 2026-06-04 05:45 BST — Fam1

### Fixed
- **"Date" had no effect with the analogue clock** — it was only implemented
  for the digital style; the analogue branch silently ignored `CLOCK_DATE`.
  The analogue face now gets the same small date line underneath
  (`Thu 4 Jun`), sized to the face diameter.

## 2026-06-04 05:42 BST — Fam1

### Changed
- **Wide-screen two-column layout for the web UI.** The page was an 860px
  centre column, pushing Controls below the fold on a desktop monitor. Now up
  to 1560px wide: ≥1100px viewports get thumbnail + status cards on the left
  with the Controls form alongside on the right (downloads/recent-activity
  diagnostics flow below-left); narrow/mobile keeps the single-column stack.

## 2026-06-04 05:38 BST — Fam1

### Changed
- **Faster recovery from the 2-day forecast.** While the cached forecast still
  leads with a past day (wttr.in pre-rollover, so only Today + 1 render after
  the past-day drop), the raw cache TTL is cut from 3h to 30min — the third day
  reappears soon after the API catches up instead of waiting out the full cache.

## 2026-06-04 05:35 BST — Fam1

### Fixed
- **Forecast day labels off by one** ("Today Thu Fri" shown on a Thursday):
  wttr.in's `weather[0]` can still be *yesterday* early in the morning (its data
  generation lags), and "Today" was baked into the 3h cache at fetch time so it
  also went stale across midnight. The raw API dates are now cached instead and
  labels are resolved at render time — each day's real date is compared to the
  current date: past days are dropped, today's labelled "Today", the rest get
  their weekday name.

## 2026-06-04 05:28 BST — Fam1

### Changed
- **Smooth Apply + soft status refresh in the web UI.** "Apply changes" now
  submits via fetch() and stays on the page: the button shows a spinner +
  "Applying…" while the server works (a theme change can take a while), then
  "Applied ✓" (green) or "Failed — try again" (red) — no more jarring full-page
  POST→redirect→reload. The 30-second `<meta http-equiv=refresh>` full reload is
  gone too: a background fetch swaps just the status cards / thumbnail /
  downloads table / recent-activity log in place, never the form, so in-progress
  edits survive and the thumbnail only reloads when the image actually changed.

## 2026-06-04 05:20 BST — Fam1

### Fixed
- **Re-running install.sh didn't restart a running wallpaper-web**, so the old
  server kept handling POSTs from the freshly regenerated controls form — new
  settings it didn't know (e.g. Clock) were silently dropped from the config on
  every Apply. `systemctl --user enable --now` is a no-op when the unit is
  already active; install.sh now does `enable` + `restart` so an upgrade always
  brings the new server code live.

## 2026-06-03 10:46 BST — paul-HP-ProDesk-400-G4-SFF

### Changed
- **Controls form polish — toggle switches + active cards.** Each feature card
  (Quote / System stats / Weather / Clock) now has a header **toggle switch** for
  its enable, with the sub-options below; an enabled card gets a subtle accent
  border, and toggling off dims the card (a tiny inline script reflects the
  toggle state — controls are only *dimmed*, never `disabled`, so their values
  still submit and a saved position isn't lost when you toggle off + Apply).

### Fixed
- **Weather overlay didn't show after upgrading** if a pre-structured (legacy)
  `weather.txt` cache was <60 min old: the new `weather_line` keyed off the
  `|`-structured format but never force-refreshed the legacy one. It now also
  refreshes when the cache lacks `|`, so it self-heals on upgrade.

## 2026-06-03 10:04 BST — paul-HP-ProDesk-400-G4-SFF

### Changed
- **Modernised the web-UI controls form.** The controls had grown to ~24 mixed
  checkboxes/selects in a single flat wrap that read as cluttered. They're now
  grouped into labelled cards — **Rotation / Quote / System stats / Weather /
  Clock / Background / Appearance** — laid out in a responsive grid, with
  consistent input styling, accent-blue checkboxes, label+control pairs kept
  together on wrap (`.fld`, no orphaned labels), and a proper **Apply changes**
  button. Pure layout/CSS in `gen-status.sh`; same control names + behaviour, so
  `wallpaper-web.py` is unchanged. (Re-applied on top of the clock/forecast/
  overlay-style controls added in parallel on Fam3/e210.)

## 2026-06-03 08:58 BST — paul-e210

### Added
- **Version number + tracker, derived from the CHANGELOG.** The version *is* the
  newest CHANGELOG entry — this header's date (`v2026.06.03`), with the time +
  authoring host for precise tracking — so every entry auto-bumps it and there's no
  separate `VERSION` file to maintain.
  - `install.sh` parses the top `## YYYY-MM-DD HH:MM TZ — host` header and stamps
    `~/.local/state/wallpaper-rotator/version` (`WR_VERSION`, `WR_VERSION_ID`,
    authoring host, install time + host), and prints the version in its summary.
  - The **web UI** shows the version in the header subline (`v2026.06.03`) and the
    full id + install details in the footer — so each machine's `:8787` page tells
    you at a glance what it's running and when it was installed.
  - **`set-wallpaper.sh --version`** (`-V`) prints the installed version and exits.

## 2026-06-03 07:26 BST — Fam3

### Fixed
- **Quotes repeated through the day** (seen the same one earlier). `pick_quote` did
  `shuf -n1` each rotation, so repeats happened by chance. Now it's a **shuffle-bag**:
  draw from a shuffled queue (`quotes.bag`) so none repeats until all have shown.
  - When the bag is **exhausted**, it downloads a **fresh batch** (`fetch-quotes.sh`)
    for the next bag instead of reshuffling the same set.
  - A persistent **seen-list** (`quotes.seen`, by quote text, last ~1000) filters
    every new/re-downloaded bag, so an overlapping re-download never re-shows a
    quote already had — until the whole known set is exhausted, then the seen-list
    resets and cycling resumes. (`@@FETCHQ@@` added to set-wallpaper.sh.)
- **Wallpaper double-rendered / flickered every 3rd minute.** The web UI's
  `set_cron_interval` rewrote *every* line containing the set-wallpaper path to
  `*/N` — including the every-minute clock-refresh line — so both fired together and
  raced (two renders/sets in one second, and a race on the quote bag). Now it only
  rewrites the rotate line (the clock line references `current`), and set-wallpaper
  takes a **non-blocking lock** so two runs can never render at once (the later one
  skips that tick). Live crontab repaired (clock line back to `* * * * *`).

## 2026-06-03 07:13 BST — Fam3

### Changed
- **Forecast glyphs are now coloured** (when the weather "colour" toggle is on),
  matching the current-conditions icon — gold sun, blue rain, etc. The forecast
  cache is now stored **structured** (`label⇥condition⇥hi⇥lo` per day) so the line
  is composed per-day, letting each glyph take its condition colour; the colour
  toggle applies at render time without re-fetching. Spacing is via explicit
  transparent spacers (since `-trim` drops whitespace), and the strip is dimmed
  only lightly (0.85) so the colours read while staying secondary.

## 2026-06-03 06:55 BST — Fam3

### Changed
- **Weather forecast line restyled — was cramped/messy.** The forecast read like a
  second competing line (same weight, tight against the current line). Now it's
  clearly secondary: ~70% size, dimmed to 72% opacity, centred under the current
  line with a 14px gap. Reads as "now" + a quiet outlook instead of two dense rows.

## 2026-06-03 06:51 BST — Fam3

### Added
- **Weather forecast line** (`OVERLAY_WEATHER_FORECAST` + "forecast" checkbox). When
  on, the weather overlay gains a second, smaller line with a compact 3-day daily
  outlook — `Today ☀ 24/14 · Thu ☀ 24/16 · Fri ☀ 24/17` (day · condition glyph ·
  maxC/minC), parsed from wttr.in's `?format=j1` JSON via `weather_forecast()` and
  cached ~3h (forecasts move slowly). The current-conditions line is unchanged when
  the toggle is off. Forecast glyphs are rendered in DejaVu-Sans so they never tofu
  regardless of the chosen overlay font. (The existing weather line is still
  **current** conditions, not a forecast.)

## 2026-06-03 06:43 BST — Fam3

### Added
- **Clock overlay** (`OVERLAY_CLOCK`) — **digital** (big time + optional date,
  12/24h) or **analogue** (drawn dial: ring, 12 ticks, hour/minute hands, accent
  centre pin via `draw_clock`), with position + size (shared `OVERLAY_SIZE`) and a
  UI control row (Clock / style / position / 24h / date). Goes through the shared
  `style_block` so it gets the same panel/shadow/collision-avoidance.
  - Because the wallpaper is a static render, a **1-minute cron re-renders the
    current image while the clock is on** (no shuffle) so the baked-in clock stays
    accurate to the minute (and weather/stats refresh too); it's a no-op when the
    clock is off, so there's no extra churn otherwise.
  - To stop that 1-min refresh re-randomising the quote every minute, the quote is
    now **cached per current image** (re-picked only when the image actually
    rotates or the +attribution toggle changes).

## 2026-06-03 06:29 BST — Fam3

### Added
- **Favicon + informative window title for the web UI.** Added an inline SVG
  favicon (framed landscape — accent frame, gold sun, green hills) as a base64
  data-URI, so no server route or binary asset is needed. The `<title>` is now
  `Wallpaper Rotator · <host> — <N> imgs` (was just `wallpaper-rotator`), so the
  browser tab is identifiable per machine at a glance.

## 2026-06-03 06:26 BST — Fam3

### Added
- **Cycling theme** in the Background-theme dropdown (Wallhaven `q=cycling`) —
  fitting for the bike shop.

### Fixed
- **Background theme barely did anything.** Three causes: (1) hitting *Apply* only
  re-rendered the current image and never fetched, so theme changes had no visible
  effect; (2) only Wallhaven honours the theme, but it was 1 of 4 shuffled sources,
  so ~75% of downloads (Bing/Picsum) ignored it; (3) random rotation over a 30-img
  pool of mostly old/untargeted images diluted what little was themed. Now:
  - `fetch-wallpaper.sh` tries **Wallhaven first** when a theme is set (others as
    fallback), so new downloads actually honour it.
  - Changing the theme in the web UI **fetches a themed image immediately and
    displays it** (instant feedback), then tops up the pool with a background burst
    of themed images and trims to the newest ~12, so rotation **converges** to the
    theme. (`wallpaper-web.py` gained `@@FETCH@@`/`@@POOL@@`; a plain Apply with no
    theme change still just re-renders the current image.)

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
