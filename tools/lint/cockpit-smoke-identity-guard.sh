#!/usr/bin/env bash
# cockpit-smoke-identity-guard.sh — the smoke gate must run in the REAL cockpit terminal, as the attendee.
#
# ORIGIN (SEV2-G, 2026-08-06). The cockpit smoke is the only gate that touches the surface attendees
# actually touch: the ttyd terminal inside showroom-<user>, logged in as <user>. A smoke that runs
# `ws` from a maintainer laptop against a cluster-admin kubeconfig proves nothing about it, and when
# one did, three defect classes walked past it into the owner's first live session:
#
#   • `ws` was not on the terminal's interactive PATH — measured again 2026-08-06 on user5's live
#     cockpit: `bash -ic` finds /home/lab-user/ocp-getting-started/tools/ws/ws, a NON-interactive
#     `bash -c` in the same container finds nothing, and a maintainer shell finds its own checkout.
#   • the terminal answered as the showroom ServiceAccount, not as the attendee. From a laptop
#     `oc whoami` says `admin` and the mismatch is unobservable.
#   • peer namespaces were listable by an attendee who should only ever see their own — an admin
#     shell can list every namespace on the cluster, so the isolation check silently inverts.
#
# Every one of those is invisible from an admin shell by construction: it has ws on PATH,
# cluster-admin rights, and a different HOME. Only the attendee's own terminal can answer them.
#
# WHAT THIS GUARD CAN AND CANNOT PROVE — read this before quoting a green run as evidence.
# CI has no cluster, no cockpit and no attendee, so it cannot smoke anything. The real proof is
# `tools/ws/ws smoke <module> <userN>` against a live cockpit; THIS guard is strictly weaker and a
# green run of it is NOT a smoke pass. What CI can hold is the CONTRACT — that the gate still drives
# the attendee's real terminal rather than the host shell — so the regression that produced SEV2-G
# cannot land unnoticed between on-cluster runs. Keep the two claims apart in any report.
#
# WHY `bash -ic` AND NOT `bash -c` / `bash -lc`. The cockpit exports the workshop PATH from the
# terminal's ~/.bashrc, and the stock skel .bashrc early-returns for a non-interactive shell — so a
# bare `oc exec … -- bash -c 'ws …'` reports "ws: command not found" on a perfectly healthy cockpit
# (a test artifact), while `bash -lc` sources the login files instead and misses the same block.
# Only an INTERACTIVE shell reproduces what the attendee types into ttyd.
#
# WHY `-c <container>`. The cockpit pod runs three containers (nginx, content, terminal). Without an
# explicit selector `oc exec` takes the FIRST one — verified live 2026-08-06: it lands in nginx,
# where there is no ws and no attendee kubeconfig, and the gate grades a container no attendee ever
# sees.
#
# THE MACHINE IS ONLY HALF THE GATE (SEV2-G's G4 half, 2026-08-06). `ws smoke` driving the cockpit
# is necessary and not sufficient: the smoke and milestone gates are run by an AUDITOR following a
# written procedure, and the original defect was in the PROCEDURE, not the tool — the auditor ran the
# lab from whatever shell launched it. Checks [1]–[3] pin the tool; check [4] pins the procedures, so
# a milestone verdict cannot quietly go back to being earned in a maintainer shell.
#
# Check [4] has a hole this guard states rather than hides: the procedures live under `.claude/`,
# which is gitignored maintainer-local material (owner directive 2026-07-19) and therefore absent
# from every CI checkout. So CI runs [4]'s CANARIES — proving each rule's detector is not blind,
# against tracked fixtures — but cannot apply [4] to the real procedures; it prints ➖ NOT INSPECTED
# and the success line changes to say the run covers tools/ws/ws only. On that half a maintainer's
# local run is the whole gate. Do not report a green CI run as procedure coverage.
#
# Checks (each one a canary in --self-test):
#   [1] tools/ws/ws defines an exec helper that reaches the cockpit through an INTERACTIVE shell
#       (`oc exec … -c <container> -- bash -ic`), the container is the ttyd terminal, and no cockpit
#       exec uses a login shell.
#   [2] cmd_smoke DRIVES the attendee path through that helper: `ws prep`, `ws verify` and the
#       identity assertion (`oc whoami`) all travel into the pod, and the helper is what the gate
#       actually runs on.
#   [3] cmd_smoke never falls back to the host: no local cmd_prep/cmd_verify/verify-script call, and
#       no attendee entrypoint smuggled through the NON-interactive helper.
#   [4] every gate PROCEDURE on the roster still binds its auditor to that terminal — the interactive
#       exec form with its container selector, the `oc whoami` identity proof, the `ws smoke` anchor,
#       the impersonation flags for negative examples, and an identity statement in the report — and
#       no procedure that drives a cockpit is missing from the roster.
#
# Exit codes:
#   0  contract holds
#   1  contract broken — or, under --self-test, every canary was correctly detected
#   2  the guard could not inspect what it claims to inspect (file missing, extraction failed,
#      roster malformed)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tools/lint/_extract-func.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_extract-func.sh"
# shellcheck source=tools/lint/_check-coverage.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_check-coverage.sh"
# shellcheck source=tools/lint/_parse-guard-args.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_parse-guard-args.sh"

ok()   { echo "✅ $*"; }
bad()  { echo "❌ $*" >&2; }
note() { echo "   $*"; }

WS="tools/ws/ws"
FUNC="cmd_smoke"
# Where the gate procedures live. Gitignored maintainer-local material: present in a maintainer's
# working copy, absent from every CI checkout. Check [4] handles both, loudly.
AGENT_DIR=".claude/agents"
# Set by check [4] so the closing banner can never claim more coverage than the run achieved.
PROCEDURE_ARM="not-run"
# The attendee entrypoints. Each one MUST be typed into the attendee's own terminal to mean anything:
# `ws prep` exercises materialization under the attendee's RBAC, `ws verify` grades the entry state
# with the attendee's reads, and `oc whoami` is the identity assertion itself.
ENTRYPOINTS=('ws prep' 'ws verify' 'oc whoami')

# Helper names are DISCOVERED, never hardcoded: a rename must not silently switch this guard off.
# An interactive cockpit exec is the only shape that reproduces ttyd.
interactive_helpers() {  # root → helper names, one per line
  grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{[^#]*oc exec[^#]*bash[[:space:]]+-ic' \
    "${1}/${WS}" 2>/dev/null | sed -E 's/\(\).*//' | sort -u
}
# The non-interactive twin is legitimate — clean captures (a git HEAD) must not have the MOTD spliced
# into them — but it is NOT the attendee's shell and must never carry an entrypoint.
noninteractive_helpers() {  # root → helper names, one per line
  grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{[^#]*oc exec[^#]*bash[[:space:]]+-c[[:space:]]' \
    "${1}/${WS}" 2>/dev/null | sed -E 's/\(\).*//' | sort -u
}
# newline-separated names → an ERE alternation. Used with a leading [^A-Za-z0-9_] so a longer
# identifier that merely ENDS in a helper's name cannot count as a call.
alternation() { tr '\n' '|' | sed -E 's/\|+$//'; }

# ── [1] the exec helper reaches the real terminal ─────────────────────────────
check_interactive_exec_helper() {  # root → 0 clean, 1 broken, 2 uninspectable
  ran_check
  local root="$1" names rc=0
  if [[ ! -f "${root}/${WS}" ]]; then
    bad "[1] ${WS} not found under ${root} — nothing to inspect."
    return 2
  fi

  names="$(interactive_helpers "$root")"
  if [[ -z "$names" ]]; then
    bad "[1] no helper in ${WS} execs the cockpit through an INTERACTIVE shell (oc exec … -- bash -ic)."
    note "    Without one the gate cannot be running what the attendee types: a non-interactive"
    note "    shell skips the terminal's ~/.bashrc, so 'ws' is not on PATH and the gate reports a"
    note "    healthy cockpit as broken — or, worse, the run moved back to the maintainer's shell,"
    note "    which is the SEV2-G defect verbatim."
    rc=1
  else
    ok "[1] cockpit exec helper(s): $(printf '%s' "$names" | tr '\n' ' ')— oc exec … -- bash -ic"
  fi

  if [[ -n "$names" ]] && ! grep -qE '^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{[^#]*oc exec[^#]*[[:space:]]-c[[:space:]][^#]*bash[[:space:]]+-ic' "${root}/${WS}"; then
    bad "[1] the interactive exec helper does not select a container (-c <container>)."
    note "    The cockpit pod runs nginx + content + terminal; with no selector oc exec takes the"
    note "    FIRST container, which has neither ws nor the attendee's kubeconfig."
    rc=1
  fi

  if ! grep -qE "^SMOKE_CONTAINER=[\"']?terminal[\"']?[[:space:]]*(#.*)?$" "${root}/${WS}"; then
    bad "[1] SMOKE_CONTAINER is not the ttyd 'terminal' container."
    note "    Grading any other container grades an image the attendee never types into."
    rc=1
  fi

  if grep -qE 'oc exec[^#]*bash[[:space:]]+-lc' "${root}/${WS}"; then
    bad "[1] a cockpit exec uses a LOGIN shell (bash -lc)."
    note "    The terminal's PATH is exported from ~/.bashrc, which a login shell does not source;"
    note "    -lc reintroduces the ws-not-found false failure that -ic exists to avoid."
    rc=1
  fi
  return "$rc"
}

# ── [2] the smoke drives the attendee path through it ─────────────────────────
check_smoke_drives_cockpit() {  # root → 0 clean, 1 broken, 2 uninspectable
  ran_check
  local root="$1" body names alt uses ep rc=0
  if [[ ! -f "${root}/${WS}" ]]; then
    bad "[2] ${WS} not found under ${root} — nothing to inspect."
    return 2
  fi
  body="$(extract_func "${root}/${WS}" "$FUNC")"
  if [[ -z "$body" ]]; then
    bad "[2] could not extract ${FUNC}() from ${WS} — the gate may have been renamed or removed."
    return 2
  fi
  names="$(interactive_helpers "$root")"
  if [[ -z "$names" ]]; then
    bad "[2] no interactive exec helper exists to drive the smoke through — see [1]."
    return 2
  fi
  alt="$(printf '%s\n' "$names" | alternation)"

  uses="$(printf '%s\n' "$body" | grep -cE "^[^#]*[^A-Za-z0-9_](${alt})[[:space:]]")"
  if [[ "$uses" -lt 3 ]]; then
    bad "[2] ${FUNC}() calls the cockpit exec helper only ${uses} time(s) — it is not what the gate runs on."
    rc=1
  else
    ok "[2] ${FUNC}() runs ${uses} checks inside the attendee's terminal"
  fi

  for ep in "${ENTRYPOINTS[@]}"; do
    if ! printf '%s\n' "$body" | grep -qE "^[^#]*[^A-Za-z0-9_](${alt})[[:space:]].*${ep}"; then
      bad "[2] '${ep}' is not driven through the cockpit exec helper in ${FUNC}()."
      note "    Run from the host it answers as the maintainer: ws is the checkout's, oc is"
      note "    cluster-admin, HOME is the laptop's. That is a different world from the attendee's."
      rc=1
    fi
  done
  [[ "$rc" -ne 0 ]] || ok "[2] ws prep · ws verify · oc whoami all execute as the attendee"
  return "$rc"
}

# ── [3] no host-side fallback ─────────────────────────────────────────────────
check_no_hostside_entrypoints() {  # root → 0 clean, 1 broken, 2 uninspectable
  ran_check
  local root="$1" body hits nonint alt ep rc=0
  if [[ ! -f "${root}/${WS}" ]]; then
    bad "[3] ${WS} not found under ${root} — nothing to inspect."
    return 2
  fi
  body="$(extract_func "${root}/${WS}" "$FUNC")"
  if [[ -z "$body" ]]; then
    bad "[3] could not extract ${FUNC}() from ${WS}."
    return 2
  fi

  # (a) the local verbs and the module's own verify script. `source "${VERIFY_DIR}/_lib.sh"` is fine
  # and deliberately not matched: the gate borrows the ✅/❌ idiom, it does not run a check locally.
  # shellcheck disable=SC2016  # an ERE, not a string: "\$script" must reach grep as literal text
  hits="$(printf '%s\n' "$body" | grep -nE '^[^#]*([^A-Za-z0-9_]|^)(cmd_prep|cmd_verify)[[:space:]]|^[^#]*"\$script"')"
  if [[ -n "$hits" ]]; then
    bad "[3] ${FUNC}() runs an attendee entrypoint on the HOST:"
    printf '%s\n' "$hits" | sed 's/^/       /' >&2
    note "    That is the SEV2-G defect: the gate grades the maintainer's shell and reports it as"
    note "    the attendee's. Route it through the cockpit exec helper instead."
    rc=1
  fi

  # (b) an entrypoint smuggled through the non-interactive helper — same pod, wrong shell.
  nonint="$(noninteractive_helpers "$root")"
  if [[ -n "$nonint" ]]; then
    alt="$(printf '%s\n' "$nonint" | alternation)"
    for ep in "${ENTRYPOINTS[@]}"; do
      hits="$(printf '%s\n' "$body" | grep -nE "^[^#]*[^A-Za-z0-9_](${alt})[[:space:]].*${ep}")"
      if [[ -n "$hits" ]]; then
        bad "[3] '${ep}' runs through the NON-interactive exec helper (no ~/.bashrc, so no ws on PATH):"
        printf '%s\n' "$hits" | sed 's/^/       /' >&2
        rc=1
      fi
    done
  fi

  [[ "$rc" -ne 0 ]] || ok "[3] no host-side or non-interactive fallback in ${FUNC}()"
  return "$rc"
}

# ── [4] the gate PROCEDURES still bind their auditor to that terminal ─────────
# ROSTER. Not a declared-debt ledger (nothing here suppresses a red signal — see tools/lint/
# LEDGERS.md for that convention), but it carries the same two-directional ratchet, for the same
# reason: a roster that can be satisfied by deleting the thing it names is not a gate.
#   forward  — a rostered procedure that is missing, or that dropped one of its rules, FAILS.
#   backward — a procedure that drives a cockpit (mentions `showroom` and `oc exec`) and is NOT on
#              the roster FAILS. A new gate cannot be written outside the contract by being new.
# Format:  <file>.md <Gn> :: <rule> <rule> …
# The rule sets differ ON PURPOSE. G3 smokes one module inside the cockpit and never impersonates;
# G4 samples capability claims across a wave (so it needs the impersonation flags) and drives
# browsers for console/UI work (so it needs the ttyd/Enter warning). Copying G4's list onto G3 would
# fail a procedure for not doing something it has no business doing.
gate_procedures() {
  cat <<'ROSTER'
sa-tester.md G4 :: cockpit-exec cockpit-container identity-proof ws-smoke impersonation negative-example identity-ledger no-browser-terminal
sa-smoke-tester.md G3 :: cockpit-exec cockpit-container identity-proof ws-smoke negative-example identity-ledger
ROSTER
}
RULE_VOCAB="cockpit-exec cockpit-container identity-proof ws-smoke impersonation negative-example identity-ledger no-browser-terminal"

rule_why() {  # rule → the sentence a reader who has never seen this file needs
  case "$1" in
    cockpit-exec)        echo "no interactive cockpit exec (oc exec … -- bash -ic), or one that uses a login/non-interactive shell. That is the SEV2-G defect: the lab gets walked in the auditor's own shell." ;;
    cockpit-container)   echo "the exec form has no '-c terminal' selector — oc exec then takes the FIRST container (nginx), which has neither ws nor the attendee's kubeconfig." ;;
    identity-proof)      echo "no 'oc whoami' inside the cockpit exec — nothing makes the auditor prove the terminal answers as the attendee before collecting results." ;;
    ws-smoke)            echo "the procedure is not anchored to 'ws smoke' — the one mechanical check that drives the attendee terminal and fails closed." ;;
    impersonation)       echo "capability claims are not pinned to '--as=… --as-group=…' — attendee rights hang off the group, so --as alone fabricates blockers." ;;
    negative-example)    echo "no rule for deliberate negative examples. Run as admin they SUCCEED: the lesson evaporates and the mutation actually lands." ;;
    identity-ledger)     echo "the report is not required to state the identity each step ran under — an unstated admin step is how a wave passes a gate and fails the room." ;;
    no-browser-terminal) echo "no warning that a browser pane cannot deliver Enter to the ttyd terminal — the command sits unexecuted and the screenshot reads as if it ran." ;;
    *)                   echo "unknown rule." ;;
  esac
}

# The unit a rule matches inside: a line of a fenced block, or one inline `code` span. Prose is
# excluded on purpose — both procedures must be free to WRITE about `bash -lc` in order to forbid it,
# and a line-based scan reads that sentence as a violation (measured: sa-smoke-tester.md's line 18
# carries `oc exec` and `bash -c` in separate spans of one sentence).
command_units() {  # file → one unit per line
  awk '
    /^[[:space:]]*```/ { fence = 1 - fence; next }
    fence             { print; next }
    {
      line = $0
      while (match(line, /`[^`]+`/)) {
        print substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$1"
}

rule_holds() {  # rule file → 0 holds, 1 does not
  local rule="$1" f="$2" units
  units="$(command_units "$f")"
  case "$rule" in
    cockpit-exec)
      grep -qE 'oc exec.*bash[[:space:]]+-ic([^A-Za-z0-9_-]|$)' <<< "$units" || return 1
      # -l?c matches `-c` and `-lc` and NOT `-ic`: the two shells that skip the terminal's ~/.bashrc.
      ! grep -qE 'oc exec.*bash[[:space:]]+-l?c([^A-Za-z0-9_-]|$)' <<< "$units" || return 1
      ;;
    cockpit-container)   grep -qE 'oc exec.*[[:space:]]-c[[:space:]]+terminal' <<< "$units" || return 1 ;;
    identity-proof)      grep -qE '(oc exec|bash[[:space:]]+-ic).*oc whoami' <<< "$units" || return 1 ;;
    ws-smoke)            grep -qE '(^|[^A-Za-z0-9_-])ws smoke([^A-Za-z0-9_-]|$)' "$f" >/dev/null || return 1 ;;
    impersonation)       grep -qF -- '--as=' "$f" && grep -qF -- '--as-group=' "$f" || return 1 ;;
    negative-example)    grep -qiE 'negative example' "$f" || return 1 ;;
    identity-ledger)     grep -qiE 'identity ledger|identity every step ran under' "$f" || return 1 ;;
    # Same LINE, both tokens: you cannot state this rule without naming the terminal and the key.
    no-browser-terminal) grep -E 'ttyd' "$f" | grep -qE '(^|[^A-Za-z])Enter([^A-Za-z]|$)' || return 1 ;;
    *) return 1 ;;
  esac
  return 0
}

# A roster this guard cannot parse declares nothing, and a gate that silently declares nothing
# reports a broken procedure as a clean one. Linted BEFORE anything is read, and it costs rc 2 (could
# not inspect), never rc 1 (a procedure is broken) — CI asserts --self-test exits exactly 1, so a
# malformed roster reporting 1 would satisfy that assertion while checking nothing.
roster_lint() {  # <roster text> → prints problems, 0 clean / 1 malformed
  local text="$1" line key rules file gate rule bad_n=0
  while IFS= read -r line; do
    [[ -n "${line// /}" ]] || continue
    if [[ "$line" != *" :: "* ]]; then
      echo "no ' :: ' separating the key from the rule list: ${line}"; bad_n=1; continue
    fi
    key="${line%% :: *}"; rules="${line#* :: }"
    file="${key%% *}"; gate="${key##* }"
    if [[ "$key" != "${file} ${gate}" ]]; then
      echo "key must be exactly '<file>.md <Gn>': ${key}"; bad_n=1; continue
    fi
    [[ "$file" == *.md ]]      || { echo "first key field is not a markdown procedure: ${file}"; bad_n=1; }
    [[ "$gate" =~ ^G[0-9]$ ]]  || { echo "second key field is not a gate id G0–G9: ${gate}"; bad_n=1; }
    [[ -n "${rules// /}" ]]    || { echo "no rules declared for ${file} — the entry asserts nothing"; bad_n=1; }
    # Deliberate word splitting: the rule list is space-separated by format.
    # shellcheck disable=SC2086
    for rule in $rules; do
      case " ${RULE_VOCAB} " in
        *" ${rule} "*) ;;
        *) echo "unknown rule '${rule}' for ${file} — vocabulary is: ${RULE_VOCAB}"; bad_n=1 ;;
      esac
    done
  done <<< "$text"
  return "$bad_n"
}

check_gate_procedures_drive_cockpit() {  # root → 0 clean (or not inspectable HERE), 1 broken, 2 roster malformed
  ran_check
  local root="$1" rc=0 problems line key rules file gate rule f base dir
  # Separate statement, deliberately: `local a="$1" b="${a}/x"` expands every word BEFORE the builtin
  # assigns any of them, so b would resolve through the CALLER's scope — right by accident when
  # run_check calls this (it has its own `root`), unbound the moment a canary calls it directly.
  dir="${root}/${AGENT_DIR}"
  if problems="$(roster_lint "$(gate_procedures)")"; then :; else
    bad "[4] this guard's gate-procedure roster is malformed — it declares nothing:"
    printf '%s\n' "$problems" | sed 's/^/       /' >&2
    return 2
  fi

  if [[ ! -d "$dir" ]]; then
    PROCEDURE_ARM="skipped"
    note "➖ [4] gate procedures NOT INSPECTED — ${AGENT_DIR}/ is maintainer-local (gitignored) and is"
    note "      not in this checkout. This run covers ${WS} ONLY and says nothing about whether the"
    note "      G3/G4 procedures still drive the attendee's terminal. Run this guard on a maintainer"
    note "      machine to close that half; a green run here is not procedure coverage."
    return 0
  fi
  PROCEDURE_ARM="ran"

  # forward ratchet — every rostered procedure is present and still carries its rules
  while IFS= read -r line; do
    [[ -n "${line// /}" ]] || continue
    key="${line%% :: *}"; rules="${line#* :: }"
    file="${key%% *}"; gate="${key##* }"
    if [[ ! -f "${dir}/${file}" ]]; then
      bad "[4] ${gate}: ${AGENT_DIR}/${file} is on the roster but not in the tree."
      note "    A gate whose procedure vanished did not get simpler — it stopped being held to a"
      note "    contract. Restore it, or take it off the roster as a deliberate decision."
      rc=1; continue
    fi
    # shellcheck disable=SC2086  # space-separated by format, as above
    for rule in $rules; do
      if ! rule_holds "$rule" "${dir}/${file}"; then
        bad "[4] ${gate} (${file}): rule '${rule}' no longer holds — $(rule_why "$rule")"
        rc=1
      fi
    done
  done < <(gate_procedures)

  # backward ratchet — anything that drives a cockpit must be on the roster. The trigger is what the
  # file DOES (showroom + oc exec), not what its description calls itself: content-editor.md's
  # description says "(gate G2)" and has no business in the cockpit, so a gate-id trigger over-fires.
  for f in "${dir}"/*.md; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f")"
    grep -q 'showroom' "$f" || continue
    grep -q 'oc exec'  "$f" || continue
    if ! gate_procedures | grep -qE "^${base}[[:space:]]"; then
      bad "[4] ${base} drives an attendee cockpit but is not on this guard's roster."
      note "    Add it with the rule set its gate owes, or it is a procedure nobody checks — which is"
      note "    how the first one drifted back into the maintainer's shell."
      rc=1
    fi
  done

  [[ "$rc" -ne 0 ]] || ok "[4] $(gate_procedures | grep -c ' :: ') gate procedure(s) still bind the auditor to the attendee's terminal"
  return "$rc"
}

run_check() {  # root → 0 clean, 1 broken, 2 uninspectable
  coverage_reset
  PROCEDURE_ARM="not-run"
  local root="$1" rc=0 sub=0
  check_interactive_exec_helper "$root" || sub=$?
  if [[ "$sub" -eq 2 ]]; then return 2; fi
  if [[ "$sub" -ne 0 ]]; then rc=1; fi

  sub=0; check_smoke_drives_cockpit "$root" || sub=$?
  if [[ "$sub" -eq 2 ]]; then return 2; fi
  if [[ "$sub" -ne 0 ]]; then rc=1; fi

  sub=0; check_no_hostside_entrypoints "$root" || sub=$?
  if [[ "$sub" -eq 2 ]]; then return 2; fi
  if [[ "$sub" -ne 0 ]]; then rc=1; fi

  sub=0; check_gate_procedures_drive_cockpit "$root" || sub=$?
  if [[ "$sub" -eq 2 ]]; then return 2; fi
  if [[ "$sub" -ne 0 ]]; then rc=1; fi

  # Nothing above proves run_check still CALLS what this guard declares — a deleted call site leaves
  # every canary passing and the real run reporting clean (see _check-coverage.sh).
  if [[ "$rc" -ne 2 ]]; then assert_all_checks_ran || rc=2; fi
  return "$rc"
}

# ── self-test ─────────────────────────────────────────────────────────────────
# Canaries are MUTATIONS OF THE REAL FILE, not a synthetic stand-in: each one is a single edit of the
# shape a refactor would actually make, so a canary that stops reproducing is itself a signal.
mutate_ws() {  # tmp sed-expr… → writes tmp/tools/ws/ws, echoes its root
  local tmp="$1"; shift
  mkdir -p "${tmp}/tools/ws"
  local args=() e
  for e in "$@"; do args+=(-e "$e"); done
  sed "${args[@]}" "${REPO_ROOT}/${WS}" > "${tmp}/${WS}"
  printf '%s' "$tmp"
}

# Check [4]'s canaries cannot mutate the real procedures the way mutate_ws mutates the real ws: the
# procedures are maintainer-local and CI has none, so a canary built from them would silently stop
# running there — the guard would ship with its [4] detectors unproven on the only machine that runs
# it automatically. They are built from TRACKED fixtures instead, one well-formed procedure per gate.
FIXTURES="${REPO_ROOT}/tools/lint/cockpit-smoke-identity-guard.fixtures/agents"
stage_agents() {  # tmp [sed-expr…] → writes tmp/.claude/agents/*.md (exprs apply to sa-tester.md only)
  local tmp="$1"; shift
  rm -rf "${tmp:?}/.claude"
  mkdir -p "${tmp}/${AGENT_DIR}"
  cp "${FIXTURES}"/*.md "${tmp}/${AGENT_DIR}/"
  if [[ "$#" -gt 0 ]]; then
    local args=() e
    for e in "$@"; do args+=(-e "$e"); done
    sed "${args[@]}" "${FIXTURES}/sa-tester.md" > "${tmp}/${AGENT_DIR}/sa-tester.md"
  fi
}

self_test() {
  local tmp real_rc rc
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  # Proof 0: the real tree passes. A detector that fires on everything proves nothing either.
  real_rc=0
  run_check "$REPO_ROOT" >/dev/null 2>&1 || real_rc=$?
  if [[ "$real_rc" -ne 0 ]]; then
    bad "SELF-TEST FAILED: the real tree does not satisfy the contract (rc=${real_rc}). Run without --self-test."
    return 2
  fi

  # Canary A — the exec drops to a non-interactive shell. Reproduces the "ws: command not found on a
  # healthy cockpit" artifact measured live on user5.
  rm -rf "${tmp:?}/tools"; mutate_ws "$tmp" 's/bash -ic/bash -c/' >/dev/null
  rc=0; check_interactive_exec_helper "$tmp" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 1 ]]; then
    bad "SELF-TEST FAILED: a non-interactive cockpit exec was NOT detected (rc=${rc}) — detector [1] is blind."
    return 2
  fi

  # Canary B — a login shell instead of an interactive one.
  rm -rf "${tmp:?}/tools"; mutate_ws "$tmp" 's/bash -ic/bash -lc/' >/dev/null
  rc=0; check_interactive_exec_helper "$tmp" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 1 ]]; then
    bad "SELF-TEST FAILED: 'bash -lc' was NOT detected (rc=${rc}) — detector [1] is blind to login shells."
    return 2
  fi

  # Canary C — the container selector goes away and the exec lands in nginx.
  rm -rf "${tmp:?}/tools"
  # shellcheck disable=SC2016  # a sed script: $SMOKE_CONTAINER is the text being deleted from ws
  mutate_ws "$tmp" 's/ -c "\$SMOKE_CONTAINER"//' >/dev/null
  rc=0; check_interactive_exec_helper "$tmp" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 1 ]]; then
    bad "SELF-TEST FAILED: a missing -c <container> was NOT detected (rc=${rc}) — detector [1] is blind."
    return 2
  fi

  # Canary D — the SEV2-G shape itself: `ws prep` stops travelling into the pod.
  rm -rf "${tmp:?}/tools"; mutate_ws "$tmp" 's/pod_i "ws prep/run_local "ws prep/' >/dev/null
  if ! grep -q 'run_local "ws prep' "${tmp}/${WS}"; then
    bad "SELF-TEST FAILED: could not build the host-side-prep canary — the pod_i call it mutates was not found."
    return 2
  fi
  rc=0; check_smoke_drives_cockpit "$tmp" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 1 ]]; then
    bad "SELF-TEST FAILED: 'ws prep' leaving the cockpit was NOT detected (rc=${rc}) — detector [2] is blind."
    return 2
  fi

  # Canary E — a local verify verb called from inside the gate.
  rm -rf "${tmp:?}/tools"; mutate_ws "$tmp" "s/^cmd_smoke() {/cmd_smoke() {\n  cmd_verify \"\$user\" \"\$module\"/" >/dev/null
  # shellcheck disable=SC2016  # searching for the literal text the canary just wrote into the copy
  if ! grep -q 'cmd_verify "\$user" "\$module"' "${tmp}/${WS}"; then
    bad "SELF-TEST FAILED: could not build the host-side-verify canary — ${FUNC}()'s opening line was not found."
    return 2
  fi
  rc=0; check_no_hostside_entrypoints "$tmp" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 1 ]]; then
    bad "SELF-TEST FAILED: a host-side cmd_verify call was NOT detected (rc=${rc}) — detector [3] is blind."
    return 2
  fi

  # Canary F — the file is not there at all. Must be "could not inspect" (2), never a clean 0.
  rm -rf "${tmp:?}/tools"
  rc=0; run_check "$tmp" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 2 ]]; then
    bad "SELF-TEST FAILED: a missing ${WS} reported rc=${rc}, not 2 — the guard would pass on nothing."
    return 2
  fi

  # ── check [4]: the gate PROCEDURES ────────────────────────────────────────────────────────────
  if [[ ! -f "${FIXTURES}/sa-tester.md" || ! -f "${FIXTURES}/sa-smoke-tester.md" ]]; then
    bad "SELF-TEST FAILED: the procedure fixtures are missing under ${FIXTURES} — [4]'s detectors cannot be proven."
    return 2
  fi

  # Canary G — the over-fire control, and it comes first: a detector that fires on everything proves
  # nothing, and every case below is only meaningful against a control that stays quiet.
  local out
  stage_agents "$tmp"
  rc=0; out="$(check_gate_procedures_drive_cockpit "$tmp" 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    bad "SELF-TEST FAILED: two well-formed procedure fixtures were reported broken (rc=${rc}) — [4] cries wolf:"
    printf '%s\n' "$out" | sed 's/^/       /' >&2
    return 2
  fi

  # Canary H — one case PER RULE. Each mutation removes exactly one rule's evidence, and the case
  # asserts both halves: the guard names THAT rule, and names no OTHER. Exit code alone would pass
  # even if a single blunt detector were firing for all eight reasons at once (the shape the
  # canary-coverage audit found in fifteen detectors that had been green in CI the whole time).
  local mrule mexpr other
  while IFS='|' read -r mrule mexpr; do
    [[ -n "$mrule" ]] || continue
    stage_agents "$tmp" "$mexpr"
    rc=0; out="$(check_gate_procedures_drive_cockpit "$tmp" 2>&1)" || rc=$?
    if [[ "$rc" -ne 1 ]]; then
      bad "SELF-TEST FAILED: rule '${mrule}' removed from a procedure was NOT detected (rc=${rc}) — its detector is blind."
      note "    mutation: sed '${mexpr}'"
      return 2
    fi
    if ! grep -qF -- "'${mrule}'" <<< "$out"; then
      bad "SELF-TEST FAILED: rule '${mrule}' was broken and the guard reported something else:"
      printf '%s\n' "$out" | sed 's/^/       /' >&2
      return 2
    fi
    # shellcheck disable=SC2086  # RULE_VOCAB is space-separated by format
    for other in $RULE_VOCAB; do
      [[ "$other" != "$mrule" ]] || continue
      if grep -qF -- "'${other}'" <<< "$out"; then
        bad "SELF-TEST FAILED: breaking '${mrule}' also reported '${other}' — the mutation is not single-variable, or a detector over-fires:"
        printf '%s\n' "$out" | sed 's/^/       /' >&2
        return 2
      fi
    done
  done <<'CASES'
cockpit-exec|s/bash -ic/bash -lc/g
cockpit-container|s/ -c terminal//g
identity-proof|s/oc whoami; //
ws-smoke|s/ws smoke/ws inspect/g
impersonation|s/--as-group=/--asgroup=/g
negative-example|s/negative example/counter-example/g
identity-ledger|s/identity ledger/identity list/g
no-browser-terminal|s/ttyd/web/g
CASES

  # Canary I — ratchet forward: a rostered procedure that is simply GONE. Deleting the file must not
  # be a way to satisfy the guard.
  stage_agents "$tmp"; rm -f "${tmp}/${AGENT_DIR}/sa-tester.md"
  rc=0; out="$(check_gate_procedures_drive_cockpit "$tmp" 2>&1)" || rc=$?
  if [[ "$rc" -ne 1 ]] || ! grep -q 'on the roster but not in the tree' <<< "$out"; then
    bad "SELF-TEST FAILED: a rostered procedure that vanished was NOT caught (rc=${rc}) — the roster can be satisfied by deletion."
    return 2
  fi

  # Canary J — ratchet backward: a NEW procedure that drives a cockpit and is not on the roster.
  stage_agents "$tmp"
  cat > "${tmp}/${AGENT_DIR}/rogue-tester.md" <<'ROGUE'
---
name: rogue-tester
description: a new gate procedure nobody added to the roster
---
Walk the lab: oc exec -n ogsr-showroom deploy/showroom-<userN> -- bash -c 'ws verify m01'
ROGUE
  rc=0; out="$(check_gate_procedures_drive_cockpit "$tmp" 2>&1)" || rc=$?
  if [[ "$rc" -ne 1 ]] || ! grep -q 'not on this guard.s roster' <<< "$out"; then
    bad "SELF-TEST FAILED: an unrostered cockpit-driving procedure was NOT caught (rc=${rc}) — a new gate could opt out by being new."
    printf '%s\n' "$out" | sed 's/^/       /' >&2
    return 2
  fi

  # Canary K — a roster this guard cannot parse must cost rc 2, never rc 1: CI asserts --self-test
  # exits exactly 1, so a malformed roster reporting 1 would satisfy that assertion while the guard
  # checked nothing. Both shapes, driving the REAL detector with the roster overridden in a subshell.
  stage_agents "$tmp"
  rc=0
  (
    # shellcheck disable=SC2317,SC2329  # an override, reached from inside the detector below
    # (SC2329 is shellcheck >=0.10, SC2317 the same finding on 0.9.x which CI installs — name both)
    gate_procedures() { echo "sa-tester.md G4 cockpit-exec"; }
    check_gate_procedures_drive_cockpit "$tmp" >/dev/null 2>&1
  ) || rc=$?
  if [[ "$rc" -ne 2 ]]; then
    bad "SELF-TEST FAILED: a roster entry with no ' :: ' reported rc=${rc}, not 2 — a malformed roster would pass as a check."
    return 2
  fi
  rc=0
  (
    # shellcheck disable=SC2317,SC2329  # same override, second malformed shape (name both codes)
    gate_procedures() { echo "sa-tester.md G4 :: cockpit-exec typo-rule"; }
    check_gate_procedures_drive_cockpit "$tmp" >/dev/null 2>&1
  ) || rc=$?
  if [[ "$rc" -ne 2 ]]; then
    bad "SELF-TEST FAILED: an unknown rule token reported rc=${rc}, not 2 — a typo'd rule would silently assert nothing."
    return 2
  fi

  # Canary L — the public-tree shape. `.claude/` is gitignored, so in CI check [4] has nothing to
  # read. That must be SAID, not silently scored as coverage: this asserts on the OUTPUT, because
  # "rc 0" is exactly what a blind pass also looks like.
  rm -rf "${tmp:?}/.claude"
  rc=0; out="$(check_gate_procedures_drive_cockpit "$tmp" 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    bad "SELF-TEST FAILED: an absent ${AGENT_DIR}/ reported rc=${rc} — CI would be permanently red on material it can never have."
    return 2
  fi
  if ! grep -q 'NOT INSPECTED' <<< "$out" || grep -q '✅ \[4\]' <<< "$out"; then
    bad "SELF-TEST FAILED: an absent ${AGENT_DIR}/ was reported as a pass, not as uninspected:"
    printf '%s\n' "$out" | sed 's/^/       /' >&2
    return 2
  fi

  ok "self-test ok — real tree clean (rc=0); non-interactive, login-shell, no-container, host-side-prep,"
  note "host-side-verify and missing-file canaries all caught; and for the gate procedures: a clean"
  note "control, all 8 rules proven individually (each names its own rule and no other), a deleted"
  note "roster entry, an unrostered cockpit procedure, two malformed rosters at rc 2, and an absent"
  note "${AGENT_DIR}/ reported as NOT INSPECTED rather than as a pass."
  return 1
}

# Rejects anything that is not --self-test / -h / --help, naming the offender, exit 2.
parse_guard_args "$@"
if [[ "$GUARD_SELF_TEST" -eq 1 ]]; then
  self_test
  exit $?
fi

run_check "$REPO_ROOT"
rc=$?
case "$rc" in
  0) if [[ "$PROCEDURE_ARM" == "ran" ]]; then
       printf '%s\n' "cockpit-smoke-identity-guard: clean — the smoke gate still runs in the attendee cockpit, and every gate procedure still binds its auditor to it."
     else
       # The success line CHANGES rather than carrying a footnote: a run that inspected one of the
       # two halves must not read the same as a run that inspected both.
       printf '%s\n' "cockpit-smoke-identity-guard: clean for ${WS} ONLY — the gate-procedure arm did not run (see ➖ above), so this run says NOTHING about whether G3/G4 still drive the attendee terminal."
     fi
     printf '%s\n' "  (Contract only. CI has no cockpit: the real proof is 'tools/ws/ws smoke <module> <userN>'.)" ;;
  1) printf '\n%s\n' "  A smoke that does not run in the attendee's terminal proves nothing about the surface" >&2
     printf '%s\n\n'  "  attendees touch — it grades the maintainer's shell. Fix before trusting any G1 result." >&2 ;;
esac
exit "$rc"
