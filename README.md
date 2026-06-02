# wallpaper-rotator

Auto-rotating **desktop wallpaper** and **LightDM login background** for XFCE
machines, fed from a single image pool that cron refills every 10 minutes from
[picsum.photos](https://picsum.photos). Extracted from the working setup on
`paul-e210` so it can be installed on any Debian/MX/XFCE laptop.

---

## How it works

Everything hangs off **one shared image pool**: `~/Pictures/online-wallpapers/`.

```
                    ┌─ cron  every 10 min : download picsum  → pool
   IMAGE POOL  ◄────┤
   ~/Pictures/      └─ cron  hourly       : prune pool to 30 newest
   online-wallpapers
        │
        ├──► DESKTOP : xfdesktop native folder-cycle (xfconf backdrop-cycle-*)
        │             cycles randomly through the pool — no extra app needed.
        │
        └──► LOGIN   : random-login-bg.sh picks one image, crops/resizes it to
                       the screen resolution, writes /usr/share/backgrounds/
                       login-random.jpg. Runs at each login via autostart +
                       passwordless sudo. The greeter config points at that file,
                       so the *next* login shows a fresh image.
```

> **Note:** this does **not** use [Variety](https://peterlevi.com/variety/).
> The desktop rotation is XFCE's own built-in wallpaper cycler. (On the original
> machine Variety was installed but dormant/redundant — it is not part of this.)

### Components installed

| Piece | Location | Purpose |
|-------|----------|---------|
| `random-login-bg.sh` | `/usr/local/bin/` | Resize a random pool image → login target |
| sudoers rule | `/etc/sudoers.d/random-login-bg` | Let your user run that script passwordless |
| autostart entry | `~/.config/autostart/random-login-bg.desktop` | Refresh login image at login |
| greeter line | `/etc/lightdm/lightdm-gtk-greeter.conf` | `background=` → the login image |
| cron jobs | your user crontab | download (10 min) + prune (hourly) |
| xfconf props | `xfce4-desktop` channel | enable desktop folder-cycle on your monitor |

---

## Requirements

- XFCE desktop with `xfdesktop` (for the desktop-cycle half)
- LightDM + `lightdm-gtk-greeter` (for the login half)
- Packages (the installer apt-installs these): `imagemagick`, `curl`, `cron`,
  `lightdm`, `lightdm-gtk-greeter`, `xfconf`
- An internet connection (images come from picsum.photos)

---

## Install

On any target machine that already has this dotfiles repo cloned (`~/cldev`):

```bash
cd ~/cldev/wallpaper-rotator
./install.sh
```

Run it **as your normal user, not root** — it calls `sudo` itself for the
system bits and will prompt for your password once.

The installer is **idempotent** — safe to re-run after a `git pull`.

### What the installer does, step by step

1. Detects your screen **resolution** via `xrandr` (falls back to `1366x768`).
2. Detects your **monitor node** for xfconf (e.g. `monitoreDP-1`), deriving it
   from `xrandr` if xfconf doesn't know it yet.
3. `apt install` the dependencies.
4. Creates the pool and **seeds one image** so nothing is blank on first run.
5. Installs `random-login-bg.sh` (with your resolution/paths baked in) and runs
   it once to generate the first login image.
6. Installs the sudoers rule, **validated with `visudo -c`** before it's placed.
7. Installs the autostart `.desktop` entry.
8. Merges `background=<login image>` into the greeter config (keeps your other
   greeter settings untouched).
9. Installs the two cron jobs inside a managed marker block (replaces any prior
   copy — no duplicates).
10. Enables the XFCE folder-cycle (`backdrop-cycle-enable`,
    `backdrop-cycle-random-order`, `image-style=4`) on your monitor node.

---

## Verify

```bash
# pool is filling
ls -t ~/Pictures/online-wallpapers/ | head

# login image exists and matches your resolution
identify /usr/share/backgrounds/login-random.jpg

# cron jobs are present
crontab -l | grep -A4 wallpaper-rotator

# desktop cycle is on (substitute your monitor node)
xfconf-query -c xfce4-desktop -p /backdrop -lv | grep cycle

# download errors, if any
cat /tmp/wall-errors.log 2>/dev/null
```

The **desktop** starts cycling on its own (xfdesktop). The **login** background
updates on your next login (the autostart entry runs as you log in, preparing
the image for the login *after* — i.e. it's always one login fresh).

---

## Customise

- **Resolution** — re-run `install.sh` after changing monitors; it re-detects.
  Or edit `RESOLUTION=` at the top of `/usr/local/bin/random-login-bg.sh`.
- **Image source** — change the `picsum.photos` URL in `cron/wallpaper.cron`
  then re-run `install.sh`. Any URL that returns a JPEG works
  (e.g. `https://picsum.photos/1920/1080`).
- **Pool size** — change `tail -n +31` (keep-30) in `cron/wallpaper.cron`.
- **Download frequency** — change the `*/10` in `cron/wallpaper.cron`.
- **Desktop cycle timing** — XFCE Settings → Desktop → Background, or set
  `backdrop-cycle-period` / `backdrop-cycle-timer` via `xfconf-query`.

After editing any template in this folder, just re-run `./install.sh`.

---

## Uninstall

```bash
cd ~/cldev/wallpaper-rotator
./uninstall.sh            # removes cron, autostart, script, sudoers, login image; keeps the pool
./uninstall.sh --purge    # also deletes ~/Pictures/online-wallpapers/
```

The greeter's `background=` line is left pointing at the (now-removed) image;
edit `/etc/lightdm/lightdm-gtk-greeter.conf` by hand if you want a different one.

---

## Repo layout

```
wallpaper-rotator/
├── README.md                              # this file
├── install.sh                             # idempotent installer
├── uninstall.sh                           # reverser (--purge to wipe the pool)
├── bin/random-login-bg.sh                 # login-image generator (templated)
├── cron/wallpaper.cron                    # download + prune jobs (templated)
├── autostart/random-login-bg.desktop      # runs the login generator at login
├── sudoers.d/random-login-bg              # passwordless sudo for the generator
└── greeter/lightdm-gtk-greeter.conf.snippet  # reference for the background= line
```

Templated files use `@@POOL@@`, `@@TARGET@@`, `@@RESOLUTION@@`, `@@USER@@`
placeholders that `install.sh` substitutes per-machine — the repo copies stay
machine-agnostic.

---

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Desktop not cycling | `xfconf-query -c xfce4-desktop -p /backdrop -lv` — is the monitor node right? Re-run `install.sh` inside an XFCE session. |
| Login bg never changes | Is `~/.config/autostart/random-login-bg.desktop` present? Does `sudo /usr/local/bin/random-login-bg.sh` work without a password? |
| Login bg blank/black | Pool empty (no internet at install) — wait for cron, or run the script manually once images arrive. |
| Pool not filling | `cat /tmp/wall-errors.log`; test `curl -fsL https://picsum.photos/1600/900 -o /tmp/t.jpg`. |
| Wrong image size at login | Re-run `install.sh` to re-detect resolution, or edit `RESOLUTION=` in the installed script. |
