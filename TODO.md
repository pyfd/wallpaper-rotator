<!-- GENERATED FILE — do not edit by hand. -->
<!-- Source of truth: the todo API + SQLite todo.db on scb-ubuntu. Hand edits are overwritten on the next export. -->
<!-- To change items: tell Claude ("todo: …", "close the X", "bump Y to high") or use http://scb-ubuntu:3000/reports/todo/ . -->
# Wallpaper Rotator — TODO (generated 2026-06-13)

> 1 open · 0 in-progress · 1 done

## Open

### open

- [ ] **Improve SCB pulse content (added 2026-06-12): the pulse overlay**  ·  `improve-scb-pulse-content-added-2026-06-12`
  (`pulse.txt`, workshop-service-fed) now ALSO drives the Claude Code
    statusline on all desktops via `statusline-plus` (dotfiles, see
    `~/cldev/STATUSLINE.md`) — improvements here flow to both surfaces for
    free. Paul wants a pass over what it reports: current fields are
    in-workshop / ready-to-collect / booked-in-today / emails-waiting /
    WhatsApp-in-today / payments-today / takings-today; statusline currently
    shows the first two + emails. Think about which numbers actually matter
    at a glance, freshness cadence, and any new fields worth surfacing
    (e.g. overdue jobs, today's bookings vs capacity).

## Done (history)

- [x] **Option to link the image to the quote**  ·  `option-to-link-the-image-to-the-quote`  ·  closed 2026-06-04
  AI-dreamed pairing shipped as sketched (random bag draw → quote-driven
    prompt → `<img>.quote` sidecar → renderer prefers sidecar, marks seen,
    de-bags; orphan sidecar sweep; "Match image to quote" toggle in the Quote
    group). Interleaves with the normal pool; gen failures fall back to
    unlinked sources. Verified on Fam3 (gratitude quote → golden-meadow gen).
    Remaining idea: (b) tag-matched wallhaven sourcing for non-AI mode —
    moved to Ideas/later.

