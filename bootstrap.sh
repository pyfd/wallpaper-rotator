#!/bin/bash
#
# wallpaper-rotator bootstrap — install on any Linux box with one command,
# no git/dotfiles/USB needed:
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/pyfd/wallpaper-rotator/main/bootstrap.sh)
#
# Downloads the repo tarball to a temp dir and runs install.sh (which needs the
# sibling bin/ cron/ etc., so a bare `curl install.sh | bash` won't do).
# -------------------------------------------------------------------------
set -euo pipefail

REPO="pyfd/wallpaper-rotator"
REF="${1:-main}"
TARBALL="https://github.com/${REPO}/archive/refs/heads/${REF}.tar.gz"

command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required." >&2; exit 1; }
command -v tar  >/dev/null 2>&1 || { echo "ERROR: tar is required." >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> downloading $REPO ($REF)"
curl -fsSL "$TARBALL" | tar xz -C "$TMP" --strip-components=1

echo "==> running installer"
cd "$TMP"
chmod +x install.sh
./install.sh
