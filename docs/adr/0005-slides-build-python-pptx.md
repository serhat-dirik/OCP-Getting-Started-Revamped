# ADR-0005: Slides build — python-pptx generator with a swappable reference template

Date: 2026-07-08 · Status: accepted, amended 2026-07-09 · Owner: PM (spike by research-analyst)

> **Amendment (project owner, 2026-07-09):** Phase-6 deck ASSEMBLY runs through the Red Hat presentation
> skill (redhat-deck-design) available in the build environment — it owns branding/layout fidelity.
> The `slides/outlines/*.md` schema stays the source of truth and `build-deck.py` remains the
> CI structural proof + template-file fallback for environments without the skill.

## Context

`slides/outlines/*.md` use a structured schema (`## Slide:` / bullets / `Notes:` / `Visual:`) and must build to PPTX **in the Red Hat corporate template**, scriptable in CI (no GUI). The real template file arrives later (gate answer: proceed with a placeholder). Evaluated: pandoc `--reference-doc` (needs a preprocessor anyway; weak per-slide placement), md2pptx (ties us to its dialect), marp (exports images-per-slide — not editable; rejected), python-pptx (full placeholder control, template = named layouts in a swappable `.potx`/reference deck).

## Decision

A thin **python-pptx** generator (`tools/slides/build-deck.py`) parses the outline schema and instantiates slides from **named layouts** in `slides/template/` (placeholder now, Red Hat `.potx` later — file swap, optionally a layout-name map, no code change). CI proof: build a sample outline in GitHub Actions, re-open the artifact with python-pptx, assert slide count + bullets + notes.

## Consequences

- We own ~150 lines of build script; in exchange we get deterministic RH-layout mapping and a clean template swap.
- pandoc `--reference-doc` stays the documented fallback.

## Update (2026-07-18) — CI structural proof wired

The CI proof promised under *Decision* is now implemented as `.github/workflows/slides-build.yml`
(path-filtered to `slides/outlines/**`, `tools/slides/**`, `modules.yaml`): it installs
python-pptx, runs `build-deck.py` on two outlines (whose own self-check fails the build if the
built slide count is below what it parsed), then re-opens the artifact with python-pptx and
asserts the slide count independently. The branded assembly (redhat-deck-design skill) needs
LibreOffice + fonts + the authored icon set and is **not** reproducible in CI, so CI validates
the schema + template-fallback path only — the skill remains the presentation-output path per
the 2026-07-09 amendment. Branded build usage is documented in `slides/template/README.md`.

## Update (recorded 2026-07-31, describing changes made 2026-07-25) — the CI proof above no longer exists, and neither does its input tree

> Recorded six days late, and that is the point: until 2026-07-31 `.gitignore` excluded `docs/`
> wholesale, so no ADR ever appeared in a diff. Two commits removed this ADR's CI gate and its
> entire input tree and nothing prompted anyone to amend the record, because the record was
> invisible. Same root cause as ADR-0002's stale security claim.

Verified against the repo as it stands today, not recalled: `.github/workflows/slides-build.yml`
is gone (`git log --all --diff-filter=D -- .github/workflows/slides-build.yml` → deleted in
`eb68c8e`, "the decks are committed artifacts now"), `slides/` itself does not exist on disk, and
`git log --diff-filter=D --summary -- 'slides/*'` shows it untracked wholesale the same day in
`e7511bea` ("keep slides out of the public repo" — SA decks are internal enablement material,
shared through an internal drive, not this repo). `ls .github/workflows/` today: `apps-test.yml`,
`content-build.yml`, `lint.yml`, `link-check.yml`, `pages-preview.yml` — no slides job.

Two sequential decisions, same day, superseding each other: `eb68c8e` first dropped only the CI
job (reasoning: decks would ship as committed `.pptx` binaries, so there was nothing left to build
in CI) and untracked `tools/slides/`; `e7511bea` then went further and untracked `slides/`
entirely, including the finished `.pptx` files `eb68c8e` had just started committing — the owner
decision to keep decks off the public repo altogether, not a build-pipeline problem.

Current state: `slides/outlines/*.md` and `slides/template/` referenced above do not exist.
The schema now lives at `sa-guides/outlines/*.md` and the generator at `tools/slides/build-deck.py`
— both present on disk but **gitignored** (`.gitignore` lines for `sa-guides/` and `tools/slides/`,
confirmed with `git check-ignore -v`), i.e. maintainer-local material, not part of this repo's
tracked tree and not CI-checked. This ADR's Decision (python-pptx generator, swappable template,
named-layout instantiation) is still the mechanism in local use; only the "CI structural proof"
and "tracked in this repo" parts of the 2026-07-18 Update are stale. There is no CI gate for the
slide build today.
