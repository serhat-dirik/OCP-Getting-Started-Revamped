# Slides template (swappable — ADR-0005)

Drop the **Red Hat corporate template** here as `reference.pptx` (or `.potx`) and every deck build uses it — no code change. Until then, builds run in **placeholder mode** (python-pptx default layouts), per the 2026-07-08 gate decision.

If the Red Hat template's layout names differ from the defaults, map them in `layout-map.yaml`:

```yaml
# role: layout name as it appears in the template's slide master
section: "Section Divider"
content: "Title and Body"
```

Build: `python3 tools/slides/build-deck.py` → `slides/dist/deck.pptx` (gitignored; attached to releases).

## Branded build (ADR-0005 amendment)

Two builders read the **same** `slides/outlines/*.md` schema; they never diverge on content order or numbering (both key off `modules.yaml`, position = number).

| Path | Tool | Output | When |
|---|---|---|---|
| **Branded** (presentation) | `redhat-deck-design` skill | on-brand, native/editable decks | producing decks an SA presents |
| **Structural** (fallback + CI) | `tools/slides/build-deck.py` | placeholder-layout deck | environments without the skill; CI proof |

**Branded path** — the `redhat-deck-design` presentation skill owns branding and layout fidelity (per the 2026-07-09 owner amendment). It renders:

- `slides/dist/ocp-getting-started-overview.pptx` — the hand-crafted SA field overview (~13 slides).
- `slides/dist/modules/mNN-<slug>.pptx` — one branded deck per module, via a schema-driven generator (section divider from `#`, `kt()`-style header per `## Slide:`, bullets → flowing cards, `Notes:` → speaker notes, `Visual:` → an embedded asset or a **`MEDIA PASS`** placeholder).
- `slides/dist/ocp-getting-started-full.pptx` — every module in catalog order through the same generator.

All land in `slides/dist/` (**gitignored** — build artifacts, attached to releases, never committed). The skill's scripts/assets are copied into a working folder **outside the repo tree** and are not vendored here. `Visual:` lines that name a concept diagram not yet on disk render a clean branded placeholder tagged `MEDIA PASS` — swap in real captures during the media pass.

> The **placeholder-mode** note above (python-pptx default layouts) still describes `build-deck.py`; for skill-equipped environments the branded path supersedes it as the presentation output. `build-deck.py` remains the deterministic CI structural proof and the template-file fallback.

**CI** — `.github/workflows/slides-build.yml` proves the schema builds: it runs `build-deck.py` on two outlines (self-check on slide count) and re-opens the artifact with python-pptx to assert the count independently.
