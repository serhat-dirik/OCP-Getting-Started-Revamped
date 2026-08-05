# Vendored Red Hat fonts (air-gap / egress-restricted rendering)

Red Hat Display, Red Hat Text and Red Hat Mono, **SIL Open Font License 1.1** (see `LICENSE`),
vendored as the `.woff2` files that `https://fonts.googleapis.com` was serving to us.

## Why it is here

`partials/head-styles.hbs` used to emit two `<link rel="preconnect">` (googleapis + gstatic) and a
`<link rel="stylesheet" href="https://fonts.googleapis.com/css2?…">`. This was the **last** external
request the built site made after Mermaid was vendored — measured by loading the built site with
every non-localhost request blocked.

The theme bundle's own `site.css` names `Red Hat Text` / `Red Hat Display` / `Red Hat Mono` in its
`font-family` stacks but ships **no `@font-face` of its own**, so that remote stylesheet was the only
thing supplying the faces. Without it, on an air-gapped or egress-restricted cluster — and the
Showroom cockpit serves from in-cluster, where egress is not guaranteed — the page:

1. falls back to `helvetica, arial, sans-serif` (wrong typeface, not broken), **and**
2. pays a DNS + TCP timeout on two preconnects and a stylesheet on *every page load*, which is a
   visible stall before first paint.

Now `head-styles.hbs` links `red-hat-fonts.css` from this directory via `{{{uiRootPath}}}`, and the
faces are served from the same origin as the site.

## Three things that are easy to get wrong here

1. **These are variable fonts — one file serves several weights.** The css2 API returned the same
   `.woff2` URL for Display 400, 500 *and* 700; the browser instantiates the `wght` axis from each
   `@font-face`'s own `font-weight` descriptor. So six files back fourteen `@font-face` rules. Do
   not "deduplicate" the rules down to one per file: that is what selects the weight.

2. **`red-hat-fonts.css` is a mechanical transform, not hand-written.** Every `@font-face` block —
   weights, `unicode-range`, `font-display: swap` — is byte-for-byte what Google served; only the
   fourteen `url()` targets were rewritten to the filenames next to this file. Keeping it a pure
   transform is what makes "renders identically to before" checkable rather than asserted. Edit the
   recipe below, never the output.

3. **The `unicode-range` split is deliberate.** Google splits each family into `latin` and
   `latin-ext`; the browser fetches `latin-ext` only if the page actually uses a character in that
   range. Concatenating the subsets would make every page load pull ~30% more font bytes for glyphs
   an English workshop never draws. (Only these two subsets are offered for these families — there
   is no cyrillic/greek variant to drop.)

## Refreshing

Run from a scratch directory. `curl` **must** send a modern browser User-Agent — the css2 API
content-negotiates on it and will hand a non-browser client `.ttf` URLs instead of `.woff2`.

```sh
VEND=<repo>/content/supplemental-ui/css/vendor/red-hat-fonts
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
URL='https://fonts.googleapis.com/css2?family=Red+Hat+Display:wght@400;500;700&family=Red+Hat+Mono:wght@400;700&family=Red+Hat+Text:wght@400;700&display=swap'
curl -sS -A "$UA" "$URL" -o gf.css

python3 - "$VEND" <<'PY'
import os, re, subprocess, sys
VEND = sys.argv[1]
css = open("gf.css").read()
# Name each file <family>-<subset>.woff2 from the /* subset */ comment preceding its rule.
subset, names = None, {}
for line in css.splitlines():
    m = re.match(r"/\* (\S+) \*/", line)
    if m:
        subset = m.group(1)
    m = re.search(r"font-family: '([^']+)'", line)
    if m:
        fam = m.group(1).lower().replace(' ', '-')
    m = re.search(r"url\((https://fonts\.gstatic\.com/[^)]+)\)", line)
    if m:
        names[m.group(1)] = "%s-%s.woff2" % (fam, subset)
for url, name in names.items():
    subprocess.run(["curl", "-sfL", url, "-o", os.path.join(VEND, name)], check=True)
out = re.sub(r"url\((https://fonts\.gstatic\.com/[^)]+)\)",
             lambda m: "url(%s)" % names[m.group(1)], css)
assert "gstatic" not in out and "googleapis" not in out
hdr = open(os.path.join(VEND, "red-hat-fonts.css")).read().split("*/\n\n", 1)[0] + "*/\n\n"
open(os.path.join(VEND, "red-hat-fonts.css"), "w").write(hdr + out)
print("vendored", len(names), "files;", out.count("@font-face"), "rules")
PY

curl -sfL https://raw.githubusercontent.com/RedHatOfficial/RedHatFont/master/LICENSE -o "$VEND/LICENSE"
```

## Verifying (and the trap that makes the obvious check lie)

Rebuild, then **verify with the network blocked, not merely that the files exist**: serve
`www/workshop/` locally and load a page with every non-localhost request aborted.

**Do not assert with `document.fonts.check('700 1em "Red Hat Display"')`.** Red Hat Display / Text /
Mono are installed as *system* fonts on many Red Hat laptops, and `check()` answers "can I render
this family?", which a system install satisfies. Measured 2026-08-05: a deliberate canary run with
`red-hat-fonts.css` emptied still returned `true` for all seven faces — the check passes just as
happily when the vendoring is completely broken.

Assert on the `FontFaceSet` instead. It contains *only* CSS-declared `@font-face` rules, and an
entry reaches `status === 'loaded'` only after its `.woff2` was fetched and parsed:

```js
await Promise.all([...document.fonts].map((f) => f.load()));
[...document.fonts].length                                        // must be 14
[...document.fonts].filter((f) => f.status === 'loaded').length    // must be 14
```

plus zero `requestfailed` events for a non-localhost URL. With the stylesheet emptied that first
number is `0`, so the canary fails as it should.

(Deduplicating the loaded list by family+weight gives 7, not 14 — that is just the two subsets of
each face collapsing, not a failure.)
