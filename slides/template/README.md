# Slides template (swappable — ADR-0005)

Drop the **Red Hat corporate template** here as `reference.pptx` (or `.potx`) and every deck build uses it — no code change. Until then, builds run in **placeholder mode** (python-pptx default layouts), per the 2026-07-08 gate decision.

If the Red Hat template's layout names differ from the defaults, map them in `layout-map.yaml`:

```yaml
# role: layout name as it appears in the template's slide master
section: "Section Divider"
content: "Title and Body"
```

Build: `python3 tools/slides/build-deck.py` → `slides/dist/deck.pptx` (gitignored; attached to releases).
