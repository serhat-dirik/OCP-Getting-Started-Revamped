# devworkspace-editor-guard fixtures

One chart per detector, plus a control that must stay silent. `--self-test` drives the guard's
REAL `main()` over each directory and asserts both its exit code and the text it printed, so
no-op'ing any single `problems.append(...)` makes the self-test exit 2. That is the whole point:
before these existed the self-test asserted a *reimplementation* of the detection logic and
`_canary-coverage.py` scored the guard 0/5 — five detectors that could stop working with no CI
signal at all.

These are NOT in `gitops/entry-states/`, so CI's `helm lint + template every chart` step (which
globs exactly that path) never sees `canary-unrenderable`, whose whole job is to fail to render.
