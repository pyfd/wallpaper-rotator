#!/usr/bin/env bash
# vendor-usage-beacon.sh: refresh the web UI's two vendored usage scripts (#1815; the bike finder's script, ported).
# One shared beacon across every page we serve, not another rewrite (cldev USAGE_TRACKING.md §3).
#
#     scripts/vendor-usage-beacon.sh [path-to-workshop-service] [path-to-song-journey]
#
#   web/vendor/usage-beacon.js  <- workshop-service infra/_shared/usage-beacon.js (the house beacon)
#   web/vendor/usage-names.js   <- song-journey static/usage-names.js (names the controls it can't)
#
# Each file keeps its header down to the sentinel and re-stamps the commit line, so `git diff` afterwards shows
# exactly what moved. Commit the upstream change first: the stamp is the last commit that touched it.
# tests/test_usage.py diffs everything below the sentinel against upstream byte-for-byte.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ws="${1:-${WORKSHOP_SERVICE_ROOT:-$HOME/gits/workshop-service}}"
sj="${2:-${SONG_JOURNEY_ROOT:-$HOME/gits/song-journey}}"

vendor() {   # <upstream repo> <path in it> <vendored file> <source label>
    local repo="$1" rel="$2" out="$3" label="$4"
    if [ ! -f "$repo/$rel" ]; then
        echo "vendor-usage-beacon: upstream not found at $repo/$rel" >&2
        exit 2
    fi
    if ! git -C "$repo" diff --quiet -- "$rel"; then
        echo "vendor-usage-beacon: $repo/$rel has uncommitted changes; commit them first so the stamp is true" >&2
        exit 2
    fi
    local commit date
    commit="$(git -C "$repo" log -1 --format='%H' -- "$rel")"
    date="$(git -C "$repo" log -1 --format='%ad' --date=short -- "$rel")"
    if [ -f "$out" ]; then
        awk '/^\/\* ─── UPSTREAM COPY BEGINS ─── \*\/$/ { print; exit } { print }' "$out" \
            | sed -E "s|^( \* Taken  : commit ).*$|\1${commit} (${date})|" > "$out.new"
    else   # first vendoring: write the header
        cat > "$out.new" <<HDR
/* ───────────────────────────────────────────────────────────────────────────
 * VENDORED COPY — do not edit below the sentinel.
 *
 * Source : ${label}
 * Taken  : commit ${commit} (${date})
 *
 * WHY A COPY (#1815). The web UI serves its own page from this machine's
 * 127.0.0.1:8787, with no shared server behind it, and posts its rows to its
 * own /seen (named on the tag with data-endpoint). The house pattern is one
 * beacon everywhere, not a rewrite per app. wallpaper-web.py adds the tags to
 * every HTML response (one place), so a new page can't ship without them.
 *
 * THE COST IS DRIFT, MADE VISIBLE: tests/test_usage.py diffs everything below
 * the sentinel against the upstream file byte-for-byte, and fails loudly
 * rather than passing quietly when the upstream repo isn't cloned beside this
 * one (WR_NO_UPSTREAM=1 to run the other tests without it).
 *
 * To re-vendor: scripts/vendor-usage-beacon.sh
 * ─────────────────────────────────────────────────────────────────────────── */
/* ─── UPSTREAM COPY BEGINS ─── */
HDR
    fi
    cat "$repo/$rel" >> "$out.new"
    mv "$out.new" "$out"
    echo "vendored $repo/$rel -> $out (commit ${commit}, ${date})"
}

vendor "$ws" infra/_shared/usage-beacon.js "$root/web/vendor/usage-beacon.js" "workshop-service  infra/_shared/usage-beacon.js"
vendor "$sj" static/usage-names.js "$root/web/vendor/usage-names.js" "song-journey  static/usage-names.js"
git -C "$root" --no-pager diff --stat -- web/vendor/ || true
