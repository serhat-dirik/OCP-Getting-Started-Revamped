#!/usr/bin/env python3
"""no-cdn-assets-guard.py — a page asset fetched from the public internet works perfectly in CI and
fails in the room.

ORIGIN (2026-08-05, commit e669f7c). All five Antora playbooks pointed `mermaid_library_url` at
`https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.esm.min.mjs`. On an air-gapped or
egress-restricted cluster that ES-module import fails and EVERY diagram on EVERY page renders as
raw mermaid text — and the Showroom cockpit is served from in-cluster, where egress is not
guaranteed. The library was vendored into content/supplemental-ui/js/vendor/mermaid/ and the
playbooks now point at it through `{{{uiRootPath}}}`.

WHY A GATE AND NOT A CONVENTION. Nothing in CI can see the regression. A build that points at a CDN
succeeds — Antora never fetches the URL, it only substitutes it into an emitted
`<script type="module">import mermaid from '…'</script>`. Every link checker passes, every page
renders, `www/` looks right. The first failing observation happens in front of a room.

WHAT IT CHECKS (over TRACKED files only — an untracked scratch file cannot reach a cluster):

  [1] CDN LIBRARY URL. `mermaid_library_url` in any site playbook whose value is an absolute or
      protocol-relative URL. It must be a local `{{{uiRootPath}}}` path. Comments are stripped
      first: site-workshop.yml deliberately RECORDS the old jsdelivr URL in a comment so the next
      reader knows what was removed and why, and that must stay legal.

  [2] REMOTE ASSET IN THE UI. Anything under content/supplemental-ui/** that makes the browser
      fetch from another host: `<script src>`, `<link href>`, `@import`, a CSS `url()`, or an ES
      `import … from` / `import()`. Comments, markdown prose and fenced code blocks are stripped
      first, for the same reason as [1] — the vendored README documents the CDN URL it replaced,
      in prose and in a `curl` example, and a guard that fired on its own documentation would be
      deleted within a week. Navigation (`<a href>`) and XML namespaces (`xmlns="http://…"`) are
      not fetches and are not flagged.

  [3] SILENT FALLBACK / DANGLING LOCAL PATH. Two ways to lose the vendoring without ever writing a
      URL:
        (a) DELETE the `mermaid_library_url` line. The extension then uses its own default, which
            is a CDN — verified in this repo's installed copy, not recalled:
            node_modules/@sntke/antora-mermaid-extension/lib/extension.js:11
              const DEFAULT_MERMAID_LIBRARY_URL =
                'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs'
            and line 33: `config.mermaidLibraryUrl || DEFAULT_MERMAID_LIBRARY_URL`. So a playbook
            that requires the extension and omits the key is back on jsdelivr with nothing in the
            diff that says "https".
        (b) POINT IT AT A FILE THAT IS NOT THERE. `…/mermaid.esm.min.mjs` instead of `.js` is the
            live trap here — upstream's name is `.mjs`, the vendored entry was deliberately
            renamed `.js` because quay.io/rhpds/nginx:1.25 has no `mjs` MIME mapping. A one-letter
            "correction" back to upstream's name yields a 404 and, again, diagrams as raw text.
        (c) A local-looking value that is neither remote nor `{{{uiRootPath}}}`-relative is
            reported as UNRESOLVED, not as clean. "I could not check this" and "I checked and it
            is fine" are the two verdicts a gate may never conflate.

WHAT IT DELIBERATELY DOES NOT CHECK.
  • `ui.bundle.url` in the playbooks (the rhpds theme zip on github.com). That is a BUILD-time
    download by Antora on the build host, not a runtime fetch by the attendee's browser, and the
    cockpit's build host has egress by construction — it clones the repo. Flagging it would be a
    permanent false positive on all five playbooks.
  • showroom/ui-config.yml tab URLs. Those are the cluster's own Routes (`${DOMAIN}`), which is the
    entire point of the cockpit.
  • `fetch()` / `new URL()` in JavaScript. Too broad to separate a page asset from an API call, and
    no incident points at it. Adding a detector nobody can keep quiet takes the useful ones down
    with it.

BASELINE SHIPS EMPTY — and that is a measured result, not an assumption. Writing this guard turned
up a SECOND live CDN dependency the mermaid work had not touched: head-styles.hbs emitted two
`<link rel="preconnect">` and a `<link rel="stylesheet">` to fonts.googleapis.com / fonts.gstatic.com
for Red Hat Display/Text/Mono. It was pinned here while the fonts were vendored to
content/supplemental-ui/css/vendor/red-hat-fonts/; the pins were then deleted because the tree no
longer needs them. Detector [2] fires on that shape today — verified against the pre-vendoring
file — so the escape hatch stays for a future case that genuinely cannot be vendored. Use it as
an exact (tracked path, host) pair and never widen it to a bare host or a whole file: the pin is
supposed to stop being satisfied the moment the reference moves. A pin that matches nothing is
reported as stale (loud, but never a failure — failing there would redden main for somebody's fix).

GROUNDED AGAINST THE REAL REGRESSION, not only against fixtures. Run over the five playbooks as
they stood at e669f7c^ (`git show e669f7c^:content/site-workshop.yml` …), detector [1] reports all
five jsdelivr URLs; run over head-styles.hbs at the same commit, detector [2] reports all three
webfont <link>s. Both files are silent at HEAD. That is the property the CI job asserts: the guard
distinguishes the tree that shipped the bug from the tree that fixed it.

Exit codes:
  0  contract holds
  1  contract broken — or, under --self-test, every canary was correctly detected
  2  the guard could not inspect what it claims to inspect (no files found, unreadable tree)
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
UI_DIR = "content/supplemental-ui"

# ── pinned remote assets that cannot (yet) be vendored ────────────────────────────────────────────
# (tracked path, host). EXACT pairs only — a new host, or the same host in another file, still
# fails. Empty on purpose: the two Google Fonts entries this started with are gone because the
# fonts were vendored instead, which is always the better answer. Pin only what you cannot vendor,
# and say why in a comment next to the entry.
BASELINE: set[tuple[str, str]] = set()

# ── what counts as "somewhere else" ───────────────────────────────────────────────────────────────
# An absolute (https://host) or protocol-relative (//host) reference. Everything a browser resolves
# against the serving origin — `/js/x.js`, `../img/y.png`, `{{{uiRootPath}}}/…`, `data:`, `#frag` —
# is by definition air-gap-safe and is not matched at all.
_REMOTE = r"(?P<url>(?:https?:)?//(?P<host>[A-Za-z0-9][A-Za-z0-9._-]*\.[A-Za-z]{2,})[^'\"\s)>]*)"

# Tags whose src= makes the browser fetch. `<a href>` is navigation, not a fetch, and is absent by
# design; `<link href>` gets its own pattern because href on <link> IS a fetch.
_FETCH_TAGS = "script|img|iframe|source|embed|audio|video|track|object|input"

ASSET_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    ("script/img src", re.compile(
        rf"<\s*(?:{_FETCH_TAGS})\b[^>]{{0,600}}?\bsrc\s*=\s*[\"']?{_REMOTE}", re.I | re.S)),
    ("link href", re.compile(
        rf"<\s*link\b[^>]{{0,600}}?\bhref\s*=\s*[\"']?{_REMOTE}", re.I | re.S)),
    ("@import", re.compile(rf"@import\s+(?:url\(\s*)?[\"']?{_REMOTE}", re.I)),
    ("css url()", re.compile(rf"\burl\(\s*[\"']?{_REMOTE}", re.I)),
    # The mermaid regression itself was an ES module import, so the shape gets its own detector.
    ("es import", re.compile(rf"\b(?:import\s*\(\s*|from\s+|import\s+)[\"']{_REMOTE}", re.I)),
]

# `mermaid_library_url: <value>` — after comment stripping, so a commented-out line cannot match.
MERMAID_KEY = re.compile(r"^\s*mermaid_library_url\s*:\s*(?P<val>\S.*?)\s*$")
MERMAID_EXT = re.compile(r"^\s*-?\s*require\s*:.*antora-mermaid-extension")
UI_ROOT_TOKEN = re.compile(r"^\{\{\{?\s*uiRootPath\s*\}?\}\}")

BINARY_SUFFIXES = {
    ".ico", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".woff", ".woff2", ".ttf", ".otf",
    ".eot", ".zip", ".gz", ".pdf", ".mp4", ".webm", ".cast",
}


# ── comment / prose stripping ─────────────────────────────────────────────────────────────────────
# Every one of these exists because the project's own documentation MENTIONS the CDN it removed.
# A guard that cannot tell a reference from a remark is a guard that gets switched off.

def _is_canary(path: str) -> bool:
    """A fixture belonging to some guard's canary — never this guard's finding.

    Matches BOTH shapes. `foo-guard.canary.adoc` is a single-file canary; `foo-guard.canary/` is a
    directory canary holding a whole fake tree. The original test was `".canary." not in path`,
    which silently covered only the first: a directory canary's path contains `.canary/`, with a
    SLASH, so every .adoc inside it was scanned as real content. Latent in five guards until
    2026-08-12, when cockpit-attribute-emission-guard became the first directory canary to hold
    .adoc files and reddened attribute-interpolation-guard on a deliberately-malformed fixture.
    """
    return ".canary." in path or ".canary/" in path


def _strip_yaml_comments(text: str) -> str:
    """Quote-aware `#` stripping. `mermaid_library_url: "…"` is a quoted scalar, and the rationale
    comment above it contains the very URL detector [1] looks for."""
    out = []
    for line in text.splitlines():
        quote = None
        cut = len(line)
        for i, ch in enumerate(line):
            if quote:
                if ch == quote:
                    quote = None
            elif ch in "\"'":
                quote = ch
            elif ch == "#" and (i == 0 or line[i - 1] in " \t"):
                cut = i
                break
        out.append(line[:cut])
    return "\n".join(out)


def _strip_html_comments(text: str) -> str:
    return re.sub(r"<!--.*?-->", " ", text, flags=re.S)


def _strip_c_comments(text: str) -> str:
    """`/* … */` anywhere, and `//` only at the START of a line. Treating `//` as a comment mid-line
    would eat the `//` of every `https://` inside a string literal — i.e. would blind detector [2]
    on exactly the thing it exists to find."""
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"^[ \t]*//.*$", "", text, flags=re.M)


def _strip_markdown_code(text: str) -> str:
    """Fenced blocks and inline spans. Documentation is allowed to SHOW the wrong thing — the
    vendored README's refresh recipe is a `curl` to registry.npmjs.org inside a fence."""
    text = re.sub(r"^(```|~~~).*?^\1", " ", text, flags=re.S | re.M)
    return re.sub(r"`[^`\n]*`", " ", text)


def strip_noise(path: Path, text: str) -> str:
    suf = path.suffix.lower()
    if suf in (".yml", ".yaml"):
        return _strip_yaml_comments(text)
    if suf in (".md", ".markdown"):
        return _strip_markdown_code(_strip_html_comments(text))
    if suf in (".hbs", ".html", ".htm", ".svg", ".xml", ".adoc"):
        text = _strip_html_comments(text)
        # A .hbs is HTML with <style>/<script> inside it, so C comments apply too.
        return _strip_c_comments(text)
    if suf in (".js", ".mjs", ".cjs", ".css", ".ts"):
        return _strip_c_comments(text)
    return text


def read_text(path: Path) -> str | None:
    if path.suffix.lower() in BINARY_SUFFIXES:
        return None
    try:
        raw = path.read_bytes()
    except OSError:
        return None
    if b"\0" in raw[:4096]:
        return None
    return raw.decode("utf-8", errors="replace")


def rel(path: Path) -> str:
    try:
        return str(path.relative_to(REPO))
    except ValueError:
        return str(path)


def _line_of(text: str, pos: int) -> int:
    return text.count("\n", 0, pos) + 1


# ── file discovery ────────────────────────────────────────────────────────────────────────────────

def _ls_files(*pathspecs: str) -> list[Path]:
    try:
        out = subprocess.run(
            ["git", "-C", str(REPO), "ls-files", "--", *pathspecs],
            capture_output=True, text=True, check=True,
        ).stdout.splitlines()
    except Exception:
        return []
    return [REPO / f.strip() for f in out if f.strip() and not _is_canary(f)]


def tracked_playbooks() -> list[Path]:
    """Any tracked Antora playbook, found by NAME rather than by a hardcoded list of five paths —
    the playbook count has changed twice already and a list here would rot on the next rendering."""
    return [p for p in _ls_files("*.yml", "*.yaml")
            if re.match(r"^(site.*|antora-playbook.*)\.ya?ml$", p.name)]


def tracked_ui_files() -> list[Path]:
    # Directory pathspec, not a `**` glob: git treats a bare directory as a prefix match with no
    # dependence on glob magic. Both forms return the same 53 files today; this one cannot drift.
    return _ls_files(UI_DIR)


# ── detectors ─────────────────────────────────────────────────────────────────────────────────────

def check_cdn_library_url(playbooks) -> list[tuple[str, int, str]]:
    """[1] a remote mermaid_library_url — the exact regression e669f7c fixed."""
    hits = []
    for p in playbooks:
        text = read_text(p)
        if text is None:
            continue
        clean = strip_noise(p, text)
        for i, line in enumerate(clean.splitlines(), 1):
            m = MERMAID_KEY.match(line)
            if not m:
                continue
            val = m.group("val").strip().strip("\"'")
            if re.match(r"^(?:https?:)?//", val):
                hits.append((rel(p), i, val))
    return hits


def check_remote_ui_assets(ui_files, baseline=None) -> list[tuple[str, int, str, str, str]]:
    """[2] a supplemental-ui file that makes the browser fetch from another host.

    `baseline` is a parameter, not a global read, so the self-test can prove the allowlist matches
    (path, host) PAIRS rather than hosts — which is the only property that keeps a pin from
    quietly becoming a blanket exemption. It also means the shipped BASELINE can be empty without
    that proof going untested.
    """
    if baseline is None:
        baseline = BASELINE
    hits = []
    for p in ui_files:
        text = read_text(p)
        if text is None:
            continue
        clean = strip_noise(p, text)
        r = rel(p)
        seen: set[tuple[int, str]] = set()
        for kind, rx in ASSET_PATTERNS:
            for m in rx.finditer(clean):
                host = m.group("host")
                if (r, host) in baseline:
                    continue
                ln = _line_of(clean, m.start())
                if (ln, host) in seen:
                    continue
                seen.add((ln, host))
                hits.append((r, ln, kind, host, m.group("url")[:80]))
    return hits


def check_vendored_target(playbooks, ui_root: Path) -> list[tuple[str, str]]:
    """[3] silent CDN fallback (key deleted) or a local path that resolves to nothing."""
    hits = []
    for p in playbooks:
        text = read_text(p)
        if text is None:
            continue
        clean = strip_noise(p, text)
        lines = clean.splitlines()
        uses_ext = any(MERMAID_EXT.match(ln) for ln in lines)
        values = [m.group("val").strip().strip("\"'")
                  for m in (MERMAID_KEY.match(ln) for ln in lines) if m]
        if uses_ext and not values:
            hits.append((rel(p),
                         "requires antora-mermaid-extension but declares no mermaid_library_url — "
                         "the extension falls back to its jsdelivr default"))
            continue
        for val in values:
            if re.match(r"^(?:https?:)?//", val):
                continue  # detector [1] owns remote values; do not double-report
            m = UI_ROOT_TOKEN.match(val)
            if not m:
                # Not a uiRootPath-relative value: this guard cannot say where it resolves to.
                # Reported as unresolved rather than as a violation — a wrong accusation here
                # would be indistinguishable from a real one.
                hits.append((rel(p), f"mermaid_library_url={val!r} is neither remote nor "
                                     "{{{uiRootPath}}}-relative — cannot verify it resolves"))
                continue
            target = ui_root / val[m.end():].lstrip("/")
            if not target.is_file():
                hits.append((rel(p), f"mermaid_library_url points at {val!r}, which is not present "
                                     f"under {rel(ui_root)}/ — diagrams 404 and render as raw text"))
    return hits


# ── reporting ─────────────────────────────────────────────────────────────────────────────────────

def report(cdn_urls, remote_assets, targets, baseline_live) -> int:
    rc = 0
    if cdn_urls:
        rc = 1
        print(f"❌ [1] {len(cdn_urls)} playbook(s) load Mermaid from the public internet.")
        print("       Air-gapped or egress-restricted cluster ⇒ every diagram on every page")
        print("       renders as raw text. Point it at {{{uiRootPath}}}/js/vendor/mermaid/… .")
        for f, ln, val in cdn_urls:
            print(f"   {f}:{ln}  {val}")
    if remote_assets:
        rc = 1
        print(f"❌ [2] {len(remote_assets)} remote asset reference(s) under {UI_DIR}/.")
        print("       The attendee's browser fetches these from another host at page load.")
        print("       Vendor the file into the UI tree, or pin it in BASELINE with a reason.")
        for f, ln, kind, host, url in remote_assets:
            print(f"   {f}:{ln}  [{kind}] {host}  {url}")
    if targets:
        rc = 1
        print(f"❌ [3] {len(targets)} playbook(s) cannot be shown to load a vendored Mermaid.")
        for f, why in targets:
            print(f"   {f}: {why}")
    if baseline_live:
        print(f"ℹ️  {len(baseline_live)} pinned pre-existing remote asset(s) still in the tree "
              "(known, not fixed):")
        for f, host in sorted(baseline_live):
            print(f"   {f} → {host}")
    stale = BASELINE - baseline_live
    if stale:
        # NOT a failure. A pin that is no longer needed is dead config, never a regression — and
        # failing here would redden main for somebody else's *fix*.
        print(f"⚠️  {len(stale)} BASELINE pin(s) no longer match anything — delete them from "
              "no-cdn-assets-guard.py:")
        for f, host in sorted(stale):
            print(f"   {f} → {host}")
    if rc == 0:
        print("✅ no-cdn assets: Mermaid loads from the vendored copy in every playbook, and no")
        print("   unpinned supplemental-ui asset is fetched from another host.")
    return rc


def live_baseline(ui_files) -> set[tuple[str, str]]:
    """Which BASELINE pins are actually present right now. Answered by re-scanning WITHOUT the
    allowlist, so the pins are measured against the tree instead of asserted."""
    live = set()
    for p in ui_files:
        text = read_text(p)
        if text is None:
            continue
        clean = strip_noise(p, text)
        r = rel(p)
        for _kind, rx in ASSET_PATTERNS:
            for m in rx.finditer(clean):
                if (r, m.group("host")) in BASELINE:
                    live.add((r, m.group("host")))
    return live


# ── fixtures ──────────────────────────────────────────────────────────────────────────────────────

FIXTURE_CLEAN_PLAYBOOK = """---
ui:
  # Build-time theme download by Antora on the build host — NOT a browser fetch. Must stay legal.
  bundle:
    url: https://github.com/rhpds/rhdp_showroom_theme/releases/download/patternfly-6/ui-bundle.zip
antora:
  extensions:
    - require: '@sntke/antora-mermaid-extension'
      # Was https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.esm.min.mjs — recorded on purpose
      # so the next reader knows what was removed. A comment is not a reference.
      mermaid_library_url: "{{{uiRootPath}}}/js/vendor/mermaid/mermaid.esm.min.js"
"""

FIXTURE_CLEAN_UI = """    <link rel="stylesheet" href="{{{uiRootPath}}}/css/site.css">
    <script defer src="{{{uiRootPath}}}/js/click-to-run.js"></script>
    <!-- previously: <script type="module">import mermaid from
         'https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.esm.min.mjs'</script> -->
    <a class="navbar-item" href="https://www.redhat.com" target="_blank" rel="noopener">Red Hat</a>
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"></svg>
<style>
.a { background-image: url(../img/tile.png); }
.b { background-image: url("data:image/svg+xml;utf8,<svg/>"); }
.c { fill: url(#gradient); }
/* the CDN build used url(https://cdn.jsdelivr.net/npm/x/y.css) — a remark, not a fetch */
</style>
<script>
// import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.esm.min.mjs'
import mermaid from './vendor/mermaid/mermaid.esm.min.js';
</script>
"""

FIXTURE_CDN_PLAYBOOK = """---
antora:
  extensions:
    - require: '@sntke/antora-mermaid-extension'
      mermaid_library_url: "https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.esm.min.mjs"
"""

FIXTURE_NO_KEY_PLAYBOOK = """---
antora:
  extensions:
    - require: '@sntke/antora-mermaid-extension'
      script_stem: header-scripts
"""

FIXTURE_DANGLING_PLAYBOOK = """---
antora:
  extensions:
    - require: '@sntke/antora-mermaid-extension'
      mermaid_library_url: "{{{uiRootPath}}}/js/vendor/mermaid/mermaid.esm.min.mjs"
"""

# Local-looking but not uiRootPath-relative. The theme resolves uiRootPath per page depth, so a
# site-root-absolute path is not equivalent — and this guard cannot say where it lands, which is
# the one thing it must never pretend about.
FIXTURE_UNRESOLVABLE_PLAYBOOK = """---
antora:
  extensions:
    - require: '@sntke/antora-mermaid-extension'
      mermaid_library_url: "/js/vendor/mermaid/mermaid.esm.min.js"
"""

FIXTURE_REMOTE_UI = """    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/patternfly/pf.css">
    <script src="https://unpkg.com/htmx.org@1.9.10"></script>
<style>
@import url(https://fonts.example.net/css2?family=Foo);
.hero { background-image: url('https://images.example.net/hero.png'); }
</style>
<script type="module">
import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';
</script>
"""


def self_test(tmp: Path) -> int:  # noqa: C901 — one linear proof per canary reads better flat
    ui_root = tmp / "ui"
    (ui_root / "js" / "vendor" / "mermaid").mkdir(parents=True)
    (ui_root / "js" / "vendor" / "mermaid" / "mermaid.esm.min.js").write_text("export {};\n")

    # ── Proof 0: the CLEAN fixtures must be silent. A guard that fires on correct content is
    # deleted by the first person it blocks, taking the real detectors with it.
    pb = tmp / "site-clean.yml"
    pb.write_text(FIXTURE_CLEAN_PLAYBOOK)
    ui = tmp / "clean.hbs"
    ui.write_text(FIXTURE_CLEAN_UI)
    for name, found in (
        ("[1] clean playbook", check_cdn_library_url([pb])),
        ("[2] clean UI partial", check_remote_ui_assets([ui])),
        ("[3] clean playbook", check_vendored_target([pb], ui_root)),
    ):
        if found:
            print(f"❌ SELF-TEST FAILED: the CLEAN fixture was flagged by {name}: {found}")
            print("   Comments, <a href> navigation, xmlns, data:/relative url() and the recorded")
            print("   old CDN URL are all legitimate. A wolf-crier gets switched off.")
            return 2

    # ── Proof 0b: the REAL vendored README, which documents the CDN URL it replaced in prose AND
    # ships a curl to registry.npmjs.org in a fenced block, must be silent. Named explicitly
    # because it is the concrete file this guard was warned about.
    readme = REPO / UI_DIR / "js" / "vendor" / "mermaid" / "README.md"
    if not readme.is_file():
        print(f"❌ SELF-TEST FAILED: {rel(readme)} is missing — the documentation-is-not-a-reference")
        print("   proof cannot run, so the guard's tolerance for prose is unproven.")
        return 2
    found = check_remote_ui_assets([readme])
    if found:
        print(f"❌ SELF-TEST FAILED: the vendored README was flagged: {found}")
        print("   It DOCUMENTS the CDN URL that was removed. Documentation must never trip this.")
        return 2

    # ── Canary A — detector [1]: the exact pre-e669f7c value.
    f = tmp / "site-cdn.yml"
    f.write_text(FIXTURE_CDN_PLAYBOOK)
    if not check_cdn_library_url([f]):
        print("❌ SELF-TEST FAILED: a jsdelivr mermaid_library_url was NOT detected — detector [1]")
        print("   is blind and the CDN dependency can come straight back.")
        return 2

    # ── Canary B — detector [2], once per asset shape. A single combined assertion would pass
    # while three of the five patterns were dead.
    hits = check_remote_ui_assets([_write(tmp / "remote.hbs", FIXTURE_REMOTE_UI)])
    kinds = {k for _f, _l, k, _h, _u in hits}
    for want in ("link href", "script/img src", "@import", "css url()", "es import"):
        if want not in kinds:
            print(f"❌ SELF-TEST FAILED: the '{want}' asset shape was NOT detected (caught: "
                  f"{sorted(kinds)}) — that pattern is dead and a remote asset of that form ships.")
            return 2

    # ── Canary B2 — the real webfont regression this guard found while being written. These are
    # the three lines head-styles.hbs carried before the fonts were vendored; they must be caught,
    # or the guard would have watched the second CDN dependency walk straight back in.
    fonts = _write(tmp / "webfonts.hbs",
                   '    <link rel="preconnect" href="https://fonts.googleapis.com">\n'
                   '    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>\n'
                   '    <link rel="stylesheet" href="https://fonts.googleapis.com/css2'
                   '?family=Red+Hat+Text:wght@400;700&display=swap">\n')
    font_hits = check_remote_ui_assets([fonts])
    if {h for _f, _l, _k, h, _u in font_hits} != {"fonts.googleapis.com", "fonts.gstatic.com"}:
        print(f"❌ SELF-TEST FAILED: the pre-vendoring webfont <link>s were not all caught: "
              f"{font_hits}")
        return 2

    # ── Canary B3 — BASELINE must allowlist by (path, host) PAIR, never host-wide. Proven with a
    # synthetic pin so the property stays tested while the shipped BASELINE is empty.
    pin = {(rel(fonts), "fonts.gstatic.com")}
    kept = {h for _f, _l, _k, h, _u in check_remote_ui_assets([fonts], baseline=pin)}
    if kept != {"fonts.googleapis.com"}:
        print(f"❌ SELF-TEST FAILED: a (path, host) pin did not suppress exactly its own host "
              f"(remaining: {sorted(kept)}).")
        return 2
    elsewhere = _write(tmp / "elsewhere.hbs",
                       '<link rel="stylesheet" href="https://fonts.gstatic.com/x.css">\n')
    if not check_remote_ui_assets([elsewhere], baseline=pin):
        print("❌ SELF-TEST FAILED: a host pinned for ONE file was tolerated in another file —")
        print("   the allowlist has become a blanket exemption for that host.")
        return 2

    # ── Canary C — detector [3a]: delete the line, get the extension's jsdelivr default.
    f = tmp / "site-nokey.yml"
    f.write_text(FIXTURE_NO_KEY_PLAYBOOK)
    if not check_vendored_target([f], ui_root):
        print("❌ SELF-TEST FAILED: a playbook that requires the mermaid extension with NO")
        print("   mermaid_library_url was NOT detected — that is a silent fallback to the")
        print("   extension's own CDN default, with no 'https' anywhere in the diff.")
        return 2

    # ── Canary D — detector [3b]: the .mjs↔.js rename trap, as a 404 instead of a URL.
    f = tmp / "site-dangling.yml"
    f.write_text(FIXTURE_DANGLING_PLAYBOOK)
    if not check_vendored_target([f], ui_root):
        print("❌ SELF-TEST FAILED: a mermaid_library_url pointing at a NON-EXISTENT vendored file")
        print("   was NOT detected — diagrams would 404 and render as raw text.")
        return 2

    # ── Canary E — detector [3c]: a local-looking value this guard cannot resolve. It must say so
    # rather than pass it, because "I could not check" and "I checked and it is fine" are the two
    # things a gate may never conflate. Its own witness, so blinding the branch has a CI signal.
    f = tmp / "site-unresolvable.yml"
    f.write_text(FIXTURE_UNRESOLVABLE_PLAYBOOK)
    found = check_vendored_target([f], ui_root)
    if not found or "cannot verify" not in found[0][1]:
        print("❌ SELF-TEST FAILED: a mermaid_library_url that is neither remote nor")
        print("   {{{uiRootPath}}}-relative was silently accepted — the guard reported a clean")
        print("   verdict on a value it never resolved.")
        return 2

    # ── Proof 1: the guard must be able to SEE the real tree, or a clean verdict means nothing.
    playbooks = tracked_playbooks()
    ui_files = tracked_ui_files()
    if not playbooks:
        print("❌ SELF-TEST FAILED: no tracked site playbooks found — the guard would pass by")
        print("   scanning nothing.")
        return 2
    if not ui_files:
        print(f"❌ SELF-TEST FAILED: no tracked files under {UI_DIR}/ — detector [2] would pass by")
        print("   scanning nothing.")
        return 2

    print("✅ self-test ok — clean playbook + clean UI partial + the real vendored README all")
    print("   silent; jsdelivr URL, five remote-asset shapes, the pre-vendoring webfont <link>s,")
    print("   a host pinned for another file, a deleted key, a dangling vendored path and an")
    print("   unresolvable local path all caught;")
    print(f"   {len(playbooks)} playbook(s) and {len(ui_files)} UI file(s) visible to the real scan.")
    return 1  # house convention: every canary caught == exit exactly 1


def _write(p: Path, text: str) -> Path:
    p.write_text(text)
    return p


def main(argv=None) -> int:
    # `argv` is NOT decoration. tools/lint/_canary-coverage.py blinds each detector in turn and
    # calls `mod.main(argv)` in-process; a zero-arg main() raises TypeError there, the harness
    # remaps it to 2, and the guard's unmutated control comes back 2/2 instead of 0/1 — reported as
    # COULD NOT INSPECT, which fails the canary-coverage job for every push that touches
    # tools/lint/. Measured 2026-08-05 against this file before the parameter was added.
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--self-test", action="store_true",
                    help="prove the detectors fire against planted canaries (exit 1 = PASS)")
    args = ap.parse_args(argv)

    if args.self_test:
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            return self_test(Path(td))

    playbooks = tracked_playbooks()
    ui_files = tracked_ui_files()
    if not playbooks:
        print("❌ no tracked site playbooks found — refusing to report a clean scan of nothing.")
        return 2
    if not ui_files:
        print(f"❌ no tracked files under {UI_DIR}/ — refusing to report a clean scan of nothing.")
        return 2

    print(f"   scanned {len(playbooks)} playbook(s) and {len(ui_files)} file(s) under {UI_DIR}/")
    return report(
        check_cdn_library_url(playbooks),
        check_remote_ui_assets(ui_files),
        check_vendored_target(playbooks, REPO / UI_DIR),
        live_baseline(ui_files),
    )


if __name__ == "__main__":
    sys.exit(main())
