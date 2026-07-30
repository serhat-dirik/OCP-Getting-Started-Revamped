#!/usr/bin/env python3
"""maas-model-drift-guard.py — catches the MaaS model default drifting from its source of truth.

WHY THIS EXISTS. `versions.yaml`'s `maas.model` entry is the audited source of truth for which
model the per-user MaaS key is scoped to (task #67 QA gate: the prior `qwen3-14b` default returned
a live HTTP 401 `key_model_access_denied` against `llama-scout-17b`-scoped keys). `content/antora.yml`
carries its own copy — the `asciidoc.attributes.maas_model` dev default that ships to every module
referencing `{maas_model}` unless a deploy playbook overrides it. The two values agree today, by
hand, and nothing re-checks that after this commit. Unlike `version-attributes.adoc` — generated
from `versions.yaml` by `tools/gen-attributes.sh` and gated in content-build's "Version-attribute
drift gate" — `maas_model` has no generator and no gate, so a `versions.yaml` model correction (the
exact kind of fix task #67 made) can go in without anyone touching `antora.yml`, and the stale
default would ship silently: every attendee namespace gets a MaaS key scoped to the OLD model and
every `{maas_model}` reference in the built site quietly lies about what the cluster actually serves.

WHAT IT CHECKS. Two raw values, read directly out of the two files (no YAML parser dependency —
same stdlib-only approach as `curl-format-guard.py`, so this guard needs nothing installed beyond
python3 in CI):

  * `versions.yaml`      — the `model:` key inside the top-level `maas:` block.
  * `content/antora.yml` — the `maas_model:` key inside `asciidoc.attributes` (a quoted string
                           carrying this project's trailing `@` soft-set marker, e.g.
                           `"llama-scout-17b@"` — stripped before comparing).

Either value missing, ambiguous (more than one candidate line), or the source file itself missing
is an ERROR (exit 2), never a silent pass — the failure mode this guard exists to prevent is
exactly a check that quietly inspects nothing.

USAGE
    tools/lint/maas-model-drift-guard.py                 # compare the real repo files
    tools/lint/maas-model-drift-guard.py --self-test      # canary fixtures; must exit 1

FIXING A HIT: decide which side is stale — almost always `versions.yaml` just got corrected by a
live QA finding — and update the other file's value (never both blindly) so they agree again. If
`versions.yaml` changed, re-verify `{maas_endpoint}` usage sites still make sense before committing.

EXIT CODES (same contract as this repo's other guards, e.g. `curl-format-guard.py`):
    0  the two values agree
    1  drift found — or, under --self-test, both canary pairs behaved exactly as declared
    2  the guard could not do its job (file missing, key missing/ambiguous, or a self-test canary
       did not behave as declared). Never confuse this with a clean result.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys


class GuardError(Exception):
    """The guard cannot do its job for this file. Always an exit 2, never a silent pass."""


def repo_root() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parents[2]


def _read(path: pathlib.Path) -> str:
    if not path.is_file():
        raise GuardError(f"{path} does not exist. It was moved or renamed; update this guard "
                          "rather than leaving it pointing at nothing.")
    return path.read_text(encoding="utf-8")


# A top-level YAML key: starts at column 0, `name:` (a block header or a scalar with no indented
# body — either way it ends whatever indented block came before it).
TOP_LEVEL_KEY_RE = re.compile(r"^[A-Za-z0-9_-]+\s*:")

# The `model:` key, indented under `maas:`. Value is a bare (unquoted) scalar in this file, running
# up to whitespace or a trailing `#` comment.
MAAS_MODEL_LINE_RE = re.compile(r"^\s+model\s*:\s*([^\s#]+)")

# The `maas_model:` key inside content/antora.yml's `asciidoc.attributes` map. Value is a quoted
# string carrying this project's trailing `@` soft-set marker (04-STYLE-GUIDE — env defaults are
# `@`-suffixed so a deploy playbook can override them).
ANTORA_MAAS_MODEL_RE = re.compile(r'^\s*maas_model\s*:\s*"([^"]*)"')


def extract_versions_yaml_model(text: str, origin: str) -> str:
    """The value of `model:` inside versions.yaml's top-level `maas:` block."""
    lines = text.splitlines()
    in_block = False
    candidates: list[str] = []
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if re.match(r"^maas\s*:", line):
            in_block = True
            continue
        if in_block and TOP_LEVEL_KEY_RE.match(line):
            break  # a new top-level key ends the maas: block
        if in_block:
            m = MAAS_MODEL_LINE_RE.match(line)
            if m:
                candidates.append(m.group(1))
    if not candidates:
        raise GuardError(f"{origin}: no `model:` key found inside a top-level `maas:` block. The "
                          "entry was renamed or restructured — update this guard's extractor "
                          "rather than leaving it pointing at nothing.")
    if len(candidates) > 1:
        raise GuardError(f"{origin}: found {len(candidates)} `model:` candidates inside the "
                          f"`maas:` block ({candidates!r}) — expected exactly 1. Refusing to guess "
                          "which one is authoritative.")
    return candidates[0]


def extract_antora_maas_model(text: str, origin: str) -> str:
    """The value of `maas_model:` inside content/antora.yml, with the `@` soft-set marker stripped."""
    candidates = [m.group(1) for m in
                  (ANTORA_MAAS_MODEL_RE.match(line) for line in text.splitlines()) if m]
    if not candidates:
        raise GuardError(f"{origin}: no `maas_model: \"...\"` key found. It was renamed, moved out "
                          "of asciidoc.attributes, or its quoting style changed — update this "
                          "guard's extractor rather than leaving it pointing at nothing.")
    if len(candidates) > 1:
        raise GuardError(f"{origin}: found {len(candidates)} `maas_model:` candidates ({candidates!r})"
                          " — expected exactly 1. Refusing to guess which one is authoritative.")
    raw = candidates[0]
    return raw[:-1] if raw.endswith("@") else raw


def check(versions_path: pathlib.Path, antora_path: pathlib.Path) -> tuple[bool, str]:
    """Returns (drifted, message)."""
    versions_value = extract_versions_yaml_model(_read(versions_path), str(versions_path))
    antora_value = extract_antora_maas_model(_read(antora_path), str(antora_path))
    if versions_value == antora_value:
        return False, (f"clean: {versions_path} maas.model = {antora_path} asciidoc.attributes."
                        f"maas_model = {versions_value!r}")
    return True, (f"DRIFT: {versions_path} maas.model = {versions_value!r} but {antora_path} "
                  f"asciidoc.attributes.maas_model = {antora_value!r} (after stripping the "
                  "trailing `@`). Decide which side is stale and update the other one to match — "
                  "never edit both to a third value.")


# ---------------------------------------------------------------------------- self-test


def self_test(root: pathlib.Path) -> int:
    fixture = root / "tools/lint/maas-model-drift-guard.canary"
    versions_fixture = fixture / "versions.yaml"
    clean_fixture = fixture / "antora-clean.yml"
    drifted_fixture = fixture / "antora-drifted.yml"

    if not (versions_fixture.is_file() and clean_fixture.is_file() and drifted_fixture.is_file()):
        print("::error::maas-model-drift-guard: canary fixtures are missing under "
              f"{fixture} — detection is unproven, so a clean result on the real tree means "
              "nothing.", file=sys.stderr)
        return 2

    failures: list[str] = []

    try:
        drifted, msg = check(versions_fixture, drifted_fixture)
    except GuardError as exc:
        failures.append(f"drifted canary: the guard could not evaluate it at all — {exc}")
    else:
        if not drifted:
            failures.append("drifted canary: expected DRIFT, got clean. The detector is blind.")
        else:
            print(f"self-test: drifted canary -> DRIFT detected, as declared ✅\n    {msg}")

    try:
        drifted, msg = check(versions_fixture, clean_fixture)
    except GuardError as exc:
        failures.append(f"clean canary: the guard could not evaluate it at all — {exc}")
    else:
        if drifted:
            failures.append(f"clean canary: expected clean, got DRIFT ({msg}). The detector "
                             "false-positives on values that genuinely agree.")
        else:
            print(f"self-test: clean canary -> clean, as declared ✅\n    {msg}")

    if failures:
        for failure in failures:
            print(f"::error::maas-model-drift-guard SELF-TEST FAILED — {failure}", file=sys.stderr)
        return 2

    print("self-test ok — drift is detected on the drifted canary and the clean canary stays "
          "clean (2 fixture pairs proven).")
    return 1


# ---------------------------------------------------------------------------- main


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--self-test", action="store_true",
                     help="scan the canary fixtures instead of the real repo files; a result "
                          "other than 1 means detection is unproven, not that the tree is fine")
    args = ap.parse_args(argv)

    root = repo_root()

    if args.self_test:
        return self_test(root)

    versions_path = root / "versions.yaml"
    antora_path = root / "content/antora.yml"

    try:
        drifted, msg = check(versions_path, antora_path)
    except GuardError as exc:
        print(f"::error::maas-model-drift-guard {exc}", file=sys.stderr)
        return 2

    if drifted:
        print(f"::error::{msg}", file=sys.stderr)
        return 1

    print(f"maas-model-drift-guard: {msg}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
