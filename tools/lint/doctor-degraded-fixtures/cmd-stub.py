#!/usr/bin/env python3
"""A recording of `oc` and `curl`, good enough to run `ws doctor` off-cluster.

Installed as BOTH `oc` and `curl` at the front of PATH by doctor-degraded-guard.sh, which decides
which tool it is being called as from argv[0]. Everything `ws doctor` shells out to is one of those
two (plus python3, mktemp, sed, grep — all of which do their real work here), so a recording of the
pair is a recording of the whole report.

WHY THE KEY IS THE WHOLE COMMAND LINE. The sibling recording (tools/lint/rebuild-scan-fixtures)
normalizes argv down to a short key, because the scan it drives asks the same question many ways and
a short key keeps its fixture legible. This one goes the other way on purpose: `ws doctor`'s rows
differ from each other by exactly the flags they pass — the same `application workshop-config` is
read three times for three different fields, and reading it "the wrong way" is precisely the class of
mistake this fixture exists to catch. So the key is the command verbatim, the recording reads as a
transcript, and a changed flag or jsonpath becomes an UNMODELLED CALL rather than being quietly
answered with some other row's data.

AN UNMODELLED CALL IS NOT AN EMPTY ANSWER. Doctor's reads are written `2>/dev/null || true`,
`|| rc=$?` and `>/dev/null 2>&1` — on a real cluster a denied or absent object must never abort the
report — which makes silence indistinguishable from "nothing there". A stub that answered an
unrecorded call with nothing would reproduce that blindness inside the test and let the guard go on
comparing rows produced from no data. So unmodelled calls are APPENDED TO A LOG and the guard fails
the run when that log is not empty. Adding a read to `ws doctor` therefore breaks this gate loudly,
which is the intent: the new read has to be recorded before its row can be trusted.

`@FORBIDDEN` is spelled out in the recording rather than inferred, for the same reason the sibling
fixture spells out `@ABSENT`: the degraded rows branch on the WORD "Forbidden" in stderr, so if a
missing entry produced one by default, forgetting to record a call would silently manufacture the
very state under test.
"""
from __future__ import annotations

import os
import sys

# Written out rather than embedded, exactly as the sibling fixture does: a field that collapses to
# nothing is the shape these recordings exist to make visible, and an invisible tab hides it.
MARKERS = (("<TAB>", "\t"), ("<NL>", "\n"))


def decode(value: str) -> str:
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
    with open(os.environ["WS_STUB_UNKNOWN"], "a", encoding="utf-8") as handle:
        handle.write(" ".join(argv) + "\n")
    return 1


def as_oc(args: list[str]) -> int:
    table = load(os.environ["WS_STUB_CASE"], "oc")
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
    """Only what `ws doctor` asks of curl: a bare reachability probe, and one -o/-w body fetch.

    The URL is the key. Everything else on the command line (-k, -s, -f, --max-time, -u) is about
    HOW the request is made, not WHAT is being asked, and none of it changes the recorded answer.
    Credentials in particular are deliberately not part of the key: the recording must never need to
    carry one.
    """
    table = load(os.environ["WS_STUB_CASE"], "curl")
    url = next((a for a in reversed(args) if a.startswith("http")), "")
    if url not in table:
        return unknown(["curl", *args])
    record = table[url]
    rc = int(record[0])
    out = decode(record[1]) if len(record) > 1 else ""
    body = decode(record[2]) if len(record) > 2 else ""
    target = ""
    for index, arg in enumerate(args):
        if arg == "-o" and index + 1 < len(args):
            target = args[index + 1]
    if target:
        with open(target, "w", encoding="utf-8") as handle:
            handle.write(body)
    elif body:
        sys.stdout.write(body)
    if out:
        sys.stdout.write(out)
    return rc


def main() -> int:
    # `--as <tool>` rather than argv[0]: the PATH shim is a two-line sh script that execs python3, so
    # argv[0] here is this file's own path, not the name the caller typed. Inferring the tool from it
    # would silently answer every call from the `oc` table.
    argv = sys.argv[1:]
    tool = os.path.basename(sys.argv[0])
    if argv[:1] == ["--as"] and len(argv) >= 2:
        tool, argv = argv[1], argv[2:]
    if tool == "oc":
        return as_oc(argv)
    if tool == "curl":
        return as_curl(argv)
    # Never silently: a stub invoked under a name it does not model has answered a question nobody
    # can see, which is the one failure mode this whole file is written against.
    print(f"cmd-stub: invoked as {tool!r}, which it does not model", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
