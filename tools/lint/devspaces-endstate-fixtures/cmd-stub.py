#!/usr/bin/env python3
"""A recording of `oc` and `curl`, good enough to run tools/verify/devspaces-inner-loop.sh off-cluster.

Installed as BOTH `oc` and `curl` at the front of PATH by devspaces-endstate-guard.py, which tells it
which tool it is standing in for with `--as`. Those two are everything the verify script and
tools/verify/_lib.sh shell out to (plus mktemp/grep/sed, which do their real work here), so a
recording of the pair is a recording of the whole run.

WHY A RECORDING AT ALL. The state this gate exists to pin — an attendee who pushed their /ping
endpoint, and one who did not — cannot be constructed on a shared workshop cluster without running
`ws prep`/`ws solve` against a real attendee, and the "pushed" half additionally needs a commit
written into somebody's Gitea fork. Both are mutations of a world other lanes are using. The
UNPUSHED half is observable live and was measured that way (see the guard's header); this recording
is how the PUSHED half, and the not-gradeable half, get exercised at all.

AN UNMODELLED CALL IS NOT AN EMPTY ANSWER. _lib.sh's readers are built to survive a cluster that
cannot be asked — oc_read classifies, oc_read_optional swallows, http_read falls back — so a stub
that answered an unrecorded call with silence would reproduce that tolerance inside the test and let
the guard go on grading output produced from no data. Unmodelled calls are therefore APPENDED TO A
LOG and the guard fails the run when that log is non-empty. Adding a read to the verify script breaks
this gate loudly, on purpose: the new read has to be recorded before its verdict can be trusted.

`@FORBIDDEN` and the body markers are spelled out in the recording rather than inferred, for the same
reason the sibling fixtures spell theirs out: the script branches on the WORD "forbidden" in stderr,
so a missing entry that defaulted to one would silently manufacture the very state under test.
"""
from __future__ import annotations

import os
import sys

# Written out rather than embedded: a field that collapses to nothing is exactly the shape these
# recordings exist to make visible, and an invisible tab or newline hides it.
MARKERS = (("<TAB>", "\t"), ("<NL>", "\n"))

FORBIDDEN = "@FORBIDDEN"


def decode(value: str) -> str:
    if value == FORBIDDEN:
        return ""
    for marker, char in MARKERS:
        value = value.replace(marker, char)
    return value


def load(path: str, kind: str) -> dict[str, list[str]]:
    """`kind`-typed records from a .case file, keyed by their second field."""
    table: dict[str, list[str]] = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            fields = line.split("\t")
            if fields[0] != kind or len(fields) < 3:
                continue
            table[fields[1]] = fields[2:]
    return table


def unknown(argv: list[str]) -> int:
    with open(os.environ["DS_STUB_UNKNOWN"], "a", encoding="utf-8") as handle:
        handle.write(" ".join(argv) + "\n")
    return 1


def as_oc(args: list[str]) -> int:
    table = load(os.environ["DS_STUB_CASE"], "oc")
    key = " ".join(args)
    if key not in table:
        return unknown(["oc", *args])
    record = table[key]
    rc = int(record[0])
    out = decode(record[1]) if len(record) > 1 else ""
    err = decode(record[2]) if len(record) > 2 else ""
    if out:
        sys.stdout.write(out)
    if err:
        sys.stderr.write(err)
    return rc


def as_curl(args: list[str]) -> int:
    """The URL is the key.

    Everything else on the command line (-k, -s, -S, -f, -o, -w, --max-time) is about HOW the request
    is made, not WHAT is being asked, and none of it changes the recorded answer. Two callers in this
    script read the answer two different ways and the split matters:
      * `-w '%{http_code}'` callers read the CODE off stdout            -> field `wout`
      * `-o <file>` callers read the BODY out of that file              -> field `body`
    `-o /dev/null` callers (fork_exists, route_ready_200) get the body written into /dev/null, which
    is what really happens, so nothing has to special-case them.
    """
    table = load(os.environ["DS_STUB_CASE"], "curl")
    url = next((a for a in reversed(args) if a.startswith("http")), "")
    if url not in table:
        return unknown(["curl", *args])
    record = table[url]
    rc = int(record[0])
    wout = decode(record[1]) if len(record) > 1 else ""
    body = decode(record[2]) if len(record) > 2 else ""
    body = resolve_body(body)
    target = ""
    for index, arg in enumerate(args):
        if arg == "-o" and index + 1 < len(args):
            target = args[index + 1]
    if target:
        with open(target, "w", encoding="utf-8") as handle:
            handle.write(body)
    elif body:
        sys.stdout.write(body)
    if wout:
        sys.stdout.write(wout)
    return rc


def resolve_body(body: str) -> str:
    """`@WORLD:<name>` pulls a body the GUARD built, rather than one pasted into the recording.

    The three ClaimResource.java worlds are DERIVED at run time from apps/parasol-claims' real source
    and from the lab's own printed snippet — see the guard's build_worlds(). Pasting them here would
    create a fourth copy of a file that already exists twice and let the fixture drift away from both
    the app the fork is seeded from and the lab the attendee follows, which is the failure this whole
    gate is about.
    """
    if body.startswith("@WORLD:"):
        name = body.split(":", 1)[1]
        path = os.path.join(os.environ["DS_STUB_WORLDS"], name)
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    return body


def main() -> int:
    # `--as <tool>`, not argv[0]: the PATH shim execs python3, so argv[0] here is this file's own
    # path, never the name the caller typed. Inferring the tool from it would answer every call from
    # the `oc` table.
    argv = sys.argv[1:]
    tool = os.path.basename(sys.argv[0])
    if argv[:1] == ["--as"] and len(argv) >= 2:
        tool, argv = argv[1], argv[2:]
    if tool == "oc":
        return as_oc(argv)
    if tool == "curl":
        return as_curl(argv)
    # Never silently: a stub invoked under a name it does not model has answered a question nobody
    # can see, which is the one failure mode this file is written against.
    print(f"cmd-stub: invoked as {tool!r}, which it does not model", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
