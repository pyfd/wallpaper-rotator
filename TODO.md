# wallpaper-rotator — TODO / roadmap

## Done (2026-06-03)
- ✅ Web UI always-on via a systemd user service (`wallpaper-web.service`).
- ✅ Weather icons (DejaVu-safe glyph set) with a UI toggle; location title-cased.
- ✅ Coloured weather icons (condition-mapped colour) with a UI toggle.
- ✅ Quotes no longer Title-Cased (source reorder + conservative de-Title-Case).
- ✅ Overlay collision-avoidance (independent anchors no longer overlap).
- ✅ Overlay panels hug their text (`-trim`), no more dead space.
- ✅ Drawn line+area sparklines (ImageMagick `-draw`) replacing blocky unicode.
- ✅ Fixed font dropdown only ever showing "default" (pipefail + `grep -q` bug).

## Done (2026-06-02)
- ✅ Quotes from an API with local cache (`fetch-quotes.sh`, cron-refreshed).
- ✅ Local weather overlay (wttr.in).
- ✅ Backgrounds by theme (Wallhaven `q=`).
- ✅ Load/RAM sparklines in the stats overlay.

## Ideas / later
- Weather: forecast line (multi-hour); the icon set itself is now done.
- Theme: per-source theming for Bing/Unsplash; multiple themes rotating.
- Sparklines: longer history window (the drawn `-draw` graph itself is now done).
- Quote sources: allow a user-supplied quotes file; category/tag filtering.
