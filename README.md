# wallpaper-rotator

Auto-rotating **desktop wallpaper** (XFCE, GNOME, Cinnamon, MATE, or a `feh`
fallback) and **LightDM login background**, fed from a single image pool that
cron refills every 10 minutes from [picsum.photos](https://picsum.photos).

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
                       LightDM greeter points at it. (LightDM only — see below.)
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
| **LightDM** (gtk or slick greeter) | ✅ supported |
| GDM / SDDM / none | ⏭️ skipped (desktop rotation still works) |

Login backgrounds on GDM/SDDM are theme-bound and fragile, so they're
intentionally out of scope. Everything else still installs and the desktop
rotates normally.

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
identify /usr/share/backgrounds/login-random.jpg # login image (LightDM only)
tail -f ~/.local/state/wallpaper-rotator/wallpaper.log  # activity log (rotate/download/prune + errors)
```

The desktop changes within ~10 min (or immediately at install). The login
background updates on your next login.

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
├── bootstrap.sh                           # curl one-liner entrypoint
├── install.sh                             # idempotent, DE/DM/distro-aware installer
├── uninstall.sh
├── bin/
│   ├── fetch-wallpaper.sh                   # multi-source pool fetcher w/ fallback (templated)
│   ├── set-wallpaper.sh                    # DE-aware desktop wallpaper setter (templated)
│   └── random-login-bg.sh                  # login-image generator (templated)
├── cron/wallpaper.cron                     # download + prune + rotate (templated)
├── autostart/random-login-bg.desktop       # refresh login image at login
├── sudoers.d/random-login-bg               # passwordless sudo for the login generator
└── greeter/lightdm-gtk-greeter.conf.snippet
```

Templated files use `@@POOL@@`, `@@SETWP@@`, `@@FETCH@@`, `@@LOG@@`, `@@RES@@`,
`@@SOURCES@@`, `@@LOCALDIR@@`, `@@TARGET@@`, `@@RESOLUTION@@`, `@@USER@@`
placeholders that `install.sh` substitutes per-machine.

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Desktop not changing | Run `/usr/local/bin/set-wallpaper.sh` by hand. If that works but cron doesn't, cron lacks your session bus — confirm `/run/user/$(id -u)/bus` exists and `DISPLAY=:0` is correct for your box. |
| Wrong DE detected | `echo $XDG_CURRENT_DESKTOP`; the setter also sniffs running `*-session` processes when run from cron. |
| Login bg never changes | LightDM only. Is `~/.config/autostart/random-login-bg.desktop` present and `sudo /usr/local/bin/random-login-bg.sh` passwordless? |
| Pool not filling | `grep download ~/.local/state/wallpaper-rotator/wallpaper.log`; test `curl -fsL https://picsum.photos/1600/900 -o /tmp/t.jpg`. |
| Desktop config changes but screen doesn't (KDE) | The setter prefers `qdbus … evaluateScript` (applies live); `plasma-apply-wallpaperimage` only updates config and won't repaint a running Plasma 5.x session. Check `backend=` in the log — `plasma-apply(config-only)` means no qdbus was found. |
| No package manager | Install `imagemagick`, `curl`, and a cron daemon manually, then re-run. |
