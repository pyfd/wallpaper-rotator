#!/bin/bash
# Refresh the local quote cache from a quotes API so overlay quotes keep changing.
# Tries sources in order; first that yields enough quotes wins. Writes the cache
# in the same pipe format set-wallpaper.sh reads: text|author|source|year
# (APIs give text+author; source/year stay blank). Falls back silently — the
# setter uses its bundled list when the cache is empty. @@LOG@@ via install.sh.
set -uo pipefail

LOG="@@LOG@@"
[ "$LOG" = "@@LOG""@@" ] && LOG="${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper-rotator/wallpaper.log"
CACHE="$(dirname "$LOG")/quotes.cache"
mkdir -p "$(dirname "$LOG")" 2>/dev/null
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null; }

command -v jq >/dev/null 2>&1 || { log "[quotes] jq missing — skip"; exit 0; }
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT

fetch() {  # $1 = source name -> emit "text|author||" lines on stdout
  case "$1" in
    dummyjson) curl -fsL --max-time 15 "https://dummyjson.com/quotes?limit=30" 2>>"$LOG" \
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

for src in zenquotes quotable dummyjson; do
  # keep only well-formed, non-empty lines, then de-Title-Case any mangled ones
  fetch "$src" | grep -vE '^\|' | grep -E '.\|.' | normalize > "$TMP" 2>/dev/null || true
  if [ "$(wc -l < "$TMP")" -ge 5 ]; then
    mv "$TMP" "$CACHE"
    log "[quotes] refreshed from $src ($(wc -l < "$CACHE") quotes)"
    exit 0
  fi
done

log "[quotes] refresh failed (all sources) — keeping existing cache"
exit 1
