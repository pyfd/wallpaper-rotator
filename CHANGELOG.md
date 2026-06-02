# Changelog

All notable changes to wallpaper-rotator are recorded here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## 2026-06-02

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
