#!/bin/bash
# Refresh the local quote cache from a quotes API so overlay quotes keep changing.
# Tries sources in order; first that yields enough quotes wins. Writes the cache
# in the same pipe format set-wallpaper.sh reads: text|author|source|year
# (APIs give text+author; source/year stay blank). Falls back silently — the
# setter uses its bundled list when the cache is empty. @@LOG@@ via install.sh.
#
# --seed: one-time bulk import (~30k sampled from the Quotes-500K dataset,
# fallback ~9k from three GitHub JSON sets) so the no-repeat cycle runs for
# months instead of hours. install.sh fires it in the background whenever the
# cache looks unseeded (<2000 lines). Daily API refreshes then merge on top.
set -uo pipefail

CAP=50000   # cache ceiling — must exceed the seed size or refreshes would truncate it

LOG="@@LOG@@"
[ "$LOG" = "@@LOG""@@" ] && LOG="${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper-rotator/wallpaper.log"
CACHE="$(dirname "$LOG")/quotes.cache"
mkdir -p "$(dirname "$LOG")" 2>/dev/null
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null; }

command -v jq >/dev/null 2>&1 || { log "[quotes] jq missing — skip"; exit 0; }
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT

fetch() {  # $1 = source name -> emit "text|author||" lines on stdout
  case "$1" in
    # dummyjson is DETERMINISTIC without skip (same first 30 every call) — that
    # made every fallback refresh re-serve one fixed batch, exhaust the seen
    # filter and reset the history (= visible repetition). Random-page over its
    # ~1450-quote pool instead.
    dummyjson) curl -fsL --max-time 15 "https://dummyjson.com/quotes?limit=30&skip=$((RANDOM % 1400))" 2>>"$LOG" \
                 | jq -r '.quotes[]? | "\(.quote)|\(.author)||"' 2>/dev/null ;;
    zenquotes) curl -fsL --max-time 15 "https://zenquotes.io/api/quotes" 2>>"$LOG" \
                 | jq -r '.[]? | "\(.q)|\(.a)||"' 2>/dev/null ;;
    quotable)  curl -fsL --max-time 15 "https://api.quotable.io/quotes/random?limit=30&maxLength=140" 2>>"$LOG" \
                 | jq -r '.[]? | "\(.content)|\(.author)||"' 2>/dev/null ;;
  esac
}

# Some sources (notably dummyjson) ship quotes pre-mangled in Title Case
# ("If You Are Out To Describe The Truth...", note the tell-tale "Can'T"). Detect
# a fully title-cased quote (>=80% of words capitalised, >=4 words) and convert it
# to sentence case; all-caps acronyms are preserved. Well-cased quotes pass
# through untouched. Operates on the text field (before the first '|') only.
normalize() {
  awk -F'|' 'BEGIN{OFS="|"}
  {
    t=$1; n=split(t,w," "); cap=0; alpha=0
    for(i=1;i<=n;i++){ if(w[i]~/[A-Za-z]/){alpha++; if(w[i]~/^[A-Z]/)cap++} }
    if(alpha>=4 && cap*10 >= alpha*8){
      out=""
      for(i=1;i<=n;i++){
        tok=w[i]
        if(tok !~ /^[A-Z][A-Z]+[[:punct:]]?$/) tok=tolower(tok)   # keep ALL-CAPS acronyms
        out=(i==1)?tok:out" "tok
      }
      $1=out
    }
    print
  }' \
  | sed -E 's/^([a-z])/\U\1/; s/([.!?]"? )([a-z])/\1\U\2/g; s/\bi\b/I/g; s/\bi'\''/I'\''/g'
}

# Bulk seed. Quotes-500K via its HuggingFace mirror (144MB CSV, python3 for
# proper quoted-comma parsing) -> length-filtered, 30k random sample. Fallback:
# three GitHub JSON datasets (~9k combined) when python3 or the download fails.
if [ "${1:-}" = "--seed" ]; then
  if command -v python3 >/dev/null 2>&1; then
    BIG="$(mktemp)"
    if curl -fsL --max-time 600 "https://huggingface.co/datasets/jstet/quotes-500k/resolve/main/quotes.csv" -o "$BIG" 2>>"$LOG"; then
      python3 - "$BIG" <<'PYEOF' 2>>"$LOG" | shuf -n 30000 | normalize > "$TMP" || true
import csv, sys
with open(sys.argv[1], newline='', encoding='utf-8', errors='replace') as f:
    r = csv.reader(f)
    next(r, None)  # header: quote,author,category
    for row in r:
        if len(row) < 2:
            continue
        q, a = row[0].strip(), row[1].strip().rstrip(',')
        if not q or not a or '|' in q or '|' in a or len(a) > 40:
            continue
        if not (20 <= len(q) <= 180):
            continue
        print(f"{q}|{a}||")
PYEOF
    fi
    rm -f "$BIG"
  fi
  if [ "$(wc -l < "$TMP")" -lt 5000 ]; then
    {
      curl -fsL --max-time 60 "https://raw.githubusercontent.com/dwyl/quotes/main/quotes.json" 2>>"$LOG" \
        | jq -r '.[]? | "\(.text)|\(.author)||"' 2>/dev/null
      curl -fsL --max-time 60 "https://raw.githubusercontent.com/JamesFT/Database-Quotes-JSON/master/quotes.json" 2>>"$LOG" \
        | jq -r '.[]? | "\(.quoteText)|\(.quoteAuthor)||"' 2>/dev/null
      curl -fsL --max-time 60 "https://raw.githubusercontent.com/lukePeavey/quotable/master/data/quotes.json" 2>>"$LOG" \
        | jq -r '.[]? | "\(.content)|\(.author)||"' 2>/dev/null
    } | grep -vE '^\|' | grep -E '.\|.' | awk -F'|' 'length($1)>=20 && length($1)<=180' | normalize > "$TMP" || true
  fi
  if [ "$(wc -l < "$TMP")" -ge 1000 ]; then
    cat "$TMP" "$CACHE" 2>/dev/null | awk -F'|' 'NF && !s[$1]++' | head -n "$CAP" > "$TMP.merged" \
      && mv "$TMP.merged" "$CACHE"
    log "[quotes] seeded bulk pool ($(wc -l < "$TMP") fetched -> cache $(wc -l < "$CACHE"))"
    exit 0
  fi
  log "[quotes] seed failed (all bulk sources) — keeping existing cache"
  exit 1
fi

for src in zenquotes quotable dummyjson; do
  # keep only well-formed, non-empty lines, then de-Title-Case any mangled ones
  fetch "$src" | grep -vE '^\|' | grep -E '.\|.' | normalize > "$TMP" 2>/dev/null || true
  if [ "$(wc -l < "$TMP")" -ge 5 ]; then
    # MERGE into the cache (dedupe by text, newest first, cap $CAP) instead of
    # overwriting. Overwriting shrank the "known set" to one batch, so a batch
    # that overlapped the seen history emptied the shuffle-bag and reset the
    # history — quotes repeated long before the pool was exhausted. A growing
    # pool (+ the --seed bulk import) keeps the no-repeat cycle months long.
    cat "$TMP" "$CACHE" 2>/dev/null | awk -F'|' 'NF && !s[$1]++' | head -n "$CAP" > "$TMP.merged" \
      && mv "$TMP.merged" "$CACHE"
    log "[quotes] refreshed from $src ($(wc -l < "$TMP") new batch -> cache $(wc -l < "$CACHE"))"
    exit 0
  fi
done

log "[quotes] refresh failed (all sources) — keeping existing cache"
exit 1
