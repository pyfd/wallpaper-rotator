/* ───────────────────────────────────────────────────────────────────────────
 * VENDORED COPY — do not edit below the sentinel.
 *
 * Source : song-journey  static/usage-names.js
 * Taken  : commit e543129caa1bd5e86f7071f167b150d6433c89fb (2026-10-21)
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
// Site use (#1670): names for the controls the shared beacon (usage-beacon.js) can't name itself. The beacon labels a
// click by the nearest data-usage, else tag#id / tag.class, and drops everything else: on 21 Oct that was 9 controls
// on the home page, 20 on the dashboard and 21 in the library (plain links, the route and range options, the column
// checkboxes, summaries). This fills data-usage in at click time from structure only, never from anything typed:
//   a link            by where it goes: link:/gallery, link:/library?tab=artists; off the site, out:musicbrainz.org
//   a radio/checkbox  by its group and value: mode=year, range=7d, f-cols=album (no name: the nearest id)
//   a summary         by its <details>' or nearest id: open:all-values
// A control with its own data-usage, id or class within reach is left to the beacon. Listens on window in the capture
// phase, so it runs before the beacon's document listener. tests/usage_names.test.js holds the rules.
(function () {
  'use strict';
  const REACH = 4;   // the beacon's own: data-usage up to 4 ancestors, then the nearest control tag
  const CONTROL = /^(button|select|a|input|summary)$/;

  function named(el) {   // what the beacon would call it already, or null
    let n = el, i;
    for (i = 0; n && i < REACH; i++, n = n.parentElement) if (n.getAttribute && n.getAttribute('data-usage')) return true;
    for (n = el, i = 0; n && i < REACH; i++, n = n.parentElement) {
      if (n.nodeType === 1 && CONTROL.test((n.tagName || '').toLowerCase())) {
        return !!(n.id || (typeof n.className === 'string' && n.className.trim()));
      }
    }
    return false;
  }

  const nearestId = el => { const h = el.parentElement && el.parentElement.closest('[id]'); return h ? h.id : null; };

  function nameFor(el, here) {
    const tag = (el.tagName || '').toLowerCase();
    if (tag === 'input' && (el.type === 'radio' || el.type === 'checkbox')) {
      const group = el.name || nearestId(el);
      return group ? group + '=' + String(el.value).slice(0, 30) : null;
    }
    if (tag === 'a' && el.getAttribute('href') != null) {
      let u;
      try { u = new URL(el.getAttribute('href'), here.href); } catch (e) { return null; }
      if (u.origin !== here.origin) return 'out:' + u.hostname.replace(/^www\./, '');
      const tab = u.searchParams.get('tab');   // the library's tabs are one page told apart by ?tab=
      return 'link:' + u.pathname + (tab ? '?tab=' + tab : '');
    }
    if (tag === 'summary') {
      const d = el.parentElement;
      const id = (d && d.id) || nearestId(el);
      return id ? 'open:' + id : null;
    }
    return null;
  }

  // the control a click landed in: the target itself or a nearer ancestor (a link's <span>, a summary's count)
  function controlOf(t) {
    for (let n = t, i = 0; n && i < REACH; i++, n = n.parentElement) {
      if (n.nodeType === 1 && CONTROL.test((n.tagName || '').toLowerCase())) return n;
    }
    return null;
  }

  function onClick(e) {
    const c = controlOf(e.target);
    if (!c || named(c)) return;
    const name = nameFor(c, location);
    if (name) c.setAttribute('data-usage', name.slice(0, 60));
  }

  if (typeof window !== 'undefined' && window.addEventListener) {
    window.addEventListener('click', onClick, true);
    window.__usageNames = {nameFor, named, controlOf};   // for an audit of a live page (what would be dropped)
  }
  if (typeof module !== 'undefined') module.exports = {nameFor, named, controlOf, onClick};
})();
