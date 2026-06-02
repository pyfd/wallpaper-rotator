# wallpaper-rotator — TODO / roadmap

Requested features not yet built (2026-06-02). Assessment conclusions inline.

## Quotes from an API (with local cache) so they keep changing
- **Feasible, recommended.** Fetch from a free quotes API (e.g. `https://zenquotes.io/api/quotes`
  or `https://api.quotable.io/quotes/random`) into a local cache file
  (`~/.local/state/wallpaper-rotator/quotes.json`), refreshed by cron (e.g. daily);
  `set-wallpaper.sh` picks a random cached quote, falling back to the bundled list
  when the cache is empty/offline. APIs return author (+ sometimes source/tags),
  which feeds the existing `+attribution` toggle. `jq` already a dep.

## Local weather overlay
- **Feasible.** A 3rd overlay (like stats). Source: `wttr.in` (`curl wttr.in/<loc>?format=...`,
  no key) or Open-Meteo (no key, needs lat/lon). Config: `OVERLAY_WEATHER`, `WEATHER_POS`,
  `WEATHER_LOCATION`. Render via the same ImageMagick path; refresh each tick (cache to
  avoid hammering the API — wttr.in asks for ~once/hour). Web UI gets a toggle + location field.

## Choose backgrounds by theme
- **Feasible (Wallhaven/Unsplash; not Bing/Picsum).** Add a `THEME`/query config; pass it as
  Wallhaven `q=<theme>` (e.g. nature, minimal, space, cars) + keep category/purity/ratio
  filters. Bing (fixed daily) and Picsum (random) ignore theme. Web UI: a theme text/select.
  When a theme is set, prefer themed sources and let the rest stay as fallback.

## Sparklines for load / RAM in the stats overlay
- **Feasible (text/unicode sparklines).** Keep a tiny rolling history
  (`~/.local/state/wallpaper-rotator/metrics.csv`, last ~30 samples appended each tick) and
  render unicode block sparklines (▁▂▃▄▅▆▇█) for load + mem next to the numbers. Pure
  bash/awk, no extra deps. (A true plotted graph would need ImageMagick `-draw` — heavier;
  unicode sparkline is the pragmatic first cut.)
