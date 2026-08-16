#!/usr/bin/env python3
"""ttyd-auth-header-guard.py — nothing token-shaped may be fed into the header ttyd reads.

WHY THIS EXISTS (measured 2026-08-16; cost most of a day).
The shared cockpit passes attendee identity to ttyd through ONE HTTP header. ttyd's `-H/--auth-header`
flag names it and nginx composes its value. In gitops/workshop-config/templates/showroom-shared.yaml
the live pair is

    proxy_set_header X-Ws-Session "u=$http_x_forwarded_user;t=";        # nginx
    exec /usr/bin/ttyd … -W -H X-Ws-Session /tmp/ws-session             # ttyd

and the `t=` is deliberately EMPTY. ttyd/libwebsockets silently refuses a custom header whose VALUE
exceeds ~29 characters. Bisected through that same nginx with subprotocol `tty`, one variable at a
time, on that image:

    value length 10 15 20 25 28          -> 101 accepted
    value length 30 31 34 40 50 61       -> 502 DENIED

Total header SIZE is not the limit — a 2.4 KB Cookie on the same request passes. An OpenShift access
token is `sha256~` + 43 = 51 characters, so it can NEVER pass through `-H`. The original design
interpolated `$http_x_forwarded_access_token` into that header; every terminal died, and ttyd
reported "too long" and "absent" IDENTICALLY — one closed socket, one client-side "reconnecting" —
which is why the search went to oauth-proxy, cookie refresh and websocket header stripping for hours
looking for a header that was never missing. nginx's own access log recorded hdr_token=1 on the very
request ttyd rejected.

So the regression this guard prevents is: someone puts a token — or any other long value — back into
the header ttyd reads.

IT FOLLOWS THE FLAG, IT DOES NOT KNOW THE NAME. `X-Ws-Session` appears nowhere as a constant below.
The guard reads `-H <name>` out of the rendered ttyd command line and then judges the
`proxy_set_header <name> …` directives that feed it. Hard-coding today's name is the failure mode
where a rename silently disarms the gate and it reports success forever — so the canary renames the
header AND changes its case, and the self-test fails if that case stops being detected.

IT RENDERS, IT DOES NOT GREP. Both halves are Helm-templated: the header name, the variable, and the
value can each arrive from values.yaml, and a grep of the template then finds neither the token nor
the correlation. The canary is built that way on purpose — `git grep http_x_forwarded_access_token`
does not find it in tools/lint/ttyd-auth-header-guard.canary/chart/templates/broken-token.yaml.

── WHAT IT CATCHES ──────────────────────────────────────────────────────────────────────────────
  TOKEN   the value interpolates a credential-bearing nginx variable, directly or through ONE hop
          of `map`/`set`/`auth_request_set` indirection. Provably fatal: every credential this
          cluster issues is longer than the ceiling, and a credential in this header is also a
          credential in a place the design says it must never be.
  LENGTH  the value's VARIABLE-FREE length alone reaches the measured deny floor (30). Provable
          without knowing any runtime value, because variables can only make a value longer.
  EMPTY   the value is the empty string. nginx then does not send the field at all, ttyd denies the
          websocket for an ABSENT header, and the attendee sees the same "reconnecting" as the
          too-long case. Same evening, other end.

── WHAT IT DOES *NOT* CATCH, STATED PLAINLY ─────────────────────────────────────────────────────
This guard cannot bound the runtime length of a value that contains variables, and it does not
pretend to. `"u=$http_x_forwarded_user;t="` is 5 literal characters plus a username whose length is
a property of the cluster's identity provider, not of this repo: `user6` leaves 23 characters of
headroom, an email-shaped login could spend it. The clean-run summary PRINTS that budget per value
so the number is in front of whoever changes the line; it is not, and cannot honestly be, a failure.

Also out of scope, deliberately:
  * a token in some OTHER header. The content location of the real chart carries
    `proxy_set_header X-Forwarded-Access-Token ""` and the terminal upstream legitimately needs the
    token elsewhere; this gate is about the one field `-H` names, not a blanket credential sweep.
    (api-key-shape-guard.py and credential-redaction-guard.py cover committed secrets.)
  * more than ONE hop of nginx variable indirection. Two hops are not resolved; the guard says so in
    its output rather than implying it looked.
  * whether the header ACTUALLY reaches ttyd at runtime — location blocks and proxy_pass targets are
    not modelled. The correlation unit is the rendered TEMPLATE FILE: a header name is assumed to
    mean one thing throughout one template. That over-approximates (a same-named field set on a
    location that does not front ttyd is still judged), which fails in the safe direction.

USAGE
    tools/lint/ttyd-auth-header-guard.py                 # check the tree
    tools/lint/ttyd-auth-header-guard.py --list-headers  # every -H found and every value feeding it
    tools/lint/ttyd-auth-header-guard.py --self-test     # scan the canary chart; MUST exit 1

EXIT CODES (same contract as image-pull-policy-guard.py / hook-env-guard.py):
    0  every header ttyd reads is fed a short, credential-free, non-empty value
    1  at least one is not — or, under --self-test, every canary was correctly detected
    2  the guard could not do its job (helm/git/PyYAML missing, a render failed, a COLLAPSED scope,
       an unparseable ttyd command line, a `-H` whose value it cannot read, a `-H` naming a header
       nothing feeds, a ttyd `-H` in a file it does not render, or an undetected canary). Never
       confuse this with a clean result.

LOCAL YAMLLINT: the canary chart's templates carry Helm actions inside block scalars, so they parse
as YAML and need no exclusion — unlike copy-drift-guard's and image-pull-policy-guard's fixtures.
Nothing to add to your gitignored .yamllint.yaml for this one.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import shlex
import shutil
import subprocess
import sys


def _crash_exit_2(exc_type, exc, tb):
    """Any uncaught exception → rc 2, INCLUDING one raised at MODULE level.

    Module-level code runs before `__main__` exists, so a bad constant or a failed import would exit
    with Python's default rc 1 — which is exactly what CI's `--self-test must exit EXACTLY 1` reads
    as "the canary fired". Installed as the first statement after the imports so it is already in
    place before anything below can fail; `os._exit` is what makes the status stick, because an
    excepthook cannot change the exit code by returning.
    """
    import os
    import traceback
    traceback.print_exception(exc_type, exc, tb)
    print(f"::error::ttyd-auth-header-guard: crashed before it could report "
          f"({exc_type.__name__}: {exc}). "
          f"Exiting 2 — a crash is 'the guard could not run', never 'clean' and never "
          f"'canary detected'.", file=sys.stderr)
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(2)


sys.excepthook = _crash_exit_2


sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
try:
    from _scope import Scope  # noqa: E402  (path must be set first)
except Exception as exc:  # noqa: BLE001 — deliberately broad, see image-pull-policy-guard's note
    print(f"::error::ttyd-auth-header-guard: cannot import _scope ({exc}) — the guard could not "
          f"start, which is NOT the same as a clean tree.", file=sys.stderr)
    sys.exit(2)

try:
    import yaml
except ImportError:  # pragma: no cover — exercised only on a machine without PyYAML
    print("ttyd-auth-header-guard: PyYAML is not installed. This guard parses RENDERED manifests "
          "rather than pattern-matching templates, so it cannot run without a parser — refusing to "
          "report clean. Install it (python3 -m pip install PyYAML) and re-run.", file=sys.stderr)
    sys.exit(2)


# ------------------------------------------------------------------------------ measured constants

# The bisection of 2026-08-16, recorded as two numbers rather than one so the guard can never claim
# to know something that was not measured. 29 was NOT probed: 28 passed, 30 failed. The failure rule
# below uses the DENY floor, so an unmeasured length is never reported as a defect.
MEASURED_ACCEPTED_MAX = 28
MEASURED_DENIED_MIN = 30

# ------------------------------------------------------------------------------ what to render

# Chart discovery roots. Every directory that can hold a chart which ships a cockpit. `.canary` paths
# are excluded below: this guard's own fixture chart is FULL of the defect on purpose, and rendering
# it in the tree scan would redden main forever.
CHART_ROOTS = ("gitops", "platform-portfolio", "helm")
CANARY_MARKER = ".canary"

# Values a chart needs before the cockpit it ships exists at all. Set EXPLICITLY rather than trusted
# to the chart's default: showroom.shared.enabled ships false (the shared cockpit stands up alongside
# the per-user ones only when someone asks for it), so a run at defaults renders no ttyd `-H` and
# this gate would judge nothing while printing "clean". A chart not named here is rendered at its
# defaults.
CHART_VALUE_SETS: dict[str, tuple[dict, ...]] = {
    "gitops/workshop-config": (
        {"showroom.shared.enabled": "true"},
    ),
}

# ------------------------------------------------------------------------------ the raw coverage lane

# The tree scan renders charts. This lane answers the question a renderer cannot: is there a ttyd
# `-H` somewhere the renderer never looks? Restricted to manifest-bearing roots and manifest file
# types, because prose is allowed to describe the flag — a troubleshooting page writing
# `ttyd -H X-Ws-Session` is documentation, not a deployment.
RAW_ROOTS = ("gitops", "platform-portfolio", "helm", "bootstrap", "pipelines", "showroom", "apps")
RAW_SUFFIXES = (".yaml", ".yml", ".tpl", ".json")

# ------------------------------------------------------------------------------ classification

# A ttyd command word: the executable, however it is pathed. `runttyd` (the terminal image's own
# entrypoint, which takes no -H) is NOT this, and neither is TTYD_USER.
TTYD_BASENAMES = frozenset({"ttyd"})

AUTH_HEADER_LONG = "--auth-header"
AUTH_HEADER_SHORT = "-H"

# What a header field name may look like. Deliberately narrower than RFC 9110's `token` production:
# `+`, `*` and `#` are legal HTTP token characters, and accepting them would make every prose line
# containing "ttyd -H + something" a finding. A `-H` value outside this shape is an exit 2 in the
# rendered lane (the guard cannot read the name, so it cannot follow it) and simply not a site in the
# raw prose-adjacent lane.
HEADER_NAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_-]*$")

# An nginx variable reference: $name or ${name}. Capture groups $1..$9 are matched too — they are how
# a `map` with a regex key forwards part of its source.
NGINX_VARIABLE_RE = re.compile(r"\$\{(\w+)\}|\$(\w+)")

# Words that make a variable name credential-bearing. Open-ended ON PURPOSE: the point is to catch
# the name nobody has invented yet, not to enumerate today's. `session` alone is absent — the header
# in the real chart is literally called X-Ws-Session and a value assembled into `$ws_session` is not
# a credential.
CREDENTIAL_WORD_RE = re.compile(
    r"(token|secret|passwd|password|credential|api_?key|access_?key|private_?key|authorization"
    r"|bearer|jwt|session_?id|session_?key|cookie|_cert)", re.IGNORECASE)

# nginx built-ins that carry a credential regardless of what the word list says. Named explicitly so
# that narrowing CREDENTIAL_WORD_RE later cannot silently drop them; the self-test proves each
# mechanism on its own, so neither can quietly become the only one doing the work.
CREDENTIAL_VARIABLES = frozenset({
    "http_cookie",
    "http_authorization",
    "http_proxy_authorization",
    "ssl_client_cert",
    "ssl_client_escaped_cert",
    "ssl_client_raw_cert",
})

# Directives that bind a new variable from an expression. `map` is handled separately because its
# forwarding decision lives in its block body, not on its own line.
SET_DIRECTIVES = frozenset({"set", "auth_request_set", "js_set", "perl_set"})

# `\$` in an nginx value is a literal dollar, not a variable. Unescaping it to `$` before the
# variable regex runs would invent a variable; this sentinel carries it through untouched and is put
# back only for the length arithmetic.
# A private-use codepoint, written as an escape rather than pasted: an invisible literal in
# source is a maintenance trap.
DOLLAR_SENTINEL = "\ue000"

RULES = ("TOKEN", "LENGTH", "EMPTY")

# Scope dimensions, named once so the counters and their floors cannot drift apart.
COLLECT_DIMENSIONS = ("charts rendered", "helm renders", "rendered documents", "ttyd invocations",
                      "auth-header invocations", "nginx configs", "proxy_set_header directives")
RAW_DIMENSIONS = ("raw manifest files scanned", "raw auth-header files")
JUDGE_DIMENSIONS = ("auth-header values judged",)


class GuardError(Exception):
    """The guard cannot do its job. Always an exit 2, never a silent pass."""


def repo_root() -> pathlib.Path:
    return pathlib.Path(__file__).resolve().parents[2]


# ------------------------------------------------------------------------------ shell-side scanning


def _ttyd_positions(tokens: list[str]) -> list[int]:
    return [i for i, t in enumerate(tokens) if t.rsplit("/", 1)[-1] in TTYD_BASENAMES]


def _auth_header_values(tokens: list[str], start: int, where: str, line: int) -> list[str]:
    """Every `-H` value in the argv slice after a ttyd command word.

    Four spellings are understood — `-H X`, `-HX`, `--auth-header X`, `--auth-header=X` — because a
    parser that only knows the spelling in today's chart stops working the first time someone
    reformats it.

    A SINGLE-DASH CLUSTER containing H that is not `-H…` (`-WH X`) raises. getopt would read it as
    W then H-takes-an-argument, but resolving a cluster correctly needs ttyd's full option table
    (`-p`, `-i`, `-c`, `-u`, `-b`, … all take arguments, so `-pH` means p="H" and not an auth
    header). Guessing either way is how a gate starts reporting on the wrong string, so this fails
    closed and asks for the flag to be written out.
    """
    values: list[str] = []
    rest = tokens[start + 1:]
    i = 0
    while i < len(rest):
        token = rest[i]
        if token == AUTH_HEADER_SHORT or token == AUTH_HEADER_LONG:
            if i + 1 >= len(rest):
                raise GuardError(
                    f"{where} line {line}: ttyd is invoked with `{token}` as its LAST argument, so "
                    f"the guard cannot read which header it names — and therefore cannot check what "
                    f"feeds it.")
            values.append(rest[i + 1])
            i += 2
            continue
        if token.startswith(AUTH_HEADER_LONG + "="):
            values.append(token.split("=", 1)[1])
            i += 1
            continue
        if token.startswith(AUTH_HEADER_SHORT) and len(token) > 2 and not token.startswith("--"):
            values.append(token[2:])
            i += 1
            continue
        if (len(token) > 2 and token[0] == "-" and token[1] != "-" and "H" in token[1:]
                and not token.startswith(AUTH_HEADER_SHORT)):
            raise GuardError(
                f"{where} line {line}: ttyd is invoked with the bundled short-option cluster "
                f"{token!r}, which contains H. Resolving a cluster needs ttyd's full option table "
                f"(several short flags take arguments), so this guard refuses to guess whether that "
                f"H is the auth header. Write `-H <name>` on its own.")
        i += 1
    return values


def find_ttyd_invocations(text: str, source: str, where: str) -> tuple[list[dict], int]:
    """(auth-header invocations, total ttyd command words) in one shell-ish string.

    Line-oriented and shlex-tokenized with comments enabled, which is what keeps the prose out: the
    real chart's script carries lines like `# The wrapper ttyd execs per websocket. TTYD_USER is set
    by ttyd from the -H header, so` — a regex over the raw text reads `-H header,` out of that and
    invents a header nothing feeds. shlex with comments=True returns [] for it.
    """
    invocations: list[dict] = []
    total = 0
    for line_no, line in enumerate(text.splitlines(), 1):
        if "ttyd" not in line:
            continue
        try:
            tokens = shlex.split(line, comments=True)
        except ValueError as exc:
            # Only fatal if the unparseable line actually invokes ttyd. Scripts contain plenty of
            # legitimately unbalanced quoting in lines that have nothing to do with this gate.
            if re.search(r"(?:^|[\s;&|(])(?:[\w./-]*/)?ttyd(?=\s|$)", line):
                raise GuardError(
                    f"{source} ({where}) line {line_no} invokes ttyd but could not be tokenized as "
                    f"a shell command ({exc}). The guard cannot read its flags, so it cannot say "
                    f"whether a token is being fed to -H.") from exc
            continue
        for position in _ttyd_positions(tokens):
            total += 1
            for value in _auth_header_values(tokens, position, f"{source} ({where})", line_no):
                if not HEADER_NAME_RE.match(value):
                    raise GuardError(
                        f"{source} ({where}) line {line_no}: ttyd's auth header is named {value!r}, "
                        f"which is not a field name this guard can follow. It cannot find the "
                        f"proxy_set_header that feeds it, so it cannot check it.")
                invocations.append({
                    "header": value,
                    "source": source,
                    "where": where,
                    "line": line_no,
                    "command": " ".join(tokens[position:position + 12]),
                })
    return invocations, total


# ------------------------------------------------------------------------------ nginx-side parsing


class NginxToken:
    __slots__ = ("text", "quoted", "line")

    def __init__(self, text: str, quoted: bool, line: int):
        self.text = text
        self.quoted = quoted
        self.line = line

    def __repr__(self) -> str:  # pragma: no cover — debugging aid
        return f"NginxToken({self.text!r}, quoted={self.quoted}, line={self.line})"


class Directive:
    __slots__ = ("words", "line", "children")

    def __init__(self, words: list[NginxToken], line: int, children):
        self.words = words
        self.line = line
        self.children = children

    @property
    def name(self) -> str:
        return self.words[0].text if self.words else ""


def tokenize_nginx(conf: str) -> list[NginxToken]:
    """Tokenize an nginx config, honouring quotes.

    THE QUOTING IS THE WHOLE REASON THIS EXISTS. The live value is

        proxy_set_header X-Ws-Session "u=$http_x_forwarded_user;t=";

    and the `;` sits INSIDE the quotes. A directive read with a non-greedy match up to the first `;`
    yields `"u=$http_x_forwarded_user` — everything after the semicolon, which is exactly where a
    reintroduced token would sit, is invisible. A guard built that way reports the bug it exists to
    catch as clean. The canary plants the token in that position for this reason.
    """
    tokens: list[NginxToken] = []
    buffer: list[str] = []
    buffer_quoted = False
    have_buffer = False
    line = 1
    start_line = 1
    i = 0
    length = len(conf)

    def flush() -> None:
        nonlocal buffer, buffer_quoted, have_buffer
        if have_buffer:
            tokens.append(NginxToken("".join(buffer), buffer_quoted, start_line))
        buffer = []
        buffer_quoted = False
        have_buffer = False

    while i < length:
        char = conf[i]
        if char == "\n":
            flush()
            line += 1
            i += 1
            continue
        if char in " \t\r":
            flush()
            i += 1
            continue
        if char == "#":
            while i < length and conf[i] != "\n":
                i += 1
            continue
        if char in ";{}":
            flush()
            tokens.append(NginxToken(char, False, line))
            i += 1
            continue
        if char in "\"'":
            quote = char
            if not have_buffer:
                have_buffer = True
                start_line = line
            buffer_quoted = True
            i += 1
            while i < length and conf[i] != quote:
                if conf[i] == "\\" and i + 1 < length:
                    nxt = conf[i + 1]
                    buffer.append(DOLLAR_SENTINEL if nxt == "$" else nxt)
                    if nxt == "\n":
                        line += 1
                    i += 2
                    continue
                if conf[i] == "\n":
                    line += 1
                buffer.append(conf[i])
                i += 1
            i += 1  # the closing quote (or EOF; an unterminated quote just ends the token)
            continue
        if not have_buffer:
            have_buffer = True
            start_line = line
        if char == "\\" and i + 1 < length:
            nxt = conf[i + 1]
            buffer.append(DOLLAR_SENTINEL if nxt == "$" else nxt)
            i += 2
            continue
        buffer.append(char)
        i += 1

    flush()
    return tokens


def parse_nginx(tokens: list[NginxToken], index: int = 0, depth: int = 0):
    """Tokens → a directive tree. Returns (directives, next index)."""
    directives: list[Directive] = []
    words: list[NginxToken] = []
    while index < len(tokens):
        token = tokens[index]
        if token.text == ";" and not token.quoted:
            if words:
                directives.append(Directive(words, words[0].line, None))
            words = []
            index += 1
            continue
        if token.text == "{" and not token.quoted:
            children, index = parse_nginx(tokens, index + 1, depth + 1)
            directives.append(Directive(words, words[0].line if words else token.line, children))
            words = []
            continue
        if token.text == "}" and not token.quoted:
            if words:
                directives.append(Directive(words, words[0].line, None))
            return directives, index + 1
        words.append(token)
        index += 1
    if words:
        directives.append(Directive(words, words[0].line, None))
    return directives, index


def walk_directives(directives: list[Directive]):
    for directive in directives:
        yield directive
        if directive.children:
            yield from walk_directives(directive.children)


# ------------------------------------------------------------------------------ values and taint


def value_variables(text: str) -> set[str]:
    """Every nginx variable referenced in a value. `\\$` never counts — see DOLLAR_SENTINEL."""
    return {m.group(1) or m.group(2) for m in NGINX_VARIABLE_RE.finditer(text)}


def literal_length(text: str) -> int:
    """The value's length with every variable reference removed — its provable LOWER BOUND.

    A variable can only ever make a value longer (it may render empty, never negative), so this is
    the one length statement that holds without knowing anything about the cluster. Everything else
    the guard says about length is a budget, printed, not enforced.
    """
    return len(NGINX_VARIABLE_RE.sub("", text).replace(DOLLAR_SENTINEL, "$"))


def is_credential_variable(name: str) -> bool:
    return name in CREDENTIAL_VARIABLES or bool(CREDENTIAL_WORD_RE.search(name))


def build_taint(directives: list[Directive]) -> tuple[dict[str, set[str]], dict[str, str], set[str]]:
    """(taint, folded literals, locally-defined names) for one nginx config.

    `taint` maps var -> the variables it can carry the content of, resolved transitively below.

    `literals` folds a `set $x "…"` whose value holds no variable at all: `$x` IS that string, so its
    length is knowable and is added to the value's provable lower bound. One hop, and `set` only — a
    `map`'s result depends on its key, so its length is a range and folding it would be a guess.

    `defined` is every variable this config BINDS, and it is what stops the name heuristic from
    overruling structural evidence. The live chart contains

        map $http_x_forwarded_access_token $ws_hdr_token { default 1; '' 0; }

    whose target is named `…_token` and provably carries no token — it exists so the access log can
    record hdr_token=0|1 without putting a credential in a log. Classifying a locally-bound variable
    by its NAME would flag that, and a gate that flags the line written to be safe is a gate that
    gets switched off. So: a variable this config binds is judged by what it is bound TO (its taint
    sources are already in the reachable set); only names this config does not define — the `$http_*`
    built-ins the credential actually arrives in — are judged by their name.

    `map` is the subtle one, and getting it wrong in either direction is a real cost:

      map $http_x_forwarded_access_token $hdr_token { default 1; '' 0; }

    is in the live chart — it exists so `hdr_token=0|1` can be written to the access log without
    putting a credential in a log. Its results are CONSTANTS, so nothing of the token survives, and
    a naive "dst inherits src" rule would flag a line that is not merely safe but was written to be
    safe. The rule here is therefore: a map forwards its source only if some RESULT references a
    variable — `default $src`, or a `$1` capture from a regex key. Everything else collapses.

    `set`/`auth_request_set`/`js_set`/`perl_set` are the plain case: the bound variable carries
    whatever its expression references.
    """
    taint: dict[str, set[str]] = {}
    literals: dict[str, str] = {}
    defined: set[str] = set()

    def record(target: str, sources: set[str]) -> None:
        if sources:
            taint.setdefault(target, set()).update(sources)

    for directive in walk_directives(directives):
        if directive.name == "map" and directive.children is not None and len(directive.words) >= 3:
            source_vars = value_variables(directive.words[1].text)
            target = value_variables(directive.words[2].text)
            defined |= target
            forwards = False
            for entry in directive.children:
                # An entry is `<key> <result…>;`. A bare key with no result forwards nothing.
                for result in entry.words[1:]:
                    if NGINX_VARIABLE_RE.search(result.text):
                        forwards = True
            if forwards:
                for name in target:
                    record(name, source_vars)
        elif directive.name in SET_DIRECTIVES and len(directive.words) >= 3:
            target = value_variables(directive.words[1].text)
            defined |= target
            sources: set[str] = set()
            for word in directive.words[2:]:
                sources |= value_variables(word.text)
            for name in target:
                record(name, sources)
            if not sources and len(directive.words) == 3:
                for name in target:
                    literals[name] = directive.words[2].text.replace(DOLLAR_SENTINEL, "$")
    return taint, literals, defined


def resolve_taint(names: set[str], taint: dict[str, set[str]]) -> set[str]:
    """Transitive closure of `names` over the taint graph, cycle-safe."""
    seen: set[str] = set()
    pending = list(names)
    while pending:
        name = pending.pop()
        if name in seen:
            continue
        seen.add(name)
        pending.extend(taint.get(name, ()))
    return seen


# ------------------------------------------------------------------------------ header sites


def nginx_header_sites(conf: str, source: str, where: str) -> tuple[list[dict], int]:
    """(proxy_set_header sites, total proxy_set_header directives seen) in one nginx config."""
    directives, _ = parse_nginx(tokenize_nginx(conf))
    taint, literals, defined = build_taint(directives)
    sites: list[dict] = []
    total = 0
    for directive in walk_directives(directives):
        if directive.name != "proxy_set_header" or len(directive.words) < 2:
            continue
        total += 1
        field = directive.words[1].text
        value_words = directive.words[2:]
        value = " ".join(word.text for word in value_words)
        # `proxy_set_header X;` with no value word at all behaves like the empty form: nginx has
        # nothing to send. Treated identically rather than skipped, so it cannot slip through.
        direct = value_variables(value)
        folded = sum(len(literals[name]) for name in direct if name in literals)
        sites.append({
            "field": field,
            "value": value,
            "printable": value.replace(DOLLAR_SENTINEL, "\\$"),
            "direct_variables": direct,
            "reachable_variables": resolve_taint(direct, taint),
            "locally_defined": defined,
            "literal_length": literal_length(value) + folded,
            "source": source,
            "where": where,
            "line": directive.line,
        })
    return sites, total


# ------------------------------------------------------------------------------ collecting


def _require(tool: str, why: str) -> None:
    if shutil.which(tool) is None:
        raise GuardError(f"{tool} is not on PATH. {why} Refusing to report clean.")


def render_helm(root: pathlib.Path, chart: pathlib.Path, values: dict) -> str:
    _require("helm", "This guard RENDERS charts rather than grepping them — the header name, the "
                     "variable and the value can each arrive from values.yaml, and a grep sees none "
                     "of the three.")
    cmd = ["helm", "template", "t", str(chart)]
    for key, value in values.items():
        cmd += ["--set", f"{key}={value}"]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False, cwd=root)
    if proc.returncode != 0:
        label = " ".join(f"{k}={v}" for k, v in values.items()) or "<defaults>"
        raise GuardError(
            f"`helm template` failed for {chart} ({label}), rc={proc.returncode}:\n"
            f"{proc.stderr.strip()}\n"
            "A chart that will not render is a chart this guard did not check.")
    return proc.stdout


def split_documents(rendered: str, label: str) -> list[tuple[str, dict]]:
    """(source template, document) pairs, keeping helm's `# Source:` attribution.

    PyYAML's safe_load_all drops comments, and the `# Source:` line is the only thing that says which
    template a document came from — the correlation unit this guard works in. So the render is split
    on document separators at column 0 and each chunk is parsed on its own. That split is then
    CHECKED against safe_load_all over the whole text: a `---` inside a block scalar would be
    indented and cannot appear at column 0, but the assertion is cheap and the failure mode
    (documents silently merged or lost) is invisible without it.
    """
    chunks = re.split(r"(?m)^---[ \t]*$\n?", rendered)
    pairs: list[tuple[str, dict]] = []
    for chunk in chunks:
        if not chunk.strip():
            continue
        try:
            document = yaml.safe_load(chunk)
        except yaml.YAMLError as exc:
            raise GuardError(f"{label}: a rendered document did not parse as YAML ({exc}).") from exc
        if not isinstance(document, dict):
            continue
        match = re.search(r"^# Source: (\S+)", chunk, re.M)
        pairs.append((match.group(1) if match else f"{label} <no # Source line>", document))
    try:
        whole = sum(1 for d in yaml.safe_load_all(rendered) if isinstance(d, dict))
    except yaml.YAMLError as exc:
        raise GuardError(f"{label}: the render did not parse as a YAML stream ({exc}).") from exc
    if whole != len(pairs):
        raise GuardError(
            f"{label}: splitting the render on document separators produced {len(pairs)} mapping "
            f"document(s) but the YAML stream holds {whole}. The source-file attribution this guard "
            f"correlates on is unreliable, so it is refusing to judge anything.")
    return pairs


def string_leaves(document) -> list[tuple[str, list]]:
    """Every string leaf, with its path — plus command/args lists joined into one argv line.

    The join matters: a container may spell the invocation `command: ["ttyd", "-H", "X-…"]` rather
    than as one shell string, and a leaf-by-leaf scan sees `ttyd` and `-H` as separate strings with
    no relationship.

    It is emitted ONLY when some element IS the ttyd executable — the genuine "argv as separate
    tokens" shape. The real chart's container is `args: ["/bin/bash", "-lc", "<whole script>"]`, and
    joining that would hand the scanner a second copy of the same script: the same invocation found
    twice, every scope counter doubled, and the counters are what the floors are raised from.
    """
    out: list[tuple[str, list]] = []

    def walk(node, path: list) -> None:
        if isinstance(node, str):
            out.append((node, list(path)))
        elif isinstance(node, dict):
            for key, value in node.items():
                if (key in ("command", "args") and isinstance(value, list) and len(value) > 1
                        and all(isinstance(v, str) for v in value)
                        and _ttyd_positions(value)):
                    out.append((" ".join(value), path + [key, "<joined argv>"]))
                walk(value, path + [key])
        elif isinstance(node, list):
            for i, value in enumerate(node):
                walk(value, path + [i])

    walk(document, [])
    return out


def collect(root: pathlib.Path, charts: list[pathlib.Path]) -> tuple[list[dict], list[dict], dict]:
    """(auth-header invocations, header sites, scope counters) across every rendered chart."""
    invocations: list[dict] = []
    sites: list[dict] = []
    counts = {dimension: 0 for dimension in COLLECT_DIMENSIONS}

    for chart in charts:
        counts["charts rendered"] += 1
        relative = chart.relative_to(root).as_posix() if chart.is_relative_to(root) else str(chart)
        for values in CHART_VALUE_SETS.get(relative, ({},)):
            label = f"{relative} ({' '.join(f'{k}={v}' for k, v in values.items()) or 'defaults'})"
            counts["helm renders"] += 1
            for source, document in split_documents(render_helm(root, chart, values), label):
                counts["rendered documents"] += 1
                kind = document.get("kind", "<no kind>")
                name = (document.get("metadata") or {}).get("name", "<unnamed>")
                for text, path in string_leaves(document):
                    where = f"{kind}/{name} at {'/'.join(str(p) for p in path)}"
                    if "ttyd" in text:
                        found, seen = find_ttyd_invocations(text, source, where)
                        counts["ttyd invocations"] += seen
                        counts["auth-header invocations"] += len(found)
                        invocations += found
                    if "proxy_set_header" in text:
                        counts["nginx configs"] += 1
                        found_sites, seen_directives = nginx_header_sites(text, source, where)
                        counts["proxy_set_header directives"] += seen_directives
                        sites += found_sites
    return invocations, sites, counts


def discover_charts(root: pathlib.Path) -> list[pathlib.Path]:
    """Charts that mention ttyd anywhere in their own files.

    Substring, not the strict command-word test: discovery should be GENEROUS (a chart that only
    talks about ttyd costs one render and finds nothing), while detection is strict. `.canary` paths
    are excluded — this guard's fixture chart carries the defect deliberately.
    """
    charts: list[pathlib.Path] = []
    for chart_root in CHART_ROOTS:
        base = root / chart_root
        if not base.is_dir():
            continue
        for chart_file in base.rglob("Chart.yaml"):
            chart = chart_file.parent
            if any(CANARY_MARKER in part for part in chart.parts):
                continue
            for path in chart.rglob("*"):
                if not path.is_file():
                    continue
                try:
                    if "ttyd" in path.read_text(encoding="utf-8"):
                        charts.append(chart)
                        break
                except (OSError, UnicodeDecodeError):
                    continue
    return sorted(set(charts))


# ------------------------------------------------------------------------------ the raw coverage lane


def raw_auth_header_files(root: pathlib.Path) -> tuple[list[dict], int]:
    """Manifest files that invoke ttyd with an auth header, from the TEXT rather than a render.

    This is the only thing that notices a cockpit the renderer never reaches — a ttyd moved into a
    kustomize base, a plain manifest, a chart outside CHART_ROOTS. It cannot judge such a file (the
    text is a template, not a manifest), so what it does is REPORT it: the tree scan turns an
    unrendered site into an exit 2 rather than letting the gate pass over something it never looked
    at.

    `git ls-files` rather than a filesystem walk, so the file set is identical on a maintainer laptop
    (where gitignored trees like docs/ are present) and in CI (where they are not).
    """
    _require("git", "The coverage lane enumerates the repo with `git ls-files` so a maintainer "
                    "laptop and CI see the same file set.")
    proc = subprocess.run(["git", "ls-files", "-z"], capture_output=True, text=True, check=False,
                          cwd=root)
    if proc.returncode != 0:
        raise GuardError(f"`git ls-files` failed (rc={proc.returncode}): {proc.stderr.strip()}")

    hits: list[dict] = []
    scanned = 0
    for relative in proc.stdout.split("\0"):
        if not relative:
            continue
        path = pathlib.Path(relative)
        if path.parts[0] not in RAW_ROOTS or path.suffix not in RAW_SUFFIXES:
            continue
        if any(CANARY_MARKER in part for part in path.parts):
            continue
        try:
            text = (root / path).read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        scanned += 1
        if "ttyd" not in text:
            continue
        for line_no, line in enumerate(text.splitlines(), 1):
            if "ttyd" not in line:
                continue
            try:
                tokens = shlex.split(line, comments=True)
            except ValueError:
                continue
            for position in _ttyd_positions(tokens):
                try:
                    values = _auth_header_values(tokens, position, relative, line_no)
                except GuardError:
                    # Unreadable flags in RAW text are prose, not a defect — a Helm comment block
                    # writing "ttyd -H + TTYD_USER" is documentation. The rendered lane is where an
                    # unreadable flag is fatal, because there it is a real argv.
                    continue
                for value in values:
                    if HEADER_NAME_RE.match(value):
                        hits.append({"path": relative, "line": line_no, "header": value})
    return hits, scanned


def coverage_blockers(hits: list[dict], charts: list[pathlib.Path],
                      root: pathlib.Path) -> list[str]:
    covered = [chart.relative_to(root).as_posix() for chart in charts]
    blockers: list[str] = []
    for hit in hits:
        if any(hit["path"] == chart or hit["path"].startswith(chart + "/") for chart in covered):
            continue
        blockers.append(
            f"{hit['path']}:{hit['line']} invokes ttyd with -H {hit['header']}, and that file is "
            f"not inside any chart this guard renders ({', '.join(covered) or 'none'}).\n"
            "      The gate would report clean while a cockpit it never looked at fed whatever it "
            "liked into that header. Add the chart to CHART_ROOTS/CHART_VALUE_SETS, or teach this "
            "guard how the file is rendered.")
    return blockers


# ------------------------------------------------------------------------------ the check


def evaluate(invocations: list[dict], sites: list[dict]) -> tuple[list[dict], list[str], dict]:
    """(findings, blockers, stats). A blocker is an exit-2 condition, not a violation."""
    sites_by_file: dict[str, list[dict]] = {}
    for site in sites:
        sites_by_file.setdefault(site["source"], []).append(site)

    findings: list[dict] = []
    blockers: list[str] = []
    stats = {"invocations": len(invocations), "judged": 0, "headers": set()}
    seen: set[tuple] = set()

    for invocation in invocations:
        header = invocation["header"]
        stats["headers"].add(header.casefold())
        # Case-insensitive on purpose: HTTP field names are, nginx's are, and libwebsockets
        # lowercases them. A literal comparison would read `-H X-Cockpit-Identity` against
        # `proxy_set_header x-cockpit-identity …` as "nothing feeds this" and miss a live defect.
        same_file = [s for s in sites_by_file.get(invocation["source"], [])
                     if s["field"].casefold() == header.casefold()]
        elsewhere = [s for s in sites if s["field"].casefold() == header.casefold()
                     and s["source"] != invocation["source"]]
        matched = same_file or elsewhere
        if not matched:
            blockers.append(
                f"{invocation['source']} {invocation['where']} line {invocation['line']}\n"
                f"      runs `{invocation['command']}` but nothing in the rendered chart sets "
                f"{header}.\n"
                "      The guard cannot follow the flag to a value, so it cannot say whether a "
                "token is being fed to it — and a header nginx never sets is one the CLIENT can "
                "send, which is worse than a long value. Set it on the location that fronts ttyd.")
            continue
        for site in matched:
            # `where` is in the key, not just source+line. The shared cockpit renders TWICE from one
            # template — the workshop flavor and the SA-demo flavor — into two ConfigMaps whose
            # nginx.conf is byte-identical, so source+line+value collapses four real sites to two and
            # the scope floor below silently loses half its resolution.
            key = (site["source"], site["where"], site["line"], site["field"].casefold(),
                   site["value"])
            if key in seen:
                continue
            seen.add(key)
            stats["judged"] += 1
            findings += judge_site(site, invocation, borrowed=not same_file)

    stats["headers"] = sorted(stats["headers"])
    return findings, blockers, stats


def judge_site(site: dict, invocation: dict, borrowed: bool) -> list[dict]:
    """Every rule, applied to one `proxy_set_header` value that ttyd reads."""
    findings: list[dict] = []
    # Only names this config does NOT bind are judged by their name — see build_taint's docstring for
    # the live `$ws_hdr_token` that makes the difference between a working gate and an ignored one.
    credential = sorted(n for n in site["reachable_variables"]
                        if n not in site["locally_defined"] and is_credential_variable(n))

    if credential:
        indirect = sorted(set(credential) - site["direct_variables"])
        route = (f" (reached through {', '.join('$' + n for n in indirect)} — one hop of "
                 f"nginx map/set indirection)" if indirect else "")
        findings.append({
            "rule": "TOKEN",
            "site": site,
            "invocation": invocation,
            "borrowed": borrowed,
            "detail": (f"interpolates {', '.join('$' + n for n in credential)}{route}."),
            "fix": ("Take the credential out of this header. It cannot work: every credential this "
                    f"cluster issues is longer than the {MEASURED_DENIED_MIN}-character deny floor "
                    "(an OpenShift access token is `sha256~` + 43 = 51), and ttyd reports a refused "
                    "header and an absent one identically — the terminal just says 'reconnecting'. "
                    "If the shell genuinely needs a secret, -H is not the channel."),
        })

    if site["literal_length"] >= MEASURED_DENIED_MIN:
        findings.append({
            "rule": "LENGTH",
            "site": site,
            "invocation": invocation,
            "borrowed": borrowed,
            "detail": (f"is {site['literal_length']} characters before any variable expands, and "
                       f"values of {MEASURED_DENIED_MIN} characters and up were measured DENIED "
                       f"(502) by ttyd/libwebsockets on 2026-08-16."),
            "fix": (f"Shorten it. {MEASURED_ACCEPTED_MAX} characters is the longest value measured "
                    "accepted; variables only ever make it longer."),
        })

    if site["value"] == "":
        findings.append({
            "rule": "EMPTY",
            "site": site,
            "invocation": invocation,
            "borrowed": borrowed,
            "detail": ("is the empty string, so nginx does not send the field at all and ttyd "
                       "denies the websocket for an ABSENT auth header."),
            "fix": ("Give it a value that is never empty. A denied websocket is a closed socket, "
                    "and 'reconnecting' forever with no reason is the only thing the ttyd client "
                    "can render — the same symptom as a too-long value."),
        })

    return findings


# ------------------------------------------------------------------------------ self-test


def _canary_chart(root: pathlib.Path) -> pathlib.Path:
    return root / "tools/lint/ttyd-auth-header-guard.canary/chart"


def _unit_failures() -> list[str]:
    """The detectors, exercised directly. Each one is a shape a fixture cannot isolate as cleanly."""
    failures: list[str] = []

    # The quoting trap: the `;` inside the quotes, with the token AFTER it. A directive read up to
    # the first `;` finds a clean-looking value and this guard reports the live bug as fine.
    conf = ('http { server { location /t/ {\n'
            '  proxy_set_header X-Ws-Session '
            '"u=$http_x_forwarded_user;t=$http_x_forwarded_access_token";\n'
            '} } }\n')
    sites, total = nginx_header_sites(conf, "unit", "quoting")
    if total != 1 or len(sites) != 1:
        failures.append(f"the nginx parser found {total} proxy_set_header directive(s) in a config "
                        "holding exactly one.")
    elif "http_x_forwarded_access_token" not in sites[0]["direct_variables"]:
        failures.append("the nginx parser stopped at the `;` INSIDE the quoted value — the token "
                        "after it was invisible, which is precisely the live defect this guard "
                        "exists to catch.")

    # A map whose results are constants COLLAPSES its source; one that references a variable, or
    # captures with $1, FORWARDS it. Written with the live chart's own variable NAME, because that
    # is the trap: `$ws_hdr_token` is called …_token and provably carries no token, so structural
    # evidence has to beat the name heuristic. The canary's clean.yaml caught this for real.
    collapsing = ('http {\n'
                  '  map $http_x_forwarded_access_token $ws_hdr_token { default 1; \'\' 0; }\n'
                  '  server { location /t/ { proxy_set_header X-H "u=$ws_hdr_token"; } }\n'
                  '}\n')
    site = nginx_header_sites(collapsing, "unit", "map-collapse")[0][0]
    if any(n not in site["locally_defined"] and is_credential_variable(n)
           for n in site["reachable_variables"]):
        failures.append("a map whose results are the constants 1 and 0 was treated as forwarding "
                        "its source, or its …_token TARGET was judged by its name — either way the "
                        "live chart's hdr_token access-log flag becomes a finding.")

    forwarding = ('http {\n'
                  '  map $http_authorization $bearer { "~^Bearer\\s+(.*)$" $1; default ""; }\n'
                  '  server { location /t/ { proxy_set_header X-H "u=$bearer"; } }\n'
                  '}\n')
    site = nginx_header_sites(forwarding, "unit", "map-forward")[0][0]
    if not any(is_credential_variable(n) for n in site["reachable_variables"]):
        failures.append("a map that forwards its source through a $1 capture was treated as "
                        "collapsing it — one rename of the target variable disarms the guard.")

    setting = ('http { server { location /t/ {\n'
               '  set $carrier $http_x_forwarded_access_token;\n'
               '  proxy_set_header X-H "u=$carrier";\n'
               '} } }\n')
    site = nginx_header_sites(setting, "unit", "set")[0][0]
    if not any(is_credential_variable(n) for n in site["reachable_variables"]):
        failures.append("`set $carrier $http_x_forwarded_access_token` did not taint $carrier.")

    # A `set` bound to a PURE LITERAL is folded into the length: `$carrier` then has a knowable
    # length, and hiding a 51-character token one hop away from the header must not shrink the
    # value's provable lower bound to nothing.
    folded = ('http { server { location /t/ {\n'
              '  set $carrier "sha256~' + "a" * 43 + '";\n'
              '  proxy_set_header X-H "u=$carrier";\n'
              '} } }\n')
    site = nginx_header_sites(folded, "unit", "fold")[0][0]
    if site["literal_length"] < MEASURED_DENIED_MIN:
        failures.append(f"a token-length literal bound one hop away by `set` folded to "
                        f"{site['literal_length']} characters; the LENGTH rule would not see it.")

    # A DIRECTIVE WITH NO TERMINATING `;`, at a closing brace and at end of input. nginx would
    # refuse to start on either, so neither is a shape anyone writes on purpose — but both are one
    # dropped character away from the live line, and the parser must still SEE them. If it discards
    # a pending directive instead, this guard prints "clean" over a config carrying the token in
    # plain sight, which is strictly worse than the malformed config it came from. The same branch
    # is what rescues a value whose closing quote is missing: the tokenizer then runs to EOF inside
    # the quote and the directive never meets a `;` at all.
    for label, conf in (
        ("no-semicolon-before-brace",
         'http { server { location /t/ {\n'
         '  proxy_set_header X-H "u=$http_x_forwarded_access_token"\n'
         '} } }\n'),
        ("no-semicolon-at-eof",
         'proxy_set_header X-H "u=$http_x_forwarded_access_token"\n'),
    ):
        found, _ = nginx_header_sites(conf, "unit", label)
        if not found or "http_x_forwarded_access_token" not in found[0]["direct_variables"]:
            failures.append(f"the nginx parser dropped a proxy_set_header that had no terminating "
                            f"`;` ({label}), so a token sitting in it would never be judged.")

    # `\$` is a literal dollar, not a variable — inventing one there would be a false finding.
    escaped = 'http { server { location /t/ { proxy_set_header X-H "cost \\$5"; } } }\n'
    site = nginx_header_sites(escaped, "unit", "escaped")[0][0]
    if site["direct_variables"] or site["literal_length"] != len("cost $5"):
        failures.append("an escaped `\\$` was read as a variable reference, or its literal length "
                        f"came out as {site['literal_length']} instead of {len('cost $5')}.")

    # The length arithmetic is a LOWER bound: variables removed, literals counted.
    site = nginx_header_sites(
        'http { server { location /t/ { proxy_set_header X-H "u=$a;t="; } } }\n',
        "unit", "length")[0][0]
    if site["literal_length"] != len("u=;t="):
        failures.append(f"literal_length() returned {site['literal_length']} for `u=$a;t=`; the "
                        f"variable-free lower bound is {len('u=;t=')}.")

    # Both credential classifiers, independently. Either one silently becoming the only live
    # mechanism is a narrowing nobody would notice.
    for name in ("http_x_forwarded_access_token", "my_api_key", "downstream_secret", "id_jwt"):
        if not CREDENTIAL_WORD_RE.search(name):
            failures.append(f"CREDENTIAL_WORD_RE stopped matching {name!r}.")
    for name in sorted(CREDENTIAL_VARIABLES):
        if not is_credential_variable(name):
            failures.append(f"the explicitly-listed credential variable {name!r} is not classified "
                            "as one.")
    for name in ("http_x_forwarded_user", "connection_upgrade", "ws_session", "remote_addr"):
        if is_credential_variable(name):
            failures.append(f"{name!r} was classified as credential-bearing; it carries no "
                            "credential and flagging it would make the gate unusable.")

    # The four flag spellings, and the two shapes that must fail closed.
    spellings = {
        "-H X-A": ["ttyd", "-H", "X-A"],
        "-HX-A": ["ttyd", "-HX-A"],
        "--auth-header X-A": ["ttyd", "--auth-header", "X-A"],
        "--auth-header=X-A": ["ttyd", "--auth-header=X-A"],
    }
    for label, tokens in spellings.items():
        got = _auth_header_values(tokens, 0, "unit", 1)
        if got != ["X-A"]:
            failures.append(f"the flag parser read {got} from `{label}`; a spelling it cannot read "
                            "is a cockpit it does not check.")
    for label, tokens in (("trailing -H", ["ttyd", "-W", "-H"]),
                          ("bundled cluster", ["ttyd", "-WH", "X-A"])):
        try:
            _auth_header_values(tokens, 0, "unit", 1)
        except GuardError:
            pass
        else:
            failures.append(f"the flag parser silently accepted the ambiguous {label} form instead "
                            "of failing closed.")

    # A shell COMMENT naming the flag must not become an invocation. The live chart's script carries
    # several, and a regex over the raw text invents a header out of one of them.
    comment = ("              # The wrapper ttyd execs per websocket. TTYD_USER is set by ttyd from "
               "the -H header, so\n")
    found, seen = find_ttyd_invocations(comment, "unit", "comment")
    if found or seen:
        failures.append(f"a shell comment mentioning ttyd and -H produced {len(found)} "
                        f"invocation(s); every runbook paragraph would become a finding.")

    # command/args as a LIST, which a leaf-by-leaf scan cannot correlate.
    listed = string_leaves({"spec": {"containers": [{"command": ["ttyd", "-H", "X-A", "/bin/bash"]}]}})
    if not any("ttyd -H X-A" in text for text, _ in listed):
        failures.append("a `command:` given as a LIST was never joined into an argv line, so a "
                        "container spelling the invocation that way is invisible.")

    return failures


def self_test(root: pathlib.Path) -> int:
    """Prove every detector, on fixtures. A result other than 1 means detection is unproven."""
    chart = _canary_chart(root)
    if not chart.is_dir():
        print("::error::ttyd-auth-header-guard: the canary chart is missing — detection is "
              "unproven, so a clean result on the real tree means nothing.", file=sys.stderr)
        return 2

    failures = _unit_failures()

    # The whole pipeline, over the canary chart: render → split → walk → parse → correlate → judge.
    # Asserted as an EXACT set of (source template, header, rule). A total would not distinguish
    # "the rename case fired" from "the token case fired twice".
    expected = {
        ("broken-token.yaml", "x-ws-session", "TOKEN"),
        ("broken-variants.yaml", "x-cockpit-identity", "TOKEN"),
        ("broken-variants.yaml", "x-set-session", "TOKEN"),
        ("broken-variants.yaml", "x-long-session", "LENGTH"),
        ("broken-variants.yaml", "x-empty-session", "EMPTY"),
    }
    try:
        invocations, sites, counts = collect(root, [chart])
    except GuardError as exc:
        print(f"::error::ttyd-auth-header-guard SELF-TEST FAILED — the canary chart could not be "
              f"collected: {exc}", file=sys.stderr)
        return 2

    findings, blockers, stats = evaluate(invocations, sites)
    if blockers:
        failures.append(f"the canary chart produced unexpected blockers: {blockers}")
    got = {(f["site"]["source"].rsplit("/", 1)[-1], f["site"]["field"].casefold(), f["rule"])
           for f in findings}
    for missing in sorted(expected - got):
        failures.append(f"canary case {missing} was NOT detected — that disarm vector is unproven.")
    for extra in sorted(got - expected):
        failures.append(f"canary case {extra} fired and is not declared. clean.yaml's decoys are "
                        "shapes that MUST stay quiet; a guard that flags them will be switched off.")

    # The clean template must contribute nothing at all — asserted separately from the set above so
    # that a future expectation added by mistake cannot absorb it.
    if any(f["site"]["source"].endswith("clean.yaml") for f in findings):
        failures.append("clean.yaml produced a finding. Its decoys are the emptied non-ttyd token "
                        "header, a token in a header ttyd does not read, a name that merely has "
                        "ttyd's as a prefix, and a map that collapses the token to a 0/1 flag.")

    # Every rule must be exercised by the fixture. A rule with no canary case is a rule nobody has
    # ever seen fire.
    for rule in RULES:
        if not any(f["rule"] == rule for f in findings):
            failures.append(f"no canary case exercises the {rule} rule.")

    # The blocker paths, on fixtures built here rather than in the chart: leaving a `-H` with no
    # header in the canary would make the canary's aggregate result a blocker instead of a set of
    # violations, and the assertion above could no longer be exact.
    orphan_invocations = [{"header": "X-Nothing-Feeds-Me", "source": "fixture", "where": "unit",
                           "line": 1, "command": "ttyd -H X-Nothing-Feeds-Me"}]
    _, orphan_blockers, _ = evaluate(orphan_invocations, [])
    if len(orphan_blockers) != 1:
        failures.append("a ttyd -H naming a header nothing sets did not raise a blocker — the guard "
                        "would silently pass over a cockpit whose value it never found.")

    coverage = coverage_blockers([{"path": "somewhere/else/cockpit.yaml", "line": 9, "header": "X-A"}],
                                 [root / "gitops/workshop-config"], root)
    if len(coverage) != 1:
        failures.append("the coverage lane did not blocker on a ttyd -H outside every rendered "
                        "chart — a cockpit moved out of the charts would go unchecked in silence.")
    if coverage_blockers([{"path": "gitops/workshop-config/templates/x.yaml", "line": 9,
                           "header": "X-A"}], [root / "gitops/workshop-config"], root):
        failures.append("the coverage lane blockered on a file that IS inside a rendered chart.")

    # collect() itself — the production glue. Blinding it to return nothing while still raising its
    # counters is the shape the 2026-08-01 audit found in four guards.
    if len(invocations) != counts["auth-header invocations"]:
        failures.append(f"collect() returned {len(invocations)} invocation(s) but counted "
                        f"{counts['auth-header invocations']}. Scope floors are raised from the "
                        "counters, so a filter applied after counting passes every floor while "
                        "judging nothing.")
    if counts["ttyd invocations"] <= counts["auth-header invocations"]:
        failures.append("collect() did not see MORE ttyd command words than auth-header ones over "
                        "a fixture that plants a ttyd with no -H at all — the per-user cockpit "
                        "shape is not reaching the scanner.")
    if stats["judged"] < len(expected):
        failures.append(f"only {stats['judged']} header value(s) were judged for "
                        f"{len(expected)} expected findings.")

    failures += Scope.self_check()
    tree = scope_for_tree()
    unfloored = [d for d in (*COLLECT_DIMENSIONS, *RAW_DIMENSIONS, *JUDGE_DIMENSIONS)
                 if tree.floor_for(d) is None]
    if unfloored:
        failures.append(f"scope_for_tree() declares no floor for {unfloored} — a dimension that is "
                        "measured but not judged proves nothing.")

    if failures:
        for failure in failures:
            print(f"::error::ttyd-auth-header-guard SELF-TEST FAILED — {failure}", file=sys.stderr)
        return 2

    print(f"self-test ok — {len(expected)} canary cases detected (token after an in-quote `;`, a "
          "renamed and re-cased header, map and set indirection, an over-length literal, an empty "
          "value), clean.yaml's four decoys stayed quiet, both blocker paths fired, all four flag "
          "spellings parse, the two ambiguous ones fail closed, and the scope ledger fails an empty "
          "or truncated input set.")
    return 1


# ------------------------------------------------------------------------------ main


def scope_for_tree() -> Scope:
    """Floors for a real-tree run. Measured 2026-08-16 on gitops/workshop-config with
    showroom.shared.enabled=true: 1 chart, 1 render, 447 documents, 2 ttyd invocations (both with
    -H), 2 nginx configs holding 28 proxy_set_header directives of which 4 name ttyd's header, and
    1 raw manifest file carrying a ttyd -H out of 594 scanned."""
    scope = Scope("ttyd-auth-header-guard")
    scope.require("charts rendered", 1,
                  "gitops/workshop-config is the only chart that ships a cockpit today. Zero means "
                  "discover_charts() stopped matching, not that the cockpit was deleted.")
    scope.require("helm renders", 1, "one render per declared value set.")
    scope.require("rendered documents", 100,
                  "the workshop-config render carries hundreds of documents; a handful means the "
                  "source-split collapsed and most of the chart was never walked.")
    scope.require("ttyd invocations", 2,
                  "the shared cockpit renders twice — the workshop flavor and the SA-demo flavor — "
                  "and each runs one ttyd.")
    scope.require("auth-header invocations", 2,
                  "both of those pass -H. Zero is the shape where this gate judges nothing and "
                  "still prints clean, which is the whole reason the floor exists.")
    scope.require("nginx configs", 2, "one nginx.conf per shared cockpit.")
    scope.require("proxy_set_header directives", 10,
                  "the two configs carry 22 between them. A single-figure count means the nginx "
                  "parser stopped descending into location blocks.")
    scope.require("auth-header values judged", 3,
                  "four proxy_set_header lines name ttyd's header — two tty locations in each of "
                  "the two cockpits. This is the count that proves the CORRELATION ran: invocations "
                  "and sites can both be found in full while nothing is matched up. The floor is 3 "
                  "rather than 2 deliberately, because ONE cockpit on its own yields exactly 2 — if "
                  "the SA-demo flavor is genuinely retired, lower this to 2 in the same change and "
                  "say so.")
    scope.require("raw manifest files scanned", 50,
                  "the coverage lane reads every YAML/TPL under the manifest roots. A tiny number "
                  "means git ls-files or the filter stopped matching, and the lane that notices an "
                  "unrendered cockpit went quiet.")
    scope.require("raw auth-header files", 1,
                  "showroom-shared.yaml carries the only ttyd -H in the tree. If the shared cockpit "
                  "is genuinely retired, lower this floor in the same change and say so — a gate "
                  "with nothing left to guard should be removed, not left printing clean.")
    return scope


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true",
                        help="scan the canary chart instead of the tree; a result other than 1 "
                             "means detection is unproven, not that the tree is fine")
    parser.add_argument("--list-headers", action="store_true",
                        help="print every ttyd -H found and every proxy_set_header that feeds it")
    args = parser.parse_args(argv)

    root = repo_root()

    if args.self_test:
        try:
            return self_test(root)
        except GuardError as exc:
            print(f"::error::ttyd-auth-header-guard self-test could not run: {exc}", file=sys.stderr)
            return 2

    scope = scope_for_tree()
    try:
        charts = discover_charts(root)
        invocations, sites, counts = collect(root, charts)
        scope.merge(counts)
        raw_hits, raw_scanned = raw_auth_header_files(root)
        scope.add("raw manifest files scanned", raw_scanned)
        scope.add("raw auth-header files", len({hit["path"] for hit in raw_hits}))
    except GuardError as exc:
        print(f"::error::ttyd-auth-header-guard: {exc}", file=sys.stderr)
        return 2

    findings, blockers, stats = evaluate(invocations, sites)
    scope.add("auth-header values judged", stats["judged"])
    blockers += coverage_blockers(raw_hits, charts, root)

    if args.list_headers:
        for invocation in invocations:
            print(f"-H {invocation['header']}  <- {invocation['source']} "
                  f"{invocation['where']} line {invocation['line']}")
        for site in sites:
            if site["field"].casefold() in stats["headers"]:
                # The document, not just source+line — one template renders two cockpits whose
                # nginx.conf is identical, so without it these read as the same line printed twice.
                print(f"   feeds  {site['field']} = {site['printable']!r}  "
                      f"[{site['literal_length']} literal chars] {site['source']} line "
                      f"{site['line']} — {site['where']}")
        return 0

    # BLOCKERS FIRST, THEN SCOPE — and both are printed rather than the first one winning.
    # Measured while testing this guard: renaming ttyd's `-H` without renaming the nginx field
    # produces BOTH a blocker ("nothing sets X-Cockpit-Identity") and a scope collapse ("0 values
    # judged"), because the collapse is the blocker's consequence. Enforcing scope first printed only
    # the collapse, which says the guard is broken when what actually happened is that the chart is.
    # A collapse with NO blocker is still a separate failure, so scope is enforced either way.
    if blockers:
        print("\n::error::ttyd-auth-header-guard cannot judge every ttyd auth header:",
              file=sys.stderr)
        for blocker in blockers:
            print(f"  {blocker}", file=sys.stderr)
    collapsed = scope.enforce()
    if blockers or collapsed:
        return 2

    if findings:
        print("\nValues fed into the header ttyd reads:")
        for finding in findings:
            site = finding["site"]
            invocation = finding["invocation"]
            borrowed = ("\n      (matched across templates — no proxy_set_header for this field in "
                        f"{invocation['source']})" if finding["borrowed"] else "")
            # The document is printed, not just source+line: one template renders the shared cockpit
            # twice (workshop flavor and SA-demo flavor) into byte-identical nginx.conf ConfigMaps,
            # so four real findings would otherwise read as two printed twice.
            print(f"  [{finding['rule']}] {site['source']} line {site['line']}\n"
                  f"      in       {site['where']}\n"
                  f"      {site['field']} = {site['printable']!r}\n"
                  f"      read by  {invocation['command']}\n"
                  f"               {invocation['where']} "
                  f"({invocation['source']} line {invocation['line']}){borrowed}\n"
                  f"      problem  this value {finding['detail']}\n"
                  f"      fix      {finding['fix']}")
        sys.stdout.flush()
        print(f"\n::error::{len(findings)} value(s) feeding a ttyd -H header would kill the "
              "terminal for every attendee. ttyd reports a refused header and an absent one "
              "identically — one closed socket, one 'reconnecting' — so this fails silently and "
              "takes an evening to find. Measured 2026-08-16.", file=sys.stderr)
        return 1

    print(f"ttyd-auth-header-guard: clean — {scope.summary()}.")
    for value, literal in sorted({(s["printable"], s["literal_length"]) for s in sites
                                  if s["field"].casefold() in stats["headers"]}):
        budget = MEASURED_ACCEPTED_MAX - literal
        print(f"  {value!r}: {literal} literal characters, so every variable in it must expand to "
              f"{budget} characters or fewer to stay inside the longest value measured accepted "
              f"({MEASURED_ACCEPTED_MAX}). That is a budget this guard CANNOT enforce — a username's "
              "length is a property of the cluster's identity provider.")
    return 0


if __name__ == "__main__":
    # Any unhandled exception exits 1, and 1 is this guard's "the canary was detected" / "the tree
    # has a finding" code. A crash must never be readable as either, so it is remapped to 2.
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException as exc:                                  # noqa: BLE001 — deliberate
        import traceback
        traceback.print_exc()
        print(f"::error::ttyd-auth-header-guard: crashed ({type(exc).__name__}: {exc}). "
              f"Exiting 2 — a crash is 'the guard could not run', never 'clean' and never "
              f"'canary detected'.", file=sys.stderr)
        sys.exit(2)
