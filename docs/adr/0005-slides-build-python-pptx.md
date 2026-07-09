# ADR-0005: Slides build — python-pptx generator with a swappable reference template

Date: 2026-07-08 · Status: accepted, amended 2026-07-09 · Owner: PM (spike by research-analyst)

> **Amendment (Serhat, 2026-07-09):** Phase-6 deck ASSEMBLY runs through the Red Hat presentation
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
