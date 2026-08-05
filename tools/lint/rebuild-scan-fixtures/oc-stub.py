#!/usr/bin/env python3
"""A recording of `oc`, good enough to run the read-only half of `ws rebuild-images` off-cluster.

Installed as `oc` at the front of PATH by rebuild-scan-guard.py. Normalizes argv into a key, looks
that key up in a JSON dump of cluster.yaml's `calls:`, and prints what the real command printed.

AN UNKNOWN CALL IS NOT AN EMPTY ANSWER. Every read in the scan is written `2>/dev/null || true`,
because on a real cluster a denied or absent object must not abort the report. That makes silence
indistinguishable from "nothing there" — the exact reason `ws doctor`'s drift row has to establish
read access before scanning. It does that with a REAL bounded read, not `oc auth can-i`: measured
2026-08-06, can-i answers "yes" for a cluster-scoped resource the identity cannot actually read, and
that false YES turned the drift row into a false ✅ "n/a (nothing running consumes a workshop-built
image yet)" for every attendee. A stub that quietly returned nothing for a call it did not model
would reproduce that blindness inside the test: the suite would go on comparing rows produced from
no data. So unmodelled calls are APPENDED TO A LOG, and the guard fails the run when that log is not
empty. Adding an `oc` read to the scan therefore breaks this gate loudly, which is the intent.
"""
from __future__ import annotations

import json
import os
import sys


def value_of(args: list[str], flag: str) -> str:
    """The value of `-n ns` / `-l sel`, in the separate-argument form the ws CLI always writes."""
    for i, arg in enumerate(args):
        if arg == flag and i + 1 < len(args):
            return args[i + 1]
        if arg.startswith(flag + "="):
            return arg[len(flag) + 1:]
    return ""


def key_for(args: list[str]) -> str | None:
    if not args:
        return None
    if args[0] == "whoami":
        return "whoami --show-server" if "--show-server" in args else "whoami"
    if args[:2] == ["auth", "can-i"]:
        verb = [a for a in args[2:] if not a.startswith("-")]
        scope = " --all-namespaces" if "--all-namespaces" in args or "-A" in args else ""
        ns = value_of(args, "-n")
        return "can-i:" + " ".join(verb) + scope + (f" -n {ns}" if ns else "")
    if args[0] != "get":
        return None
    kind = args[1] if len(args) > 1 else ""
    if kind == "ns":
        return "ns"
    if kind == "deployments":
        # ws doctor's drift row probes cluster-wide deployment LIST access with a field selector that
        # cannot match: authorization is decided before field selection, so the probe exercises the
        # real permission and returns nothing. A different question from the enumeration below, so it
        # gets its own key rather than sharing "workloads".
        return "deployments-probe"
    if kind == "deployments,statefulsets,daemonsets,cronjobs":
        return "workloads"
    if kind == "crd":
        return f"crd:{args[2]}"
    if kind == "services.serving.knative.dev":
        return "ksvcs"
    if kind == "pods":
        return f"pods:{value_of(args, '-n')}:{value_of(args, '-l')}"
    if kind == "istag":
        name, _, tag = args[2].partition(":")
        return f"istag:{value_of(args, '-n')}:{name}:{tag}"
    if kind == "ksvc":
        return f"ksvclabel:{value_of(args, '-n')}:{args[2]}"
    return None


def main() -> int:
    args = sys.argv[1:]
    with open(os.environ["WS_STUB_CALLS"], encoding="utf-8") as handle:
        calls = json.load(handle)
    key = key_for(args)
    if key is not None and key in calls:
        # An ABSENT object is a MODELLED answer, never an omission. `oc get istag` on a tag that does
        # not exist prints nothing and exits 1 — the scan's `no-tag` branch — and if the stub inferred
        # that from a missing entry, then forgetting to record a tag would silently produce the
        # failure state the fixture is supposed to assert, and a newly added istag read would be
        # answered instead of logged. The fixture has to say so out loud.
        if calls[key] == "@ABSENT":
            return 1
        sys.stdout.write(calls[key])
        return 0
    with open(os.environ["WS_STUB_UNKNOWN"], "a", encoding="utf-8") as handle:
        handle.write(f"oc {' '.join(args)}\n")
    return 1


if __name__ == "__main__":
    sys.exit(main())
