# Vendored Mermaid (air-gap / egress-restricted rendering)

Mermaid **10.9.8**, MIT (see `LICENSE`), vendored from the npm tarball
`https://registry.npmjs.org/mermaid/-/mermaid-10.9.8.tgz` (`package/dist/`).

## Why it is here

All five Antora playbooks used to point `mermaid_library_url` at
`https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.esm.min.mjs`. On an air-gapped or
egress-restricted cluster that import fails and **every diagram on every page renders as raw
text** — and the Showroom cockpit serves from in-cluster, where egress is not guaranteed.
The playbooks now point at this directory via `{{{uiRootPath}}}`, so the library is served from
the same origin as the site.

## Two things that are easy to get wrong here

1. **The ESM build lazy-loads one chunk per diagram type.** `mermaid.esm.min.js` is 76 bytes; it
   re-exports from `mermaid-b1704b0f.js`, which `import()`s a separate chunk the first time a
   given diagram type is drawn. Vendoring only the entry file yields a site that looks perfect
   until somebody writes a `sequenceDiagram`, and then that one page is broken. **All 45 files of
   the transitive closure are vendored** — the entry, the core chunk, and every diagram-type,
   layout and theme chunk it can reach. Do not prune by "diagram types we currently use".
   (`elk-api.js` / `elk-worker.min.js` appear as strings inside `flowchart-elk-definition-*.js`;
   those are elkjs's own inlined browserify module map, not files to fetch.)

2. **The entry is renamed `.mjs` → `.js` on purpose.** The cockpit is served by
   `quay.io/rhpds/nginx:1.25`, whose stock `conf/mime.types` has **no `mjs` entry** (verified
   against `nginx/nginx@release-1.25.3`) — an `.mjs` file would go out as the default
   `application/octet-stream`, and browsers refuse to execute an ES module with a non-JavaScript
   MIME type. The file content is byte-identical to upstream `mermaid.esm.min.mjs`; only the name
   changed. Every chunk it pulls in is already `.js`.

## Refreshing to a new Mermaid version

Run from a scratch directory, then update the five `mermaid_library_url` values only if the entry
filename changes (it does not, by design):

```sh
V=10.9.8   # pick the version; the site rendered on the 10.x line
curl -sL "https://registry.npmjs.org/mermaid/-/mermaid-$V.tgz" | tar xz
VEND=<repo>/content/supplemental-ui/js/vendor/mermaid
rm -f "$VEND"/*.js
python3 - "$VEND" <<'PY'
import os, re, shutil, sys
DIST, VEND = "package/dist", sys.argv[1]
pat = re.compile(r'''(?:from|import)\s*\(?\s*["'](\.[^"']+)["']''')
seen, stack = set(), ["mermaid.esm.min.mjs"]
while stack:
    f = stack.pop()
    if f in seen:
        continue
    seen.add(f)
    p = os.path.join(DIST, f)
    if not os.path.isfile(p):
        raise SystemExit("missing chunk: " + f)
    for m in pat.findall(open(p, encoding="utf8", errors="replace").read()):
        stack.append(os.path.normpath(os.path.join(os.path.dirname(f), m)))
for f in seen:
    shutil.copy2(os.path.join(DIST, f),
                 os.path.join(VEND, "mermaid.esm.min.js" if f.endswith(".mjs") else f))
print("vendored", len(seen), "files")
PY
curl -sfL "https://raw.githubusercontent.com/mermaid-js/mermaid/v$V/LICENSE" -o "$VEND/LICENSE"
```

Then rebuild and **verify with the CDN blocked, not merely that the files exist** — see the
offline check described in this directory's commit message: serve `www/workshop/` locally, load a
page with every non-localhost request aborted, and assert that a flowchart *and* a
`sequenceDiagram` both produce `<svg>`.
