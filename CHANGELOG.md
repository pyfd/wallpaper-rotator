# Changelog

All notable changes to wallpaper-rotator are recorded here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## 2026-06-02

### Added
- **KDE Plasma desktop support.** `set-wallpaper.sh` now sets the desktop on KDE
  Plasma via `plasma-apply-wallpaperimage`, with a `qdbus`
  `org.kde.PlasmaShell.evaluateScript` fallback for older Plasma that lacks it.
  No `feh` needed. Plasma is detected from `XDG_CURRENT_DESKTOP`/`plasmashell`,
  and the cron path reuses the existing session-bus/`DISPLAY` re-establishment.
  `install.sh` adds a soft dependency check (warns if neither
  `plasma-apply-wallpaperimage` nor `qdbus` is present; no package is force-installed,
  as the setter ships with `plasma-workspace`). Support matrix updated.

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
