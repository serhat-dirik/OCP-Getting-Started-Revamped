#!/usr/bin/env bash
# verify-mutation-guard.sh — a verify script GRADES the cluster; it must not WRITE to it.
#
# ORIGIN (2026-08-01, commit 4445c4c). tools/verify/resilience-multicluster-dr.sh scaled the
# attendee's primary-site Deployment to 0 and back as part of grading. The scale-down itself was
# behind an opt-in flag. Its EXIT trap was NOT: the trap was installed unconditionally at the top of
# the end-state branch, BEFORE the drill's own prerequisite guard, with SITEA_RESTORE still empty —
# so `--replicas=${SITEA_RESTORE:-3}` resolved to a literal 3 and EVERY end-mode run wrote 3 onto the
# Deployment, including runs that never entered the drill. M21's lab asks the attendee to scale that
# same Deployment to zero and watch the mesh fail over; running `ws verify` in a second terminal at
# that moment — the obvious thing to do — silently ended their exercise.
#
# The asymmetry IS the bug: the mutation was guarded, the trap that undid it was not. It was found by
# reading the file. Nothing checked it, and the other 25 verify scripts had never been audited.
#
# THE PROPERTY: nothing under tools/verify/ may write to the cluster except inside an explicitly
# marked, reviewed opt-in region.
#
# WHAT IT CHECKS — four detectors over a quote/comment-aware skeleton of each script (see "the
# scanner" below; this is the whole reason the guard is not a grep):
#   [D1] EXECUTED MUTATION. An `oc`/`kubectl` mutating verb at a real command position, outside any
#        opt-in region. PRINTED and COMMENTED mutations do not count and must not: of the 68
#        mutating-verb occurrences in this tree on 2026-08-01, exactly FIVE are executed writes (all
#        five inside failover_drill). The other 63 are `hint "…"` repair commands for a human to
#        paste, comments quoting the lab, or read-only sub-verbs like `oc rollout status`. A grep
#        would report 68 findings, 63 of them wrong, and be switched off inside a week.
#   [D2] MUTATING TRAP OUTSIDE THE OPT-IN. The incident shape, checked separately because a trap body
#        is a quoted string — D1's skeleton blanks it, exactly like the printed hints. Covers a trap
#        whose body names a function that mutates, not just an inline `oc`.
#   [D3] UNDISARMED TRAP. A covered mutating trap must be revoked (`trap -`) inside the same function.
#        Measured on the real fix: left armed, the DR trap fired a SECOND time at verify_summary's
#        exit and re-applied a now-stale replica count after the restore marker was already gone —
#        six writes where five were intended. An armed trap outliving its region is a live mutation.
#   [D4] MARKER HYGIENE. An opt-in region that mutates nothing, an unclosed/stray/reasonless marker,
#        or a reviewed-baseline entry that no longer matches anything. A stale opt-in marker is a
#        loaded gun pointed at the next author who writes inside it.
#
# THE OPT-IN CONTRACT. A region that genuinely must write to the cluster wraps itself:
#
#     # ws-mutation-optin: <why this must write, and what asks for it by name>
#     …
#     # ws-mutation-optin-end
#
# Explicit and greppable, deliberately: inferring "this looked opt-in enough" from control flow is
# how the trap slipped through in the first place. The marker is a claim its author signs.
#
# THE REVIEWED BASELINE — now EMPTY, which is the intended end state. It briefly carried one entry
# (resilience-multicluster-dr.sh's failover_drill) because the lane that wrote this guard did not own
# tools/verify/ and so could not add the marker comment. The marker landed in the same commit that
# emptied this array; D4 errors on an entry matching nothing, which is what forced the two halves to
# be atomic. Leave it empty. An entry here is a debt, not a feature.
#
# Emptying it also exposed a bug worth remembering: on bash 3.2 with `set -u`, "${EMPTY[@]}" raises
# "unbound variable" rather than expanding to nothing — so the SUCCESS state crashed the guard, and
# the crash exited 1, which is exactly what CI's "self-test must exit 1" reads as proof of detection.
# Both expansions below are guarded. If you ever add an entry and later remove it, re-run the PLAIN
# mode: the self-test alone cannot tell you the difference.
#
# THE SCANNER. Per file, a character state machine tracks single quotes, double quotes, `$( )`
# substitutions re-entered from inside a double quote, backslash escapes, and `#` comments, ACROSS
# lines (bash strings span them). Quoted and commented spans are blanked to whitespace; what is left
# is code. Escape handling is not optional: several hints embed `-p '{\"spec\":…}'` and a scanner that
# let `\"` close the string would leak `oc patch` out of a printed hint as a false positive.
#
# KNOWN LIMITS (deliberate, stated rather than hidden): a mutation reached only through `eval`, a
# variable holding a verb (`oc "$VERB" …`), a heredoc fed to `oc apply -f -` opened on a line with no
# mutating verb, or a multi-line `trap` body. None exist in this tree today (checked); all would need
# a real parser, and each would still trip D1 at the point the mutating command is written out.
# `oc exec` is NOT treated as a write, on purpose: this suite uses it a dozen times to probe from
# inside a pod (`oc exec deploy/claims-client -- curl …`), which is how several checks grade at all.
# It can of course mutate application state — `oc exec -- psql -c 'DROP TABLE …'` is a write nobody
# here would catch — so that stays a review responsibility, not a claim this guard makes.
#
# Runnable standalone (CI lint gate) and by hand; needs nothing but bash + awk.
#
# --self-test plants five canaries in a scratch tree: one per detector, each a real regression shape
# (D2's is the incident verbatim — a guarded mutation with an unguarded trap), plus a NEGATIVE canary
# packed with the printed/commented/escaped/dry-run/rollout-status forms that must never fire. Exit 1
# = every canary caught, the negative canary silent, and the real tree clean; that is a PASS, matching
# the house convention where CI asserts the self-test step exits exactly 1.
#
# Exit codes:
#   0  no verify script writes to the cluster outside a reviewed opt-in
#   1  a violation — or, under --self-test, every canary was correctly detected
#   2  the guard could not inspect what it claims to inspect (no files, scanner broken, canary missed)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFY_DIR="${REPO_ROOT}/tools/verify"
# shellcheck source=tools/lint/_parse-guard-args.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_parse-guard-args.sh"

ok()   { echo "✅ $*"; }
bad()  { echo "❌ $*" >&2; }
warnln() { echo "⚠️  $*"; }
note() { echo "   $*"; }

# ── the reviewed baseline ─────────────────────────────────────────────────────────────────────────
# <basename>:<function>. Opt-in by construction and reviewed in 4445c4c, but without the marker
# comment because this guard's lane does not own tools/verify/. Delete the entry when the marker
# lands — D4 fails on an entry that matches nothing, so it cannot rot silently.
BASELINE=(
)
# Space-delimited set of entries that matched, not an associative array: this must run on the bash
# 3.2 every maintainer's macOS ships as well as on CI's bash 5.
BASELINE_HIT=" "

VIOLATIONS=0
FIRED=""          # detector ids that fired, for the self-test
violate() {       # violate <detector-id> <message…>
  local id="$1"; shift
  VIOLATIONS=$((VIOLATIONS + 1))
  FIRED="${FIRED} ${id}"
  bad "[${id}] $*"
}

# ── the scanner ───────────────────────────────────────────────────────────────────────────────────
# One awk pass per file. Emits tab-separated records; all judgement happens in bash below.
#   FUNC       <name> <start> <end>
#   MUT        <line> <func> <verb> <code-snippet>
#   TRAPBODY   <line> <func> <verb-or-empty> <raw-body>
#   TRAPOFF    <line> <func>
#   OPTIN      <start> <end>          OPTINOPEN/OPTINSTRAY/OPTINBARE/OPTINNEST <line>
#   FUNCOPEN   <name> <start>         (unterminated function — scanner cannot trust its own output)
#   LINES      <n>
read -r -d '' AWK_SCAN <<'AWK_PROGRAM'
function wordin(s, w) {
  return (s ~ ("(^|[^[:alnum:]_./-])" w "([^[:alnum:]_./-]|$)"))
}
# The verb of one command segment, or "" when the segment does not write to the cluster.
function mutverb(seg,   i, n) {
  if (!(seg ~ /(^|[^[:alnum:]_.\/-])(oc|kubectl)([^[:alnum:]_.\/-]|$)/)) return ""
  # --dry-run and --list turn every writing verb into a read. Both are real idioms here.
  if (seg ~ /--dry-run/) return ""
  if (seg ~ /(^|[[:space:]])--list([[:space:]]|$)/) return ""
  # `oc auth can-i <verb>` ASKS whether a verb is permitted — the verb token is the question, not an
  # action, and this suite's RBAC checks are full of `can-i patch|create|delete`. This MUST precede
  # the verb table: otherwise `can-i patch` reads as `patch` and every RBAC check is a false
  # positive. Missed on the first pass, which reddened CI — `oc auth reconcile` is NOT included here,
  # because that one really does write.
  if (seg ~ /(^|[^[:alnum:]_.\/-])auth[[:space:]]+can-i([^[:alnum:]_.\/-]|$)/) return ""
  n = split("scale patch delete annotate apply create replace label edit expose taint drain " \
            "cordon uncordon new-app new-project new-build import-image debug set cp", MV, " ")
  for (i = 1; i <= n; i++) if (wordin(seg, MV[i])) return MV[i]
  # Sub-verb aware: `oc rollout status` is a blocking READ and appears in a dozen hints; only these
  # four rollout sub-verbs write.
  if (seg ~ /(^|[^[:alnum:]_.\/-])rollout[[:space:]]+(restart|undo|pause|resume)([^[:alnum:]_.\/-]|$)/) return "rollout"
  # `oc adm` is mostly administrative writes, with a short read allowlist.
  if (wordin(seg, "adm") && !(seg ~ /adm[[:space:]]+(policy[[:space:]]+who-can|top|inspect|must-gather|node-logs|release[[:space:]]+info)/)) return "adm"
  return ""
}
# Split on shell command separators, then ask each segment. Keeps `… || hint "…"` from bleeding.
function scanseg(t,   i, n, parts, v) {
  gsub(/\|\||&&/, "\n", t)
  gsub(/[;|&]/,   "\n", t)
  n = split(t, parts, "\n")
  for (i = 1; i <= n; i++) { v = mutverb(parts[i]); if (v != "") return v }
  return ""
}
# Blank every quoted span and every comment; leave code. Q/SP/PD/STKQ/STKPD persist across lines.
function skeleton(s,   out, i, n, c, nx, prev) {
  out = ""; n = length(s); i = 1
  while (i <= n) {
    c = substr(s, i, 1); nx = (i < n) ? substr(s, i + 1, 1) : ""
    if (Q == 0) {
      if (c == "\\") { out = out "  "; i += 2; continue }
      if (c == "#") {
        prev = (i == 1) ? " " : substr(s, i - 1, 1)
        if (prev == " " || prev == "\t" || prev == ";" || prev == "&" || prev == "|" || prev == "(") break
        out = out c; i++; continue
      }
      if (c == "'")  { Q = 1; out = out " "; i++; continue }
      if (c == "\"") { Q = 2; out = out " "; i++; continue }
      if (c == "(")  { if (SP > 0) PD++; out = out c; i++; continue }
      if (c == ")") {
        if (SP > 0) {
          if (PD > 0) { PD--; out = out c; i++; continue }
          Q = STKQ[SP]; PD = STKPD[SP]; SP--; out = out " "; i++; continue
        }
        out = out c; i++; continue
      }
      out = out c; i++; continue
    }
    if (Q == 1) { if (c == "'") Q = 0; out = out " "; i++; continue }
    # Q == 2 (double quote): backslash escapes a following quote, and $( re-enters code.
    if (c == "\\")               { out = out "  "; i += 2; continue }
    if (c == "\"")               { Q = 0; out = out " "; i++; continue }
    if (c == "$" && nx == "(")   { SP++; STKQ[SP] = 2; STKPD[SP] = PD; Q = 0; PD = 0; out = out "  "; i += 2; continue }
    out = out " "; i++; continue
  }
  return out
}
function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
# Net brace depth of a code line. `${VAR}` / `${VAR:-x}` are balanced and stripped first so a
# parameter expansion can never look like a block. One-liner functions — `f() { …; }`, which this
# tree uses a lot — come out net 0, which is exactly how they are recognised.
function bracenet(sk,   o, c) {
  while (sk ~ /\$\{[^{}]*\}/) gsub(/\$\{[^{}]*\}/, "", sk)
  o = gsub(/\{/, "{", sk); c = gsub(/\}/, "}", sk)
  return o - c
}
BEGIN { Q = 0; SP = 0; PD = 0; INFUNC = ""; FSTART = 0; FDEPTH = 0; OPEN = 0; OPENLINE = 0 }
{
  raw = $0
  # Markers are comments, so they are read from the RAW line before the skeleton blanks them.
  if (raw ~ /^[[:space:]]*#[[:space:]]*ws-mutation-optin:[[:space:]]*[^[:space:]]/) {
    if (OPEN) print "OPTINNEST\t" NR
    OPEN = 1; OPENLINE = NR
  } else if (raw ~ /^[[:space:]]*#[[:space:]]*ws-mutation-optin:/) {
    print "OPTINBARE\t" NR
  } else if (raw ~ /^[[:space:]]*#[[:space:]]*ws-mutation-optin-end[[:space:]]*$/) {
    if (OPEN) { print "OPTIN\t" OPENLINE "\t" NR; OPEN = 0 } else print "OPTINSTRAY\t" NR
  }

  sk = skeleton(raw)

  if (INFUNC == "" && sk ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\([[:space:]]*\)[[:space:]]*\{/) {
    fn = sk; sub(/^[[:space:]]*/, "", fn); sub(/[[:space:]]*\(.*$/, "", fn)
    FDEPTH = bracenet(sk)
    if (FDEPTH <= 0) { print "FUNC\t" fn "\t" NR "\t" NR; INFUNC = ""; here = fn }
    else { INFUNC = fn; FSTART = NR; here = fn }
  } else if (INFUNC != "") {
    here = INFUNC
    FDEPTH += bracenet(sk)
    if (FDEPTH <= 0) { print "FUNC\t" INFUNC "\t" FSTART "\t" NR; INFUNC = "" }
  } else {
    here = "-"
  }

  if (sk ~ /(^|[^[:alnum:]_])trap([^[:alnum:]_]|$)/) {
    body = substr(raw, index(raw, "trap") + 4)
    if (body ~ /^[[:space:]]*-([[:space:]]|$)/) print "TRAPOFF\t" NR "\t" here
    else print "TRAPBODY\t" NR "\t" here "\t" scanseg(body) "\t" trim(body)
  } else {
    v = scanseg(sk)
    if (v != "") print "MUT\t" NR "\t" here "\t" v "\t" substr(trim(sk), 1, 110)
  }
}
END {
  if (OPEN)        print "OPTINOPEN\t" OPENLINE
  if (INFUNC != "") print "FUNCOPEN\t" INFUNC "\t" FSTART
  print "LINES\t" NR
}
AWK_PROGRAM

# ── judgement ─────────────────────────────────────────────────────────────────────────────────────
SCANNED=0
MUTATIONS_SEEN=0

in_baseline() {  # in_baseline <basename> <func>
  local key="$1:$2" e
  # bash 3.2 + `set -u`: "${empty[@]}" is an UNBOUND VARIABLE error, not an empty expansion. The
  # baseline reaching zero entries is the SUCCESS case (every opt-in region now carries its marker),
  # so the guard must survive it. It did not: emptying the array crashed the script, and the crash
  # exited 1 — which is exactly what the CI assertion "self-test must exit 1" reads as proof of
  # detection. The plain run is what caught it. Guard the expansion rather than the array's contents.
  (( ${#BASELINE[@]} == 0 )) && return 1
  for e in "${BASELINE[@]}"; do
    if [[ "$e" == "$key" ]]; then
      [[ "$BASELINE_HIT" == *" ${e} "* ]] || BASELINE_HIT="${BASELINE_HIT}${e} "
      return 0
    fi
  done
  return 1
}

scan_one() {  # scan_one <path>
  local file="$1" base out rec
  base="$(basename "$file")"
  out="$(awk "$AWK_SCAN" "$file")" || { violate "SCAN" "${base}: scanner failed"; return 1; }

  local -a optin_start=() optin_end=() mut_lines=()
  local -a trap_lines=() trap_funcs=() trap_verbs=() trap_bodies=()
  local trapoff_funcs=" " mut_fn_names=" "
  local nlines=0

  while IFS=$'\t' read -r rec f2 f3 f4 f5; do
    case "$rec" in
      LINES)      nlines="$f2" ;;
      OPTIN)      optin_start+=("$f2"); optin_end+=("$f3") ;;
      OPTINOPEN)  violate "D4" "${base}:${f2}: 'ws-mutation-optin' region is never closed — add '# ws-mutation-optin-end'" ;;
      OPTINSTRAY) violate "D4" "${base}:${f2}: 'ws-mutation-optin-end' with no open region above it" ;;
      OPTINBARE)  violate "D4" "${base}:${f2}: 'ws-mutation-optin:' with no reason — the marker is a signed claim, say what must write and what asks for it" ;;
      OPTINNEST)  violate "D4" "${base}:${f2}: nested 'ws-mutation-optin:' — close the previous region first" ;;
      FUNCOPEN)   violate "SCAN" "${base}: function '${f2}' opened at line ${f3} never closes with '}' at column 0 — the scanner cannot place mutations reliably in this file" ;;
      FUNC)       : ;;
      MUT)        mut_lines+=("$f2|$f3|$f4|$f5")
                  if [[ "$f3" != "-" && "$mut_fn_names" != *" ${f3} "* ]]; then mut_fn_names="${mut_fn_names}${f3} "; fi ;;
      TRAPBODY)   trap_lines+=("$f2"); trap_funcs+=("$f3"); trap_verbs+=("$f4"); trap_bodies+=("$f5") ;;
      TRAPOFF)    [[ "$trapoff_funcs" == *" ${f3} "* ]] || trapoff_funcs="${trapoff_funcs}${f3} " ;;
    esac
  done <<<"$out"

  (( nlines > 0 )) || { violate "SCAN" "${base}: scanned 0 lines"; return 1; }
  SCANNED=$((SCANNED + 1))

  covered() {  # covered <line> <func> → 0 when inside a marker region or the reviewed baseline
    local ln="$1" fn="$2" i
    for (( i = 0; i < ${#optin_start[@]}; i++ )); do
      if (( ln >= optin_start[i] && ln <= optin_end[i] )); then return 0; fi
    done
    if [[ "$fn" != "-" ]] && in_baseline "$base" "$fn"; then return 0; fi
    return 1
  }

  # [D1] executed mutations
  local entry ln f v snip i fn
  for (( i = 0; i < ${#mut_lines[@]}; i++ )); do
    entry="${mut_lines[i]}"
    IFS='|' read -r ln f v snip <<<"$entry"
    MUTATIONS_SEEN=$((MUTATIONS_SEEN + 1))
    if covered "$ln" "$f"; then
      if [[ "$f" != "-" ]] && in_baseline "$base" "$f"; then
        warnln "baselined: ${base}:${ln} (${f}) writes to the cluster (oc ${v}) — reviewed opt-in, still owes a '# ws-mutation-optin:' marker"
      fi
      continue
    fi
    violate "D1" "${base}:${ln}: verify script WRITES to the cluster (oc ${v}) outside any opt-in region → ${snip}"
  done

  # [D2] mutating traps, and [D3] their disarm. A trap body that merely NAMES a mutating function
  # writes to the cluster just as surely as an inline `oc scale` does.
  local tv tfn tln tbody armed_fn
  for (( i = 0; i < ${#trap_lines[@]}; i++ )); do
    tln="${trap_lines[i]}"; tfn="${trap_funcs[i]}"; tv="${trap_verbs[i]}"; tbody="${trap_bodies[i]}"
    if [[ -z "$tv" ]]; then
      for fn in $mut_fn_names; do
        if [[ "$tbody" == *"$fn"* ]]; then tv="→${fn}()"; break; fi
      done
    fi
    [[ -n "$tv" ]] || continue
    MUTATIONS_SEEN=$((MUTATIONS_SEEN + 1))
    if ! covered "$tln" "$tfn"; then
      violate "D2" "${base}:${tln}: trap installs a cluster MUTATION (${tv}) outside any opt-in region — this is the 4445c4c shape: the write is guarded, the trap that fires it is not → ${tbody:0:100}"
      continue
    fi
    if [[ "$tfn" != "-" ]] && in_baseline "$base" "$tfn"; then
      warnln "baselined: ${base}:${tln} (${tfn}) installs a mutating trap (${tv}) — reviewed opt-in"
    fi
    armed_fn="$tfn"
    if [[ "$armed_fn" == "-" ]]; then
      violate "D3" "${base}:${tln}: mutating trap installed at file scope — it can never be disarmed and outlives every check below it; move it inside the function that owns the write"
      continue
    fi
    if [[ "$trapoff_funcs" != *" ${armed_fn} "* ]]; then
      violate "D3" "${base}:${tln}: mutating trap in ${armed_fn}() is never disarmed ('trap - EXIT …') — it fires again at the script's own exit and re-applies a stale value after the restore is done"
    fi
  done

  # [D4] a marker region that guards nothing
  local s e found j
  for (( i = 0; i < ${#optin_start[@]}; i++ )); do
    s="${optin_start[i]}"; e="${optin_end[i]}"; found=0
    for (( j = 0; j < ${#mut_lines[@]}; j++ )); do
      ln="${mut_lines[j]%%|*}"
      if (( ln >= s && ln <= e )); then found=1; break; fi
    done
    if (( found == 0 )); then
      for (( j = 0; j < ${#trap_lines[@]}; j++ )); do
        tln="${trap_lines[j]}"
        if (( tln >= s && tln <= e )); then found=1; break; fi
      done
    fi
    (( found == 1 )) || violate "D4" "${base}:${s}: 'ws-mutation-optin' region (to line ${e}) contains no cluster write — a stale opt-in marker is a loaded gun for whoever edits inside it next"
  done
  return 0
}

scan_tree() {  # scan_tree <dir> ; sets SCANNED
  local dir="$1" f found=0
  for f in "$dir"/*.sh; do
    [[ -f "$f" ]] || continue
    found=1
    scan_one "$f"
  done
  (( found == 1 )) || return 1
  return 0
}

# ── the always-on fixture probe ───────────────────────────────────────────────────────────────────
# EVERY run, plain mode included — this repo has been bitten three times by gates that passed without
# inspecting anything. Seven lines carrying one genuinely executed mutation and six near-misses: a
# printed repair hint, a commented lab command, a hint with an embedded `-p '{\"…\"}'` payload (the
# escape case that decides whether the scanner is real), a blocking `rollout status` read, and a
# `--dry-run` create. If the scanner cannot land on exactly line 7 the guard refuses to report at all.
fixture_probe() {
  local d out muts
  d="$(mktemp -d)" || return 1
  cat >"$d/probe.sh" <<'PROBE'
#!/usr/bin/env bash
hint "repair it yourself: oc delete pod broken -n ${NS}"
# oc scale deploy/x --replicas=0
check "meshed" pod_meshed x || hint "fix: oc patch deploy x -p '{\"spec\":{\"a\":1}}' && oc rollout status deploy/x"
oc rollout status deploy/x -n "$NS"
oc create cm x --from-literal=a=b --dry-run=client -o yaml
oc scale deploy/y -n "$NS" --replicas=0
PROBE
  out="$(awk "$AWK_SCAN" "$d/probe.sh")"
  rm -rf "$d"
  muts="$(printf '%s\n' "$out" | awk -F'\t' '$1=="MUT"{printf "%s:%s ", $2, $4}')"
  [[ "$muts" == "7:scale " ]]
}

# ── self-test ─────────────────────────────────────────────────────────────────────────────────────
# One canary per detector plus a negative canary. Each canary is scanned in isolation so a detector
# that has gone blind shows up as its own id missing from FIRED, not as a changed total.
plant_canaries() {  # plant_canaries <dir>
  local d="$1"
  # D1 — a bare executed mutation, no marker anywhere.
  cat >"$d/c1-executed.sh" <<'EOF'
#!/usr/bin/env bash
NS=demo
check "route exists" oc get route parasol-web -n "$NS" || hint "create it: oc create route edge parasol-web"
oc delete pod stuck -n "$NS"
EOF
  # D2 — the incident verbatim: the write is inside the opt-in, the trap that fires it is not.
  cat >"$d/c2-trap.sh" <<'EOF'
#!/usr/bin/env bash
NS=demo
trap 'oc scale deploy/parasol-claims -n "$NS" --replicas="${RESTORE:-3}" >/dev/null 2>&1 || true' EXIT
# ws-mutation-optin: the drill takes the primary site down; only --failover-drill asks for it
drill() {
  oc scale deploy/parasol-claims -n "$NS" --replicas=0
  trap - EXIT
}
# ws-mutation-optin-end
EOF
  # D3 — covered mutating trap, never revoked; it fires again at the script's own exit.
  cat >"$d/c3-disarm.sh" <<'EOF'
#!/usr/bin/env bash
NS=demo
# ws-mutation-optin: opt-in drill, reason recorded
drill() {
  trap 'oc scale deploy/x -n "$NS" --replicas=3' EXIT
  oc scale deploy/x -n "$NS" --replicas=0
}
# ws-mutation-optin-end
EOF
  # D4 — a marker region guarding nothing, and a reasonless marker.
  cat >"$d/c4-marker.sh" <<'EOF'
#!/usr/bin/env bash
NS=demo
# ws-mutation-optin: reserved for later
check "ns" oc get ns "$NS"
# ws-mutation-optin-end
# ws-mutation-optin:
check "pods" oc get pods -n "$NS"
# ws-mutation-optin-end
EOF
  # NEGATIVE — every printed/commented/escaped/read-only form this tree actually uses. Must be silent.
  cat >"$d/c0-clean.sh" <<'EOF'
#!/usr/bin/env bash
# The lab tells the attendee: oc scale deploy/parasol-claims --replicas=0
NS=demo
check "db ready" deploy_ready claims-db "$NS" || hint "wait for rollout: oc rollout status deploy/claims-db -n ${NS}"
check "route" oc get route parasol-web -n "$NS" || hint "publish it: oc create route edge parasol-web --insecure-policy=Allow. NOT 'oc expose'. If a plain Route exists, delete it first."
check "meshed" pod_meshed parasol-claims || hint "enroll per workload: oc patch deploy parasol-claims -n ${NS} --type=merge -p '{\"spec\":{\"template\":{\"metadata\":{\"labels\":{\"sidecar.istio.io/inject\":\"true\"}}}}}' && oc rollout status deploy/parasol-claims -n ${NS}"
got="$(oc get deploy "$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
oc rollout status deploy/parasol-claims -n "$NS" --timeout=60s
oc create configmap probe --from-literal=a=b --dry-run=client -o yaml >/dev/null
oc set env deploy/parasol-claims --list -n "$NS"
oc adm policy who-can create pods -n "$NS"
# The shape that reddened CI on this guard's first commit: the verb is the QUESTION, not the action.
! oc auth can-i patch deployments --as="$U" --as-group=workshop-attendees -n "$NS" >/dev/null 2>&1
oc auth can-i create pods -n "$NS" >/dev/null 2>&1
oc auth can-i delete secrets --subresource= -n "$NS" >/dev/null 2>&1
trap - EXIT
echo "done ${got}"
EOF
}

self_test() {
  local d rc=0 missed=""
  d="$(mktemp -d)" || { bad "self-test: mktemp failed"; return 2; }
  plant_canaries "$d"

  local id file
  for id in D1:c1-executed.sh D2:c2-trap.sh D3:c3-disarm.sh D4:c4-marker.sh; do
    file="${id#*:}"; id="${id%%:*}"
    VIOLATIONS=0; FIRED=""
    scan_one "$d/$file" >/dev/null 2>&1
    if [[ " ${FIRED} " == *" ${id} "* ]]; then
      ok "canary ${file}: ${id} detected"
    else
      bad "canary ${file}: ${id} NOT detected — that detector is blind (fired:${FIRED:-none})"
      missed="${missed} ${id}"
    fi
  done

  VIOLATIONS=0; FIRED=""
  local noise
  noise="$(scan_one "$d/c0-clean.sh" 2>&1)"
  if (( VIOLATIONS == 0 )); then
    ok "negative canary c0-clean.sh: printed hints, comments, escaped quotes, --dry-run, --list and 'rollout status' all correctly ignored"
  else
    bad "negative canary c0-clean.sh: ${VIOLATIONS} FALSE POSITIVE(S) — a noisy guard gets switched off"
    printf '%s\n' "$noise" >&2
    missed="${missed} FALSE-POSITIVE"
  fi
  rm -rf "$d"

  # The same detectors, against the tree they exist for.
  VIOLATIONS=0; FIRED=""; SCANNED=0; MUTATIONS_SEEN=0; BASELINE_HIT=" "
  scan_tree "$VERIFY_DIR" >/dev/null 2>&1 || { bad "self-test: no verify scripts to scan"; return 2; }
  if (( VIOLATIONS == 0 )); then
    ok "real tree clean under all four detectors (${SCANNED} scripts)"
  else
    bad "real tree has ${VIOLATIONS} violation(s) — run without --self-test for the list"
    missed="${missed} REAL-TREE"
  fi

  if [[ -n "$missed" ]]; then
    bad "self-test FAILED:${missed}"
    return 2
  fi
  ok "self-test: 4/4 canaries caught, negative canary silent, real tree clean"
  note "exit 1 below is the PASS signal for this mode (CI asserts exactly 1)"
  rc=1
  return "$rc"
}

# ── main ──────────────────────────────────────────────────────────────────────────────────────────
main() {
  # Parsed FIRST, before the fixture probe: a mistyped flag should be answered immediately, not
  # after a probe whose result the caller is about to be told nothing about. This guard already
  # rejected unknown arguments with exit 2 — the shared parser keeps that code and adds the part
  # that was missing, NAMING the offending argument, and rejecting past $1 as well.
  parse_guard_args "$@"

  if ! fixture_probe; then
    bad "the scanner cannot separate an executed mutation from a printed one — refusing to report on a tree it is not really reading"
    return 2
  fi

  if [[ "$GUARD_SELF_TEST" -eq 1 ]]; then
    self_test
    return $?
  fi

  if [[ ! -d "$VERIFY_DIR" ]]; then
    bad "${VERIFY_DIR} does not exist — nothing inspected"
    return 2
  fi
  if ! scan_tree "$VERIFY_DIR"; then
    bad "no *.sh under ${VERIFY_DIR} — inspecting zero files is never a pass"
    return 2
  fi
  if (( SCANNED == 0 )); then
    bad "scanned 0 verify scripts — inspecting zero files is never a pass"
    return 2
  fi

  # Same bash 3.2 `set -u` trap as in in_baseline(): an EMPTY BASELINE is the success state, and
  # "${empty[@]}" raises "unbound variable" rather than expanding to nothing. Guard the expansion.
  local e
  for e in ${BASELINE[@]+"${BASELINE[@]}"}; do
    if [[ "$BASELINE_HIT" != *" ${e} "* ]]; then
      violate "D4" "reviewed-baseline entry '${e}' matches nothing any more — delete it from BASELINE in $(basename "$0") (it exists only until that opt-in region grows its marker comment)"
    fi
  done

  if (( VIOLATIONS > 0 )); then
    bad "${VIOLATIONS} violation(s): a verify script GRADES, it must not WRITE"
    note "if a write is genuinely the lesson, wrap it: '# ws-mutation-optin: <why>' … '# ws-mutation-optin-end'"
    note "and make the region refuse to run unless something asked for it BY NAME — see failover_drill in tools/verify/resilience-multicluster-dr.sh"
    return 1
  fi
  ok "no verify script writes to the cluster outside a reviewed opt-in (${SCANNED} scripts, ${MUTATIONS_SEEN} opt-in write(s))"
  return 0
}

main "$@"
