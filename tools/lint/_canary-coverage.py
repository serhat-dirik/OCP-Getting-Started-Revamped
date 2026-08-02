#!/usr/bin/env python3
"""Every detector in a Python guard must be provable by blinding it — a guard about guards.

WHY THIS EXISTS (audit of 2026-08-01, commits d75268e and 323522a). Eleven guards were audited by
hand with ONE technique: neuter a single detector, re-run both modes, and require an exit code to
change. It found, in a single night:

  * 15 of 21 detectors blindable in `rebuild-scan-guard.py`. Its `suite()` ran a contract half and
    a behaviour half and counted a mutant caught if EITHER fired, so each half was signing off the
    other's regressions.
  * `hook-env-guard.py`'s `self_test()` re-implemented the whole pipeline inline and never called
    `check_chart()` — the only function the real run uses.
  * `copy-drift-guard.py`'s bytes headline and diff body MASKING EACH OTHER: blinding either left
    `problems` non-empty, so the reported kind never changed and the self-test stayed at 1.
  * `api-key-shape-guard.py`'s `looks_like_key()`, a documented three-layer predicate that NOTHING
    CALLED — `scan_text` had re-implemented it inline. A dead predicate cannot be blinded because
    it was never alive.

Every one of those was mechanically discoverable, and every one had been reviewed by a human who
believed the guard was covered. A hand audit finds them once; this file makes finding them a CI
job, so "N detectors, N proven" is ENFORCED rather than periodically re-established.

WHAT A DETECTOR IS, mechanically (all three kinds are restricted to the guard's REAL-RUN call
graph — the functions reachable from `main()` WITHOUT passing through `self_test()`, because
blinding a self-test assertion can never change an exit code and would report every guard as
hopelessly uncovered):

  pattern:NAME      a module-level `re.Pattern` the real run reads. Blinded to match nothing.
  predicate:NAME    a module-level `-> bool` function the real run reads. Forced to a constant,
                    both directions, because "which constant is the clean one" differs per
                    predicate (`excluded()` is blind at True, `is_workshop_image()` at False) and
                    a predicate that survives BOTH is the dead-code shape above.
  emit:FUNC:HASH    a finding-emission site, replaced by a no-op: `.append`/`.extend` onto an
                    outcome-deciding `[]` local, a `yield`, or a call to a class's one-line
                    recorder method (`self._record(…)` — copy-drift reaches all EIGHT of its
                    finding kinds that way and none through a local). This is the kind that found
                    15 of the 21, and the kind a `_compile`-only sweep misses entirely.

FUNC is `name` or `Class.method`. HASH is `sha1(ast.unparse(statement))[:8]`, not a line number: a
line number rots the moment anything above it moves, and a ledger entry keyed on a rotted id is an
entry that silently stops applying to the thing it was written for.

THE CONTRACT. Baseline is plain 0 / self-test 1. A detector is PROVEN when at least one variant of
its mutation changes at least one of those two exit codes. It is UNPROVEN when every variant leaves
BOTH unchanged: it can stop working and no CI signal will say so.

EXIT CODES (this file follows the same inverted convention as every guard beside it):
  --self-test  MUST exit exactly 1. 0 = this gate is blind. 2 = its own harness is broken.
  plain        0 = every swept detector proven, 1 = an unproven detector or a stale exemption,
               2 = COULD NOT INSPECT. 1 and 2 are deliberately different: "this detector is
               unproven" is a finding about a guard; "I could not run this guard at all" is a
               finding about the sweep, and collapsing them lets a guard that fails to import read
               as a guard with a hole (or worse, get fixed as one).
  unknown arg  2, via argparse — never 1, which CI's self-test assertion accepts as success.

RUNTIME, and why the default mode is not `--all`. Measured 2026-08-01 on this tree: nine of the ten
guards cost under 5s for both baseline modes, and sweeping every detector in all nine takes ~2
minutes wall at -j4. `rebuild-scan-guard.py` alone costs ~75s per detector pair — its --self-test
runs 21 internal mutants, several spawning `bash tools/ws/ws` — across 24 detectors, which is
360-470s at -j8 (two measurements, load-dependent) and ~30 minutes serial. A gate nobody can afford to run gets switched off, so the
default is a BUDGET, not a guard name: a guard is swept when the diff TOUCHED it (unconditionally,
budget ignored) or when its projected cost fits `--budget`. Nothing here hardcodes which guard is
the expensive one; a guard that becomes slow drops out on its own, and one that becomes fast
rejoins on its own. The consequence, stated plainly: an expensive guard's detectors are re-proven
when it or its fixtures change, not on every push.

WHAT THIS GATE DOES NOT COVER, stated so nobody reads its green tick as more than it is:
  * The 16 Bash guards. They have no module-level attribute to patch; `_check-coverage.sh` asserts
    every `check_*` RAN, which is a strictly weaker claim than "its finding could not be silenced".
  * `_scope.py` — a library with no real-run detectors of its own, exercised through its consumers.
  * This file. It is not a `*-guard.py` and sweeping itself would recurse. Its own blinding is
    proven by `--self-test` (see `self_test()`) and by hand on a scratch copy.
"""

import argparse
import ast
import collections
import concurrent.futures
import hashlib
import os
import pathlib
import re
import subprocess
import sys
import time
import types


def _compile(name, pattern, flags=0):
    """re.compile, but a bad pattern exits 2 instead of crashing with 1.

    Same reason as every guard beside this one: a module-level `re.error` raises before main() can
    run, Python exits 1, and 1 is exactly what CI's "--self-test must exit EXACTLY 1" assertion
    reads as "the canary was detected". A regex typo must never report detection as proven.
    """
    try:
        return re.compile(pattern, flags)
    except re.error as exc:
        print(f"::error::_canary-coverage: {name} is not a valid regex ({exc}) — the gate could "
              f"not load. Exiting 2: that is 'the gate is broken', not 'every detector is proven'.",
              file=sys.stderr)
        sys.exit(2)


REPO = pathlib.Path(__file__).resolve().parents[2]
LINT = REPO / "tools/lint"
CANARY = LINT / "_canary-coverage.canary"

# The guard set. `*-guard.py` is the README's naming rule for "this file is a check"; `_`-prefixed
# files are shared libraries by the same convention and are exercised through their consumers.
GUARD_GLOB = "*-guard.py"

# A pattern that can never match anything, for blinding. `(?!x)x` rather than `(?!)` because the
# latter is what credential-redaction-guard already uses as ITS blinding constant, and reusing the
# identical object would make a mutation of that constant indistinguishable from a no-op.
BLIND_PATTERN_SRC = r"(?!x)x"

# Where the real-run call graph starts. Guards use `main`; `_scope.py`-style libraries use `_main`.
ENTRYPOINTS = ("main", "_main")

# The one function whose call graph is NOT the real run. Everything reachable only through it is
# harness code: blinding an assertion inside a self-test cannot change an exit code by definition.
SELF_TEST_FUNC = "self_test"

BASELINE_PLAIN = 0
BASELINE_SELF_TEST = 1

# ── Reasoned exemptions, and dated debt ────────────────────────────────────────────────────────
#
# Two lists, identical mechanics, DIFFERENT claims. Both are swept exactly like everything else —
# neither is a mute button — and both error in two directions, which is what stops them rotting:
#
#   * the key no longer enumerates (the guard was reworded, so the entry applies to nothing), or
#   * the detector turns out to be PROVEN (someone wrote the witness; the entry is now a lie).
#
# That is the shape `_parse-guard-args.sh` uses for `_PGA_EXEMPT`, which errors when an exempt file
# starts using the parser.

# EXEMPT: "this detector CANNOT be witnessed by either mode, and here is why." Permanent, and the
# reason must be structural — isolating it would couple the fixture to live content, blinding it
# makes the guard quieter rather than louder and no safe case can witness that, and so on. Empty
# today: every unwitnessed detector found on 2026-08-01 turned out to be witnessABLE, just
# unwitnessed, so all of them are debt below rather than exemptions here.
EXEMPT: dict[str, str] = {}

# KNOWN_UNPROVEN: "this detector CAN be witnessed and is not — yet." Debt, not permission.
#
# It exists so the gate can be wired GREEN on the day it lands without pretending the tree is
# clean. Read the rule as a ratchet: the list may shrink, never grow. A NEW unproven detector fails
# CI; an entry here that acquires a witness ALSO fails CI, so paying the debt is the only way to
# stop hearing about it and nobody has to remember to prune the list.
#
# Seeded 2026-08-01 by the first run of this gate against the tree at that date. Every entry was
# confirmed by hand with a real on-disk edit as well as by this file's in-process mutation, because
# a harness reporting holes in guards deserves the same "measured two independent ways" bar the
# audit it automates held itself to.
KNOWN_UNPROVEN: dict[str, str] = {}


def _ledgers() -> dict:
    """Both ledgers as one mapping. Keys are disjoint by construction — an entry cannot be both
    "impossible to witness" and "not witnessed yet" — and a key in both is a contradiction that
    would make the two staleness rules fight, so it is rejected up front."""
    both = set(EXEMPT) & set(KNOWN_UNPROVEN)
    if both:
        print(f"::error::_canary-coverage: {sorted(both)} appear in BOTH EXEMPT and "
              f"KNOWN_UNPROVEN. A detector is either unwitnessABLE or merely unwitnessed; it "
              f"cannot be both, and the two ledgers enforce opposite things.", file=sys.stderr)
        sys.exit(2)
    return {**EXEMPT, **KNOWN_UNPROVEN}


class Detector:
    """One blindable thing, plus every mutation variant that counts as blinding it."""

    __slots__ = ("guard", "kind", "name", "func", "stmt_hash", "lineno", "variants")

    def __init__(self, guard, kind, name, func=None, stmt_hash=None, lineno=None, variants=()):
        self.guard = guard
        self.kind = kind
        self.name = name
        self.func = func
        self.stmt_hash = stmt_hash
        self.lineno = lineno
        self.variants = tuple(variants)

    @property
    def ident(self) -> str:
        if self.kind == "emit":
            return f"emit:{self.func}:{self.stmt_hash}"
        return f"{self.kind}:{self.name}"

    @property
    def key(self) -> str:
        return f"{self.guard}::{self.ident}"

    @property
    def where(self) -> str:
        return f"{self.guard}:{self.lineno}" if self.lineno else self.guard


# ── Enumeration ────────────────────────────────────────────────────────────────────────────────

def _module_functions(tree: ast.Module) -> dict:
    """Module-level functions AND class methods, the latter keyed `Class.method`.

    Methods are in because `copy-drift-guard.py` keeps its entire drift comparison inside a
    `Comparison` class — a module-level-only sweep found 3 detectors there and missed the ones that
    matter. A method is reached through `self.`, which a bare-name call graph cannot follow, so a
    method counts as real-run whenever its CLASS NAME is read by real-run code. That over-
    approximates (a class used only by the self-test would drag its methods in), and
    over-approximating is the safe direction: it can only add detectors to the swept set.
    """
    funcs = {}
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            funcs[node.name] = node
        elif isinstance(node, ast.ClassDef):
            for member in node.body:
                if isinstance(member, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    funcs[f"{node.name}.{member.name}"] = member
    return funcs


def _class_of(qualname: str) -> str | None:
    return qualname.split(".", 1)[0] if "." in qualname else None


def _is_self_test_branch(node) -> bool:
    """`if args.self_test:` / `if self_test:` — the harness path, even when it lives inside main().

    Excluding the `self_test()` FUNCTION is not enough: click-to-run, curl-format and
    version-anchor all inline their assertions in `main()` behind this exact condition. An
    assertion in there can never move an exit code by being blinded (the other assertions still
    fire, or none of them do and the mode was already failing), so counting it as a detector
    reports three guards as holed for a structural reason that says nothing about their detection.
    """
    if not isinstance(node, ast.If):
        return False
    for sub in ast.walk(node.test):
        if isinstance(sub, ast.Attribute) and sub.attr == SELF_TEST_FUNC:
            return True
        if isinstance(sub, ast.Name) and sub.id == SELF_TEST_FUNC:
            return True
    return False


def _walk_real(node):
    """ast.walk, but never descending into a self-test branch's body (its `else` still counts)."""
    yield node
    for child in ast.iter_child_nodes(node):
        if _is_self_test_branch(child):
            for orelse in child.orelse:
                yield from _walk_real(orelse)
            continue
        yield from _walk_real(child)


def _names_read(node: ast.AST) -> set:
    """Every bare name loaded anywhere inside `node`, outside its self-test branches.

    Deliberately not a real def-use analysis. Over-approximating which names a function touches
    can only ADD detectors to the swept set; under-approximating drops one silently, and a dropped
    detector is the exact failure this file exists to catch.
    """
    return {sub.id for sub in _walk_real(node)
            if isinstance(sub, ast.Name) and isinstance(sub.ctx, ast.Load)}


def real_run_functions(tree: ast.Module) -> set:
    """Functions reachable from an entrypoint by a path that never enters `self_test`.

    Reaching a class name pulls in all of its methods, because `self.compare()` is invisible to a
    bare-name call graph and dropping a method silently is the failure this file exists to catch.
    """
    funcs = _module_functions(tree)
    refs = {name: _names_read(node) for name, node in funcs.items()}
    by_class: dict = {}
    for name in funcs:
        cls = _class_of(name)
        if cls:
            by_class.setdefault(cls, []).append(name)

    seen: set = set()
    stack = [e for e in ENTRYPOINTS if e in funcs]
    while stack:
        fn = stack.pop()
        if fn in seen or fn == SELF_TEST_FUNC or fn not in funcs:
            continue
        seen.add(fn)
        stack.extend(refs[fn])
        for name in refs[fn]:
            stack.extend(by_class.get(name, ()))
    return seen


def _decides_an_outcome(func_node: ast.AST, name: str) -> bool:
    """Does this local list decide what the function reports, or is it just being built?

    The distinction is not pedantry. `copy-drift`'s `_fmt_path()` builds an `out` list of path
    fragments and joins it into a string; blinding one of its three branches changes a message's
    WORDING and can never move an exit code — reporting it as an unproven detector is a false
    accusation against a guard that is fine. `collect_files()`'s `files.append(…)` decides what
    gets scanned at all, which the audit named as failure mode three ("the code deciding what to
    scan can silently narrow the input set while the guard still prints clean"), and IS a detector.

    Two shapes qualify, both cheap and both structural:
      * the name is returned directly, or as an element of a returned tuple (`return findings, n`);
      * the name — or `len(name)` — appears in a branch test (`if problems:`), which is how
        maas-model's `problems, checked = [], 0` decides between rc 1 and rc 0 without ever
        returning the list.
    A name reached only through a call (`return "".join(out)`) qualifies for neither.
    """
    for st in _walk_real(func_node):
        if isinstance(st, ast.Return) and st.value is not None:
            candidates = st.value.elts if isinstance(st.value, ast.Tuple) else [st.value]
            if any(isinstance(c, ast.Name) and c.id == name for c in candidates):
                return True
        elif isinstance(st, (ast.If, ast.While, ast.IfExp)):
            for sub in ast.walk(st.test):
                if isinstance(sub, ast.Name) and sub.id == name:
                    return True
    return False


def _class_recorders(class_node: ast.ClassDef):
    """(self-attributes that are findings lists, one-line recorder methods that append to them).

    `copy-drift-guard.py` reaches NONE of its eight finding kinds through a local list: every one
    is a `self._record(kind, path, detail)` call, and `_record` is a one-line method appending to
    `self.findings`, which `__init__` sets to `[]`. A local-list-only rule enumerated four
    incidental detectors there and missed all eight of the kinds the audit had just spent a night
    fixing — a green tick about nothing. A recorder method is recognised structurally (its whole
    body is one append onto a `[]`-initialised self attribute), never by name, so `_record`,
    `_note` and `add_finding` are all found and a method that merely LOOKS like one is not.
    """
    attrs: set = set()
    for member in class_node.body:
        if not isinstance(member, ast.FunctionDef) or member.name != "__init__":
            continue
        for st in ast.walk(member):
            value = st.value if isinstance(st, (ast.Assign, ast.AnnAssign)) else None
            if not isinstance(value, ast.List) or value.elts:
                continue
            targets = st.targets if isinstance(st, ast.Assign) else [st.target]
            for target in targets:
                if isinstance(target, ast.Attribute) and isinstance(target.value, ast.Name) \
                        and target.value.id == "self":
                    attrs.add(target.attr)

    recorders: set = set()
    for member in class_node.body:
        if not isinstance(member, ast.FunctionDef):
            continue
        body = [st for st in member.body if not (isinstance(st, ast.Expr)
                                                 and isinstance(st.value, ast.Constant))]
        if len(body) != 1 or not isinstance(body[0], ast.Expr) \
                or not isinstance(body[0].value, ast.Call):
            continue
        call = body[0].value
        if isinstance(call.func, ast.Attribute) and call.func.attr in ("append", "extend") \
                and isinstance(call.func.value, ast.Attribute) \
                and isinstance(call.func.value.value, ast.Name) \
                and call.func.value.value.id == "self" \
                and call.func.value.attr in attrs:
            recorders.add(member.name)
    return attrs, recorders


def _emission_sites(func_node: ast.AST, self_lists=(), recorders=()):
    """`.append`/`.extend` onto an outcome-deciding `[]` local, and every `yield`, in source order.

    Plus, for a method: `self.<findings-list>.append(…)` and every call to a recorder method of
    its own class. Those need no outcome test — a `[]` instance attribute reached through a
    dedicated recorder IS the findings container, by construction.

    The `[]`-initialised requirement separates a findings accumulator from an incidental
    `list.append` on something handed in from outside. Tuple unpacking counts: maas-model's
    `problems, checked = [], 0` is exactly the shape, and requiring a plain `x = []` missed it.
    Every `yield` counts unconditionally — a generator IS the emission, and `find_offenders()` is
    the shape four guards here use.
    """
    local_lists: set = set()
    for st in _walk_real(func_node):
        if isinstance(st, ast.AnnAssign) and isinstance(st.target, ast.Name) \
                and isinstance(st.value, ast.List) and not st.value.elts:
            local_lists.add(st.target.id)
        elif isinstance(st, ast.Assign):
            for target in st.targets:
                if isinstance(target, ast.Name) and isinstance(st.value, ast.List) \
                        and not st.value.elts:
                    local_lists.add(target.id)
                elif isinstance(target, ast.Tuple) and isinstance(st.value, ast.Tuple):
                    for elt, val in zip(target.elts, st.value.elts):
                        if isinstance(elt, ast.Name) and isinstance(val, ast.List) and not val.elts:
                            local_lists.add(elt.id)
    local_lists = {n for n in local_lists if _decides_an_outcome(func_node, n)}

    sites = []
    for st in _walk_real(func_node):
        if not isinstance(st, ast.Expr):
            continue
        if isinstance(st.value, ast.Call):
            call = st.value
            func = call.func
            if isinstance(func, ast.Attribute) and func.attr in ("append", "extend") \
                    and isinstance(func.value, ast.Name) and func.value.id in local_lists:
                sites.append(st)
            elif isinstance(func, ast.Attribute) and isinstance(func.value, ast.Name) \
                    and func.value.id == "self" and func.attr in recorders:
                sites.append(st)
            elif isinstance(func, ast.Attribute) and func.attr in ("append", "extend") \
                    and isinstance(func.value, ast.Attribute) \
                    and isinstance(func.value.value, ast.Name) \
                    and func.value.value.id == "self" and func.value.attr in self_lists:
                sites.append(st)
        elif isinstance(st.value, ast.Yield):
            sites.append(st)
    sites.sort(key=lambda s: (s.lineno, s.col_offset))
    return sites


def _returns_bool(node) -> bool:
    ann = getattr(node, "returns", None)
    return isinstance(ann, ast.Name) and ann.id == "bool"


def enumerate_detectors(path: pathlib.Path) -> list:
    """Every blindable detector in one guard, from its SOURCE — no import, no execution.

    Static on purpose: enumeration must work for a guard whose import crashes, because "it does not
    import" has to be reportable as could-not-inspect rather than as zero detectors. Zero detectors
    and a broken guard look identical from a `dir(module)` sweep.
    """
    guard = path.name
    source = path.read_text(encoding="utf-8")
    tree = ast.parse(source, filename=str(path))
    funcs = _module_functions(tree)
    real = real_run_functions(tree)

    read_by_real: set = set()
    for fn in real:
        read_by_real |= _names_read(funcs[fn])

    detectors = []

    # 1. Module-level compiled patterns. Assigned from a `_compile(...)` or `re.compile(...)` call
    #    at module level — the shape every guard here uses.
    for node in tree.body:
        targets = []
        if isinstance(node, ast.Assign):
            targets = [t.id for t in node.targets if isinstance(t, ast.Name)]
            value = node.value
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            targets = [node.target.id]
            value = node.value
        else:
            continue
        if not isinstance(value, ast.Call):
            continue
        fname = value.func.id if isinstance(value.func, ast.Name) else (
            value.func.attr if isinstance(value.func, ast.Attribute) else None)
        if fname not in ("_compile", "compile"):
            continue
        for name in targets:
            if name in read_by_real:
                detectors.append(Detector(guard, "pattern", name, lineno=node.lineno,
                                          variants=("blind",)))

    # 2. Module-level `-> bool` predicates the real run reads. Module-level only: a method is
    #    patched through its class, which `setattr(module, "Class.method", …)` cannot do, and a
    #    mutation that silently fails to apply is worse than one that is never attempted.
    for name, node in funcs.items():
        if "." not in name and name in read_by_real and _returns_bool(node):
            detectors.append(Detector(guard, "predicate", name, lineno=node.lineno,
                                      variants=("false", "true")))

    # 3. Finding-emission sites inside real-run functions.
    for fn in sorted(real):
        for sid, st in sites_for(tree, fn):
            detectors.append(Detector(guard, "emit", None, func=fn, stmt_hash=sid,
                                      lineno=st.lineno, variants=("noop",)))

    detectors.sort(key=lambda d: (d.kind, d.lineno or 0, d.ident))
    return detectors


# ── Mutation ───────────────────────────────────────────────────────────────────────────────────

MUTATION_DID_NOT_LAND = 125  # not a guard exit code; see probe() — never counted as "proven"


def _site_id(stmt, seen: dict) -> str:
    """`<sha8>` of the statement text, plus `-N` when the same text repeats in one function.

    A line number would be simpler and rots on every edit above it. Hashing the text is stable
    under moves and changes exactly when the statement changes — which is when a ledger entry
    about it should be re-justified anyway.
    """
    digest = hashlib.sha1(ast.unparse(stmt).encode("utf-8")).hexdigest()[:8]
    seen[digest] = seen.get(digest, 0) + 1
    return digest if seen[digest] == 1 else f"{digest}-{seen[digest]}"


def sites_for(tree: ast.Module, qualname: str) -> list:
    """(site_id, statement) for one function or `Class.method`, in enumeration order.

    THE single source of truth for both halves. The enumerator names a site with it and the mutator
    finds that site with it, from the same parse, so a rename or a reorder cannot make the two
    disagree about which statement an id refers to — the way a line-number id silently would. If
    you ever need one of them to compute sites differently from the other, the answer is no.
    """
    func_node = _module_functions(tree).get(qualname)
    if func_node is None:
        return []
    self_lists: set = set()
    recorders: set = set()
    cls = _class_of(qualname)
    if cls:
        for node in tree.body:
            if isinstance(node, ast.ClassDef) and node.name == cls:
                self_lists, recorders = _class_recorders(node)
    seen: dict = {}
    return [(_site_id(stmt, seen), stmt)
            for stmt in _emission_sites(func_node, self_lists, recorders)]


class _EmitNeuterer(ast.NodeTransformer):
    """Replace ONE emission statement (matched by object identity) with a no-op.

    A bare `pass` is wrong for a sole `yield`: the function stops being a generator, its callers
    crash, the run exits 2, and the detector would report PROVEN on the strength of a traceback
    rather than of detection. `if False: yield None` emits nothing and keeps it a generator.
    """

    def __init__(self, target):
        self.target = target
        self.hits = 0

    def visit_Expr(self, node):  # noqa: N802 — ast.NodeTransformer's required name
        if node is not self.target:
            return node
        self.hits += 1
        if isinstance(node.value, ast.Yield):
            return ast.parse("if False:\n    yield None").body[0]
        return ast.parse("pass").body[0]


def _load_module(path: pathlib.Path, tree: ast.Module):
    """Exec a (possibly mutated) tree as a module, with __name__ != '__main__'.

    Not `__main__`, so the guard's own `if __name__ == "__main__"` dispatch does not fire and we
    get to call `main(argv)` ourselves with the argv we want.
    """
    code = compile(ast.fix_missing_locations(tree), str(path), "exec")
    mod = types.ModuleType("guard_under_mutation")
    mod.__file__ = str(path)
    sys.modules[mod.__name__] = mod
    exec(code, mod.__dict__)  # noqa: S102 — executing the guard is the entire point
    return mod


def run_mutant(path: pathlib.Path, ident: str, variant: str, mode: str) -> int:
    """Apply one mutation and run one mode IN THIS PROCESS. Returns the guard's exit code.

    Runs in a throwaway subprocess (see `_spawn`), which is what makes in-process patching safe:
    the mutated module never outlives the run, and a guard that calls `sys.exit` or leaves global
    state behind cannot contaminate the next mutant.
    """
    source = path.read_text(encoding="utf-8")
    tree = ast.parse(source, filename=str(path))

    kind = ident.split(":", 1)[0] if ident else ""
    if kind == "emit":
        _, qualname, site = ident.split(":", 2)
        target = next((st for sid, st in sites_for(tree, qualname) if sid == site), None)
        if target is None:
            print(f"::error::_canary-coverage: emission site {ident} is not in {path.name}; a "
                  f"mutation that lands nowhere proves nothing.", file=sys.stderr)
            return MUTATION_DID_NOT_LAND
        neuterer = _EmitNeuterer(target)
        tree = neuterer.visit(tree)
        if neuterer.hits != 1:
            print(f"::error::_canary-coverage: emission site {ident} matched {neuterer.hits} "
                  f"statements in {path.name}; a mutation that lands twice proves nothing.",
                  file=sys.stderr)
            return MUTATION_DID_NOT_LAND

    sys.path.insert(0, str(path.parent))
    try:
        mod = _load_module(path, tree)
    except SystemExit as exc:
        return int(exc.code or 0)
    except BaseException:  # noqa: BLE001 — a guard that cannot import is rc 2, per the convention
        return 2

    if kind == "pattern":
        name = ident.split(":", 1)[1]
        if not isinstance(getattr(mod, name, None), re.Pattern):
            print(f"::error::_canary-coverage: {path.name} has no module-level pattern {name} at "
                  f"run time — the enumerator and the module disagree.", file=sys.stderr)
            return MUTATION_DID_NOT_LAND
        setattr(mod, name, re.compile(BLIND_PATTERN_SRC))
    elif kind == "predicate":
        name = ident.split(":", 1)[1]
        if not callable(getattr(mod, name, None)):
            print(f"::error::_canary-coverage: {path.name} has no module-level callable {name} at "
                  f"run time — the enumerator and the module disagree.", file=sys.stderr)
            return MUTATION_DID_NOT_LAND
        constant = variant == "true"
        setattr(mod, name, lambda *a, **kw: constant)

    argv = ["--self-test"] if mode == "self-test" else []
    try:
        rc = mod.main(argv)
    except SystemExit as exc:
        rc = exc.code
    except BaseException:  # noqa: BLE001 — matches every guard's own _crash_exit_2 remap
        return 2
    return int(rc or 0)


def _spawn(path: pathlib.Path, ident: str, variant: str, mode: str, timeout: int) -> int:
    """One mutant, one fresh interpreter. Re-execs THIS file so there is only one file to ship."""
    argv = [sys.executable, str(pathlib.Path(__file__).resolve()), "--_mutant",
            str(path), ident or "-", variant, mode]
    try:
        proc = subprocess.run(argv, cwd=str(REPO), stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        return 124
    return proc.returncode


# ── Sweep ──────────────────────────────────────────────────────────────────────────────────────

class GuardReport:
    __slots__ = ("guard", "detectors", "proven", "unproven", "baseline", "cost",
                 "skipped", "error", "witnesses")

    def __init__(self, guard):
        self.guard = guard
        self.detectors = []
        self.proven = []
        self.unproven = []
        self.baseline = None
        self.cost = 0.0
        self.skipped = None
        self.error = None
        self.witnesses = {}


def measure_baseline(path: pathlib.Path, timeout: int):
    """(plain_rc, self_test_rc, seconds). Run through the SAME exec harness the mutants use.

    Through the same harness on purpose. The hand audit's first harness asserted rc 2 for every
    crash injection while two guards were ALREADY at 2 in the sandbox (their canary sidecars had
    not been copied), so every injection for those two proved nothing. A control that does not
    reproduce 0/1 means no mutation result from that guard can be trusted.
    """
    start = time.monotonic()
    plain = _spawn(path, "", "-", "plain", timeout)
    selft = _spawn(path, "", "-", "self-test", timeout)
    return plain, selft, time.monotonic() - start


def sweep_guard(path: pathlib.Path, detectors: list, timeout: int, jobs: int) -> GuardReport:
    report = GuardReport(path.name)
    report.detectors = detectors

    def probe(det):
        """(detector, witness, failure). Proven when ANY variant moves EITHER mode off baseline.

        The cheaper mode runs first only in the sense that `plain` usually is; the point of the
        ordering is that a detector witnessed by the real tree never pays for the self-test.

        125 and 124 are NOT guard exit codes. A mutation that failed to land, or a mutant that ran
        out of wall clock, must never be read as "the exit code changed, therefore proven" — that
        is a traceback signing off a detector, which is the shape the audit's own first harness
        shipped with. They surface as could-not-inspect (rc 2), never as coverage.
        """
        for variant in det.variants:
            for mode, baseline, label in (("plain", BASELINE_PLAIN, "plain run"),
                                          ("self-test", BASELINE_SELF_TEST, "--self-test")):
                rc = _spawn(path, det.ident, variant, mode, timeout)
                if rc == MUTATION_DID_NOT_LAND:
                    return det, None, f"{det.ident}: the mutation did not land ({mode})"
                if rc == 124:
                    return det, None, (f"{det.ident}: mutant timed out after {timeout}s ({mode}) "
                                       f"— raise --timeout rather than trusting this result")
                if rc != baseline:
                    return det, f"{label} moved {baseline} -> {rc} ({variant})", None
        return det, None, None

    start = time.monotonic()
    failures = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        for det, witness, failure in pool.map(probe, detectors):
            if failure:
                failures.append(failure)
            elif witness:
                report.proven.append(det)
                report.witnesses[det.key] = witness
            else:
                report.unproven.append(det)
    report.cost = time.monotonic() - start
    if failures:
        report.error = "; ".join(failures[:3]) + ("" if len(failures) <= 3 else
                                                  f" (+{len(failures) - 3} more)")
    return report


def changed_guards(base: str) -> set:
    """Guard basenames touched by the diff, plus everything if a shared input moved.

    A guard's fixtures are part of its detection: editing `hook-env-guard.canary/` changes what the
    self-test can witness without touching the guard. Editing `_scope.py` or this file changes what
    EVERY guard can witness, so either one widens the sweep to all of them.
    """
    out = subprocess.run(["git", "diff", "--name-only", f"{base}...HEAD"], cwd=str(REPO),
                         capture_output=True, text=True, check=False)
    if out.returncode != 0:
        out = subprocess.run(["git", "diff", "--name-only", base, "HEAD"], cwd=str(REPO),
                             capture_output=True, text=True, check=False)
    if out.returncode != 0:
        raise RuntimeError(f"cannot diff against {base!r}: {out.stderr.strip()}")

    files = [f for f in out.stdout.splitlines() if f.strip()]
    names = set()
    for rel in files:
        if rel in ("tools/lint/_scope.py", "tools/lint/_canary-coverage.py"):
            return {"*"}
        parts = pathlib.PurePosixPath(rel).parts
        if len(parts) < 3 or parts[:2] != ("tools", "lint"):
            continue
        stem = parts[2]
        if stem.endswith("-guard.py"):
            names.add(stem)
        else:
            # `<name>-guard.canary.adoc`, `<name>-guard.canary/…`, `rebuild-scan-fixtures/…`
            base_stem = stem.split(".", 1)[0]
            if base_stem.endswith("-guard"):
                names.add(base_stem + ".py")
            elif base_stem.endswith("-fixtures"):
                names.add(base_stem[: -len("-fixtures")] + "-guard.py")
    return names


def render(reports: list, budget: float, jobs: int) -> None:
    print(f"_canary-coverage: {len(reports)} guard(s), -j{jobs}, budget {budget:.0f}s per guard.")
    print(f"{'guard':40s} {'proven/total':>13s}  {'baseline':>9s}  note")
    for rep in sorted(reports, key=lambda r: r.guard):
        total = len(rep.detectors)
        if rep.error:
            note = f"COULD NOT INSPECT — {rep.error}"
            score = "-"
        elif rep.skipped:
            note = rep.skipped
            score = f"0/{total}"
        else:
            score = f"{len(rep.proven)}/{total}"
            note = f"swept in {rep.cost:.1f}s"
            if rep.unproven:
                note = f"{len(rep.unproven)} UNPROVEN — {note}"
        base = "-" if rep.baseline is None else f"{rep.baseline[0]}/{rep.baseline[1]}"
        print(f"{rep.guard:40s} {score:>13s}  {base:>9s}  {note}")


# ── The gate ───────────────────────────────────────────────────────────────────────────────────

def collect(root: pathlib.Path) -> list:
    return sorted(root.glob(GUARD_GLOB))


def run_gate(guard_paths, changed, budget, jobs, timeout, quiet=False):
    """(rc, reports). rc 0 all swept detectors proven, 1 a hole or a stale exemption, 2 no evidence."""
    if not guard_paths:
        print("::error::_canary-coverage: selected ZERO guards. The repo ships Python guards, so "
              "an empty selection is a broken sweep, not a clean one.", file=sys.stderr)
        return 2, []

    enumerated, reports, hard = {}, [], []
    for path in guard_paths:
        rep = GuardReport(path.name)
        try:
            rep.detectors = enumerate_detectors(path)
        except SyntaxError as exc:
            rep.error = f"does not parse ({exc})"
            hard.append(rep)
            reports.append(rep)
            continue
        enumerated[path.name] = {d.key for d in rep.detectors}
        reports.append(rep)

    total_detectors = sum(len(r.detectors) for r in reports)
    if total_detectors == 0:
        print("::error::_canary-coverage: enumerated ZERO detectors across "
              f"{len(guard_paths)} guard(s). Every guard here compiles patterns and appends "
              "findings, so zero means the ENUMERATOR broke — not that the guards are simple.",
              file=sys.stderr)
        return 2, reports

    # Stale entries, part 1: a key naming a detector that no longer exists. Only checked for guards
    # that were actually enumerated this run, so a `--guard` run does not report the other nine
    # guards' entries as stale.
    known = {k for keys in enumerated.values() for k in keys}
    selected = {p.name for p in guard_paths}
    stale = sorted(k for k in _ledgers()
                   if k.split("::", 1)[0] in selected and k not in known)

    sweep_all = changed == {"*"}
    for rep, path in zip(reports, guard_paths):
        if rep.error:
            continue
        touched = sweep_all or rep.guard in changed
        plain, selft, seconds = measure_baseline(path, timeout)
        rep.baseline = (plain, selft)
        if (plain, selft) != (BASELINE_PLAIN, BASELINE_SELF_TEST):
            rep.error = (f"unmutated control ran {plain}/{selft}, not "
                         f"{BASELINE_PLAIN}/{BASELINE_SELF_TEST} — no mutation result from this "
                         f"guard can be trusted")
            hard.append(rep)
            continue
        projected = seconds * len(rep.detectors)
        if not touched and projected > budget:
            rep.skipped = (f"skipped (untouched; {len(rep.detectors)} detectors x {seconds:.1f}s "
                           f"= ~{projected:.0f}s > budget {budget:.0f}s) — run --all to sweep it")
            continue
        done = sweep_guard(path, rep.detectors, timeout, jobs)
        rep.proven, rep.unproven = done.proven, done.unproven
        rep.cost, rep.witnesses = done.cost, done.witnesses
        if done.error:
            # A mutation that did not land, or a mutant that timed out. Carried up as a HARD
            # failure rather than dropped: the first draft of this assignment copied four fields
            # and silently discarded `error`, which would have turned "the gate could not test
            # this detector" into "this detector is fine" — the precise substitution this file
            # exists to make impossible.
            rep.error = done.error
            hard.append(rep)

    if not quiet:
        render(reports, budget, jobs)

    if hard:
        if not quiet:
            for rep in hard:
                print(f"::error::_canary-coverage: {rep.guard}: {rep.error}", file=sys.stderr)
            print("::error::_canary-coverage: exiting 2 — 'could not run this guard' is NOT the "
                  "same finding as 'this detector is unproven', and must not share its exit code.",
                  file=sys.stderr)
        return 2, reports

    problems, debt = [], 0
    for rep in reports:
        for det in rep.unproven:
            if det.key in EXEMPT:
                continue
            if det.key in KNOWN_UNPROVEN:
                debt += 1
                continue
            problems.append(
                f"{det.where}  {det.ident}: blinding it left BOTH modes on their baseline "
                f"({BASELINE_PLAIN} plain, {BASELINE_SELF_TEST} --self-test). This detector can "
                f"stop working with no CI signal. Give it a witness: a canary case only it can "
                f"catch, or a real-tree case only it can keep silent.")
        # Stale entries, part 2: an entry that is now provable is a lie about the guard.
        for det in rep.proven:
            for label, ledger in (("EXEMPT", EXEMPT), ("KNOWN_UNPROVEN", KNOWN_UNPROVEN)):
                if det.key in ledger:
                    problems.append(
                        f"{det.where}  {det.ident} is in {label} ({ledger[det.key]}) but is now "
                        f"PROVEN ({rep.witnesses[det.key]}). Delete the entry — a ledger line that "
                        f"no longer describes reality is how a mute button outlives its reason.")
    for key in stale:
        problems.append(f"the ledger carries {key!r}, which no longer enumerates. Either the "
                        f"detector was reworded (re-key it) or it is gone (delete the entry).")

    if problems:
        if not quiet:
            print(f"\n_canary-coverage: {len(problems)} unproven detector(s)/stale exemption(s).",
                  file=sys.stderr)
            for line in problems:
                print(f"  ❌ {line}", file=sys.stderr)
            print("\n   Fix hint: reproduce one locally with\n"
                  "     python3 tools/lint/_canary-coverage.py --guard <name>-guard.py --all",
                  file=sys.stderr)
        return 1, reports

    swept = [r for r in reports if not r.skipped and not r.error]
    if not quiet:
        print(f"\n✅ _canary-coverage: {sum(len(r.proven) for r in swept)} detector(s) proven "
              f"across {len(swept)} swept guard(s); every blinding moved an exit code.")
        if debt:
            print(f"   {debt} detector(s) carried as KNOWN_UNPROVEN debt — see the ledger in "
                  f"tools/lint/_canary-coverage.py. The list may shrink, never grow.")
    return 0, reports


# ── Self-test ──────────────────────────────────────────────────────────────────────────────────

def self_test() -> int:
    """Prove the gate itself detects an unproven detector, on fixtures with a known answer.

    Exit 1 = the gate correctly classified every fixture detector and correctly rejected a stale
    exemption. Exit 2 = the fixtures are missing or the harness cannot tell the two apart, which is
    the meta-guard's version of "blind" and must never read as a pass.

    THE FIXTURES ARE THE POINT. `proven-guard.py` has a pattern and an emission site its own canary
    witnesses; `unproven-guard.py` has a pattern its self-test re-implements around — the
    hook-env-guard shape — so blinding it changes nothing. A gate whose comparison logic is blinded
    (say, "changed" hardcoded True) reports the second fixture as proven and this fails.
    """
    problems = []
    if not CANARY.is_dir():
        print(f"❌ SELF-TEST FAILED: fixture directory {CANARY} is missing — there is nothing to "
              "prove the gate with.", file=sys.stderr)
        return 2

    proven_fixture = CANARY / "proven-guard.py"
    unproven_fixture = CANARY / "unproven-guard.py"
    recorder_fixture = CANARY / "recorder-guard.py"
    fixtures = (proven_fixture, unproven_fixture, recorder_fixture)
    for path in fixtures:
        if not path.is_file():
            print(f"❌ SELF-TEST FAILED: fixture {path} is missing.", file=sys.stderr)
            return 2

    # 1. Enumeration must find the exact detectors the fixtures declare, BY NAME. "Some detectors
    #    were found" is the assertion that let 15 of 21 through in the first place. Two of the
    #    recorder fixture's sites are the only witness the class walk has: drop class methods from
    #    _module_functions, or blind _class_recorders, and this set goes empty.
    # COUNTS, not a set of names. `Review.read` records two kinds through the same recorder, and a
    # set would be satisfied by one of them — the "a total is satisfied by one detector firing
    # twice" failure the fixtures themselves warn about, reproduced in the assertion about them.
    expected = {
        "proven-guard.py": {"pattern:FLAW_RE": 1, "emit:find_offenders:*": 1,
                            "predicate:is_exempt": 1},
        "unproven-guard.py": {"pattern:UNUSED_RE": 1, "emit:find_offenders:*": 1},
        # Two call sites plus the recorder's own append. The third is redundant with the other two
        # — blinding it silences both kinds — but it is a real emission site and it is proven, and
        # dropping a detector because it looks redundant is how a set stops describing the code.
        "recorder-guard.py": {"emit:Review.read:*": 2, "emit:Review._record:*": 1},
    }
    enumerated = {}
    for path in fixtures:
        dets = enumerate_detectors(path)
        enumerated[path.name] = dets
        got = collections.Counter(re.sub(r"^(emit:[^:]+):.*$", r"\1:*", d.ident) for d in dets)
        want = expected[path.name]
        if got != collections.Counter(want):
            problems.append(f"enumeration of {path.name} produced {dict(sorted(got.items()))}, "
                            f"expected {dict(sorted(want.items()))} — the enumerator, not the "
                            f"fixture, changed.")

    if problems:
        for line in problems:
            print(f"❌ SELF-TEST FAILED: {line}", file=sys.stderr)
        return 2

    # 2. The classification itself, which is the whole gate.
    timeout = 120
    for path, want_unproven in ((proven_fixture, set()),
                                (recorder_fixture, set()),
                                (unproven_fixture, {"pattern:UNUSED_RE"})):
        plain, selft, _ = measure_baseline(path, timeout)
        if (plain, selft) != (BASELINE_PLAIN, BASELINE_SELF_TEST):
            print(f"❌ SELF-TEST FAILED: fixture {path.name} controls ran {plain}/{selft}, not "
                  f"{BASELINE_PLAIN}/{BASELINE_SELF_TEST}. The fixture is broken, so its "
                  f"classification would prove nothing.", file=sys.stderr)
            return 2
        rep = sweep_guard(path, enumerated[path.name], timeout, 4)
        got_unproven = {d.ident for d in rep.unproven}
        if got_unproven != want_unproven:
            problems.append(f"{path.name}: classified {sorted(got_unproven) or '[]'} as unproven, "
                            f"expected {sorted(want_unproven) or '[]'}.")

    # 3. The ledgers, EXERCISED rather than asserted about — and each with its own control.
    #
    # The control matters more than the assertion. This block's first draft added a stale key to
    # the ledger, ran the gate over `unproven-guard.py`, and asserted rc 1 — which that fixture
    # returns anyway, because UNUSED_RE is unproven. The assertion could not fail, which is the
    # exact defect this whole file exists to find, reproduced inside the file itself. Every case
    # below therefore runs the SAME gate over the SAME fixture with the ledger empty first, and
    # only trusts the mutated result if the control came back where it should.
    def gate(fixture, expected_control, entries):
        control, _ = run_gate([fixture], {"*"}, 1e9, 4, timeout, quiet=True)
        if control != expected_control:
            problems.append(f"{fixture.name}: control run gave rc={control}, expected "
                            f"{expected_control} — the case below would prove nothing.")
            return None
        for ledger, key, why in entries:
            ledger[key] = why
        try:
            return run_gate([fixture], {"*"}, 1e9, 4, timeout, quiet=True)[0]
        finally:
            for ledger, key, _why in entries:
                ledger.pop(key, None)

    cases = [
        ("a stale EXEMPT key (names nothing)", proven_fixture, 0, 1,
         [(EXEMPT, "proven-guard.py::pattern:NO_SUCH_PATTERN", "fixture: stale")]),
        ("a stale KNOWN_UNPROVEN key (names nothing)", proven_fixture, 0, 1,
         [(KNOWN_UNPROVEN, "proven-guard.py::pattern:NO_SUCH_PATTERN", "fixture: stale")]),
        ("an EXEMPT key that is now PROVEN", proven_fixture, 0, 1,
         [(EXEMPT, "proven-guard.py::pattern:FLAW_RE", "fixture: claims the unwitnessable")]),
        ("a KNOWN_UNPROVEN key that is now PROVEN", proven_fixture, 0, 1,
         [(KNOWN_UNPROVEN, "proven-guard.py::pattern:FLAW_RE", "fixture: debt already paid")]),
        ("KNOWN_UNPROVEN carrying a real hole turns rc 1 into rc 0", unproven_fixture, 1, 0,
         [(KNOWN_UNPROVEN, "unproven-guard.py::pattern:UNUSED_RE", "fixture: the debt itself")]),
    ]
    for label, fixture, control_rc, want_rc, entries in cases:
        got = gate(fixture, control_rc, entries)
        if got is not None and got != want_rc:
            problems.append(f"{label}: rc={got}, expected {want_rc}. A ledger that can rot "
                            f"silently is the same mute button it replaced.")

    if problems:
        print("❌ SELF-TEST FAILED — the gate cannot tell a proven detector from an unproven one:",
              file=sys.stderr)
        for line in problems:
            print(f"   {line}", file=sys.stderr)
        return 2

    print("✅ self-test: proven-guard's 3 detectors classified proven, unproven-guard's UNUSED_RE "
          f"classified UNPROVEN, and {len(cases)} ledger cases held (both rot directions of both "
          "ledgers, each against its own control). Exiting 1 — the gate's detection is proven.")
    return 1


# ── Entry point ────────────────────────────────────────────────────────────────────────────────

def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)

    # The mutant runner. A private flag, parsed before argparse so it cannot collide with the
    # user-facing surface, and never documented in --help: it is this file re-entering itself.
    if argv[:1] == ["--_mutant"]:
        if len(argv) != 5:
            return 2
        _, path, ident, variant, mode = argv
        return run_mutant(pathlib.Path(path), "" if ident == "-" else ident, variant, mode)

    ap = argparse.ArgumentParser(
        description="Blind one detector at a time; require an exit code to change.",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--self-test", action="store_true",
                    help="classify fixture guards with known answers instead of the real tree; "
                         "exits 1 when every classification is right, which is the PASS for this "
                         "mode")
    ap.add_argument("--all", action="store_true",
                    help="sweep every guard, ignoring --budget (the local/nightly mode)")
    ap.add_argument("--guard", action="append", default=[], metavar="NAME",
                    help="sweep only this guard (repeatable); implies --all for it")
    ap.add_argument("--changed-from", metavar="REF",
                    help="treat guards touched since REF as changed; they are swept whatever "
                         "--budget says")
    ap.add_argument("--budget", type=float, default=240.0, metavar="SECONDS",
                    help="per-guard projected-cost ceiling for UNTOUCHED guards (default: 240)")
    ap.add_argument("-j", "--jobs", type=int, default=min(4, os.cpu_count() or 1),
                    help="parallel mutant runs (default: min(4, cpus))")
    ap.add_argument("--timeout", type=int, default=900, metavar="SECONDS",
                    help="per-mutant wall clock (default: 900)")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()

    guards = collect(LINT)
    if args.guard:
        wanted = set(args.guard)
        missing = wanted - {p.name for p in guards}
        if missing:
            print(f"::error::_canary-coverage: no such guard(s): {sorted(missing)}",
                  file=sys.stderr)
            return 2
        guards = [p for p in guards if p.name in wanted]

    if args.all or args.guard:
        changed = {"*"}
    elif args.changed_from:
        try:
            changed = changed_guards(args.changed_from)
        except RuntimeError as exc:
            print(f"::error::_canary-coverage: {exc}. Refusing to sweep a narrower set than asked "
                  f"for and call it clean.", file=sys.stderr)
            return 2
    else:
        changed = set()

    rc, _ = run_gate(guards, changed, args.budget, args.jobs, args.timeout)
    return rc


def _crash_exit_2(exc_type, exc, tb):
    """Any unhandled exception exits 2, never 1.

    1 is this file's "a detector is unproven" and, in --self-test, "everything worked". A crash
    must never be readable as either — the same remap every guard in this directory carries, for
    the same reason: Python's default rc 1 is exactly what CI's exit-exactly-1 assertion accepts.
    """
    sys.__excepthook__(exc_type, exc, tb)
    print("::error::_canary-coverage: crashed. Exiting 2 — the gate could not inspect what it "
          "claims to inspect, which is NOT 'every detector is proven'.", file=sys.stderr)
    sys.exit(2)


if __name__ == "__main__":
    sys.excepthook = _crash_exit_2
    sys.exit(main())
