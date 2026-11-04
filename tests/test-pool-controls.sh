#!/bin/bash
# Tests for the pool size controls (#1786): prune-pool.sh and shrink-image.sh,
# run against a throwaway pool. Touches nothing outside its own temp dir.
#
#   tests/test-pool-controls.sh
#   PRUNE=/path/to/mutant.sh tests/test-pool-controls.sh   # point at a mutant to check the tests bite
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PRUNE="${PRUNE:-$HERE/bin/prune-pool.sh}"
SHRINK="${SHRINK:-$HERE/bin/shrink-image.sh}"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export WR_POOL="$T/pool" WR_LOG="$T/state/wallpaper.log" WR_CONFIG="$T/state/config" WR_RES=1920x1080
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
count() { find "$WR_POOL" -maxdepth 1 -type f -name '*.jpg' | wc -l; }

# n images, KB each, ages 1..n hours (img01 = newest)
mkpool() {
  rm -rf "$T/pool" "$T/state"; mkdir -p "$T/pool/favourites" "$T/state"; : > "$WR_LOG"
  local n=$1 kb=$2 i
  for i in $(seq -w 1 "$n"); do
    head -c $((kb * 1024)) /dev/zero > "$T/pool/img$i.jpg"
    touch -d "-$((10#$i)) hours" "$T/pool/img$i.jpg"
  done
  head -c 1024 /dev/zero > "$T/pool/favourites/fav.jpg"; touch -d '-1000 hours' "$T/pool/favourites/fav.jpg"
}
cfg() { printf "%s\n" "$@" > "$WR_CONFIG"; }

echo "prune-pool.sh"
mkpool 20 10; cfg "POOL_MAX='15'"
"$PRUNE"
check "count cap: 20 -> 15" '[ "$(count)" = 15 ]'
check "count cap: the 5 oldest went" '[ ! -e "$T/pool/img20.jpg" ] && [ ! -e "$T/pool/img16.jpg" ] && [ -e "$T/pool/img15.jpg" ]'
check "favourites untouched" '[ -e "$T/pool/favourites/fav.jpg" ]'
check "log line: removed=5" 'grep -q "\[prune\] removed=5 " "$WR_LOG"'

mkpool 20 10; cfg "POOL_MAX='3'"
"$PRUNE"
check "floor: a cap of 3 still keeps the newest 12" '[ "$(count)" = 12 ]'

mkpool 20 10; cfg "POOL_MAX='15'"; echo "$T/pool/img20.jpg" > "$T/state/current"
"$PRUNE"
check "the image on screen is never pruned" '[ -e "$T/pool/img20.jpg" ] && [ "$(count)" = 16 ]'

mkpool 20 100; cfg "POOL_MAX='5000'" "POOL_MAX_MB='1'"   # 1 MB = 10 x 100 KB, but floor 12
"$PRUNE"
check "size cap below the floor: newest 12 kept" '[ "$(count)" = 12 ]'

mkpool 30 100; cfg "POOL_MAX='5000'" "POOL_MAX_MB='2'"   # 2 MB = 20 x 100 KB
"$PRUNE"
check "size cap: 30 x 100 KB under 2 MB -> 20 kept" '[ "$(count)" = 20 ]'
check "size cap: oldest went, newest stayed" '[ ! -e "$T/pool/img21.jpg" ] && [ -e "$T/pool/img20.jpg" ] && [ -e "$T/pool/img01.jpg" ]'

# oldest-first is strict: a small OLD image is not kept after a bigger newer one is dropped
# (20 x 100 KB fit under 2 MB, img21 tips it over, img22 is 1 KB and WOULD still fit)
mkpool 22 100; head -c 1024 /dev/zero > "$T/pool/img22.jpg"; touch -d '-22 hours' "$T/pool/img22.jpg"
cfg "POOL_MAX='5000'" "POOL_MAX_MB='2'"
"$PRUNE"
check "size cap is strictly oldest-first" '[ -e "$T/pool/img20.jpg" ] && [ ! -e "$T/pool/img21.jpg" ] && [ ! -e "$T/pool/img22.jpg" ]'

mkpool 20 10; cfg "POOL_MAX='15'"; echo "a quote" > "$T/pool/img20.jpg.quote"
"$PRUNE"
check "a pruned image's .quote sidecar goes with it" '[ ! -e "$T/pool/img20.jpg.quote" ]'

mkpool 20 10; cfg "POOL_MAX='15'"
out="$("$PRUNE" --dry-run)"
check "dry run removes nothing" '[ "$(count)" = 20 ] && [ ! -s "$WR_LOG" ]'
check "dry run reports 5" 'printf "%s" "$out" | grep -q "would remove 5 image"'

mkpool 20 10; cfg "POOL_MAX='15'"
"$PRUNE" --dryrun 2>/dev/null; rc=$?
check "unknown argument refused (exit 2), nothing removed" '[ "$rc" = 2 ] && [ "$(count)" = 20 ]'

mkpool 20 10; cfg "POOL_MAX='abc'" "POOL_MAX_MB='x'"
"$PRUNE"
check "junk config values fall back to defaults (nothing removed)" '[ "$(count)" = 20 ]'

mkpool 40 10; cfg "POOL_MAX='15'"
"$PRUNE" & "$PRUNE" & "$PRUNE" & wait
check "3 prunes at once: 25 removed, and logged once as 25 (no double count)" '[ "$(count)" = 15 ] && [ "$(grep -oP "removed=\K[0-9]+" "$WR_LOG" | paste -sd+ | bc)" = 25 ]'

echo "shrink-image.sh"
if ! command -v convert >/dev/null 2>&1; then
  echo "  skip (no ImageMagick)"
else
  mkpool 0 0
  convert -size 4000x2500 gradient:blue-red -quality 98 "$T/pool/big.jpg"
  convert -size 3000x1000 gradient:green-yellow -quality 98 "$T/pool/wide.jpg"
  cp "$T/pool/big.jpg" "$T/pool/favourites/bigfav.jpg"
  touch -d '-50 hours' "$T/pool/big.jpg"
  m0=$(stat -c %Y "$T/pool/big.jpg"); w0=$(md5sum < "$T/pool/wide.jpg")

  cfg "POOL_SHRINK='off'"
  "$SHRINK" "$T/pool/big.jpg"
  check "level off: untouched" '[ "$(identify -format %wx%h "$T/pool/big.jpg")" = 4000x2500 ]'

  "$SHRINK" --dry-run --level 1440hq --pool >/dev/null
  check "dry run: untouched" '[ "$(identify -format %wx%h "$T/pool/big.jpg")" = 4000x2500 ]'

  "$SHRINK" --level nope "$T/pool/big.jpg" 2>/dev/null; rc=$?
  check "unknown level refused (exit 2)" '[ "$rc" = 2 ]'

  cfg "POOL_SHRINK='1440hq'"
  "$SHRINK" --pool
  check "1440hq: 4000x2500 -> 2560x1600 (still covers 2560x1440)" '[ "$(identify -format %wx%h "$T/pool/big.jpg")" = 2560x1600 ]'
  check "shrunk file keeps its date" '[ "$(stat -c %Y "$T/pool/big.jpg")" = "$m0" ]'
  check "3000x1000 (under the box on one side) not re-encoded" '[ "$(md5sum < "$T/pool/wide.jpg")" = "$w0" ]'
  check "--pool leaves favourites alone" '[ "$(identify -format %wx%h "$T/pool/favourites/bigfav.jpg")" = 4000x2500 ]'
  check "log line written" 'grep -q "\[shrink\] level=1440hq .*shrunk=1 of 2" "$WR_LOG"'

  b1=$(md5sum < "$T/pool/big.jpg"); "$SHRINK" --pool
  check "second pass: already at the box, not re-encoded" '[ "$(md5sum < "$T/pool/big.jpg")" = "$b1" ]'

  "$SHRINK" --level screen "$T/pool/big.jpg"
  check "screen (1920x1080): 2560x1600 -> 1920x1200" '[ "$(identify -format %wx%h "$T/pool/big.jpg")" = 1920x1200 ]'

  check "no temp files left behind" '[ -z "$(find "$T/pool" -name ".shrink.*")" ]'
fi

echo; echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
