#!/bin/bash
#
# wallpaper-rotator uninstaller — reverses install.sh.
# Run as your normal user (NOT root). Leaves the downloaded image pool intact
# unless you pass --purge.
# -------------------------------------------------------------------------
set -uo pipefail

if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: run as your normal user, not root." >&2
  exit 1
fi

POOL="$HOME/Pictures/online-wallpapers"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

echo "==> removing cron jobs"
crontab -l 2>/dev/null \
  | sed '/# >>> wallpaper-rotator >>>/,/# <<< wallpaper-rotator <<</d' \
  | crontab - || true

echo "==> removing autostart entries"
rm -f "$HOME/.config/autostart/random-login-bg.desktop"
rm -f "$HOME/.config/autostart/gdm-login-bg.desktop"

echo "==> stopping the status server if running"
pkill -f /usr/local/bin/wallpaper-web.py 2>/dev/null || true

echo "==> removing scripts + sudoers + login image (sudo)"
sudo rm -f /usr/local/bin/random-login-bg.sh
sudo rm -f /usr/local/bin/build-gdm-greeter.sh
sudo rm -f /etc/sudoers.d/gdm-login-bg
sudo rm -f /usr/local/bin/set-wallpaper.sh
sudo rm -f /usr/local/bin/fetch-wallpaper.sh
sudo rm -f /usr/local/bin/fetch-quotes.sh
sudo rm -f /usr/local/bin/gen-status.sh
sudo rm -f /usr/local/bin/wallpaper-web
sudo rm -f /usr/local/bin/wallpaper-web.py
sudo rm -f /etc/sudoers.d/random-login-bg
sudo rm -f /usr/share/backgrounds/login-random.jpg

echo "==> reverting GDM greeter gresource (if installed)"
WR_GDM="/usr/share/gnome-shell/gnome-shell-theme-wr.gresource"
if [ -f "$WR_GDM" ]; then
  sudo update-alternatives --remove gdm-theme.gresource "$WR_GDM" 2>/dev/null || true
  sudo rm -f "$WR_GDM"
  echo "    removed custom GDM theme; alternatives reverts to the stock/Zorin theme"
fi

echo "==> disabling XFCE folder-cycle on all known monitor nodes"
for p in $(xfconf-query -c xfce4-desktop -p /backdrop -l 2>/dev/null | grep 'backdrop-cycle-enable'); do
  xfconf-query -c xfce4-desktop -p "$p" -s false 2>/dev/null || true
done

echo "    NOTE: the greeter's background= line in /etc/lightdm/lightdm-gtk-greeter.conf"
echo "    is left as-is (points at a now-removed image). Edit it manually if desired."

STATE="${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper-rotator"
if [ "$PURGE" -eq 1 ]; then
  echo "==> --purge: deleting image pool $POOL"
  rm -rf "$POOL"
  echo "==> --purge: deleting state (log, config, web, rendered) $STATE"
  rm -rf "$STATE"
else
  echo "==> image pool kept at $POOL (pass --purge to delete)"
  echo "==> state kept at $STATE (log/config/web; pass --purge to delete)"
fi

echo "Done."
