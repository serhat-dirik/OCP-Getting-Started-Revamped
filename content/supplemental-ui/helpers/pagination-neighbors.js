'use strict'

// Antora's own page.previous/page.next (@antora/page-composer lib/build-ui-model.js,
// attachNavProperties + findNavItem) are computed by flattening the component-version nav
// tree depth-first and taking the immediate neighbor on either side of the current page. That
// algorithm has no notion of "list it in the sidebar but skip it in Next/Previous" — so once a
// module's troubleshooting.adoc is added to the nav (nav-workshop.adoc: after N.3 Wrap-up;
// nav-demo.adoc: after N.3 Presenter notes — see those files' own comments for why it's last),
// Antora hands it out as page.next for the page right before it, and as page.previous for the
// page right after it (the next module's concept page). Confirmed in the built HTML before this
// helper existed: a module's Wrap-up "next" landed on that module's own troubleshooting.html
// instead of the next module's concept.html.
//
// This helper re-derives previous/next from page.navigation — the full, unfiltered nav tree,
// always present on every page (see attachNavProperties) — walking past ANY item whose URL is a
// troubleshooting page in the requested direction. It is direction-symmetric on purpose: fixing
// only "next" would leave the reverse hop (the NEXT module's concept page clicking "previous")
// landing on THIS module's troubleshooting page instead of its real predecessor — same defect,
// opposite direction.
//
// Falls through to Antora's own page.previous/page.next, completely unmodified, whenever the
// current page can't be located in the flattened tree (e.g. a page that was never in nav.adoc,
// or the synthesized 404 page, which carries neither page.navigation nor page.url) — so this
// helper only ever changes behavior at the troubleshooting insertion points; every other page's
// pagination is byte-for-byte identical to stock Antora.
//
// Registered as a Handlebars helper by filename (stem) because it lives under helpers/ in
// ui.supplemental_files — see partials/pagination.hbs (also overridden here) for the call site.

// Antora's default urls.htmlExtensionStyle ("default") keeps the .html suffix on published
// pages, and none of the three site-*.yml playbooks set `urls:`, so every page URL in this site
// ends in .html (confirmed in the built HTML, e.g. .../platform-orientation/troubleshooting.html).
// "troubleshooting.html" as a final path segment can only be produced by a page whose source
// stem is troubleshooting — the module template's five-file contract — so the suffix match can't
// collide with any other page in this repo.
const TROUBLESHOOTING_URL_RE = /\/troubleshooting\.html$/

function isTroubleshooting (navItem) {
  return !!navItem && typeof navItem.url === 'string' && TROUBLESHOOTING_URL_RE.test(navItem.url)
}

// Mirrors the depth-first, parent-before-children walk findNavItem() uses, restricted to
// "internal" (linked) items — the same filter Antora applies when matching previous/next
// candidates. A plain nav header line (e.g. ".A — Foundations", or a "* N · Module Title" bullet
// with no xref) is not urlType "internal" and is skipped for matching, exactly as Antora skips
// it, though its nested .items are still walked.
function flattenInternal (items, acc) {
  ;(items || []).forEach((item) => {
    if (item.urlType === 'internal') acc.push(item)
    if (item.items && item.items.length) flattenInternal(item.items, acc)
  })
  return acc
}

module.exports = function paginationNeighbors (page) {
  // THE INSTRUCTOR FLAVOR IS DELIBERATELY EXEMPT. nav-instructor.adoc has listed
  // Troubleshooting for every module since long before this helper existed, and it lists it
  // INSTEAD of Wrap-up — that flavor has no Wrap-up entry at all. So for an instructor,
  // Troubleshooting is a normal stop on the way through the module, not a leaf hung off the
  // side of it, and skipping it would silently remove a page from a reading order somebody
  // designed on purpose. Only workshop/demo, where this helper's own nav entries were newly
  // added, get the skip.
  //
  // Keyed on page-flavor from the playbook (site-*.yml) rather than on site.title: a title is
  // prose someone will reword one day, and the failure would be silent in exactly the way this
  // whole helper exists to prevent. Unprefixed playbook attributes (`instructor: true`) cannot
  // be used here — Antora exposes only `page-`-prefixed ones to the UI model.
  //
  // DEFAULT IS TO SKIP. A build with no page-flavor (showroom/site.yml and site-demo.yml, the
  // in-cluster cockpits) is attendee-facing, which is the behaviour it should inherit.
  const flavor = page && page.attributes && page.attributes.flavor
  if (flavor === 'instructor') return { previous: page.previous, next: page.next }
  const flat = flattenInternal(page && page.navigation, [])
  const currentUrl = page && page.url
  const idx = flat.findIndex((item) => item.url === currentUrl)
  if (idx === -1) return { previous: page && page.previous, next: page && page.next }
  let previous
  for (let i = idx - 1; i >= 0; i--) {
    if (!isTroubleshooting(flat[i])) {
      previous = flat[i]
      break
    }
  }
  let next
  for (let i = idx + 1; i < flat.length; i++) {
    if (!isTroubleshooting(flat[i])) {
      next = flat[i]
      break
    }
  }
  return { previous, next }
}
