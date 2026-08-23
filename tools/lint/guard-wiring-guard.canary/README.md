# guard-wiring-guard fixtures

Each case is a miniature repo — `.github/workflows/` plus `tools/lint/` — and trips EXACTLY ONE
detector. `--self-test` drives the guard's real `main()` over each tree with the tree as its root.

`control-good` also carries a shell-COMMENTED guard reference. That is not decoration: lint.yml
really does contain a note reading `(tools/lint/seed-drift-guard.sh, deleted)`, and a check that
greps raw workflow text reports that long-gone guard as wired — finding a defect that is not there
while missing the one that is. The control proves the comment stripping still happens.
