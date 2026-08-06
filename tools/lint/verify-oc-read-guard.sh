#!/usr/bin/env bash
# verify-oc-read-guard.sh — pins the oc_read contract (commit 51eb1b6) so it cannot silently erode.
#
# ORIGIN. 51eb1b6 fixed 154 blind reads across tools/verify/*.sh: `oc get … 2>/dev/null` cannot tell
# "the object is not there" (a real ❌) from "the cluster did not answer" (a real ⚠, never the
# attendee's fault) — both come back as an empty string. `oc_read` in _lib.sh keeps stdout and stderr
# apart and returns three outcomes; `check` routes any `oc` invocation through it. Nothing about that
# fix stops the NEXT commit from undoing it, one line at a time, in three different ways:
#
#   [1] a NEW stderr-silenced `oc` read in a tools/verify/*.sh predicate, bypassing oc_read entirely
#       — `oc … 2>/dev/null`, `oc … >/dev/null 2>&1` or `oc … &>/dev/null`; all three are blind in
#       exactly the same way, and the second is the commonest shape in this tree.
#   [2] a module script re-defining deploy_ready / deploy_ready_min / cm_key_set locally — a copy
#       silently SHADOWS the shared _lib.sh definition for that one caller, the exact failure mode
#       that let six copies of an extraction walker drift apart before tools/lint/_extract-func.sh
#       deduplicated them (2026-07-31).
#   [3] the three-outcome contract itself regressing inside oc_read — specifically NotFound folded
#       back into "succeeded". Not hypothetical: 51eb1b6's own commit message says its FIRST draft
#       shipped exactly this, and it made a PodDisruptionBudget-missing check PASS in a namespace
#       that had none. Only a full non-entry-only run caught it; every entry-only run looked clean
#       because those particular objects existed.
#
# [1] IS A RATCHET, NOT AN AMNESTY. 51eb1b6's own commit message: "108 silenced reads remain in
# per-module predicates … the conversion is mechanical, but the lane stopped where it had live state
# to diff against rather than converting fifteen scripts blind." Those reads are KNOWN, ACKNOWLEDGED
# debt, not a clean baseline — a guard that failed on all of them today would be disabled within the
# week. BASELINE_TABLE below is the exact per-file count this guard's own detector measures against
# the tree as of 2026-08-01 (by SOURCE LINE, so a line carrying two `oc … 2>/dev/null` reads — e.g. an
# outer `oc get devworkspaces … "$(oc get cm … 2>/dev/null)"` — counts once; this is why the total
# differs from the commit message's own by-READ tally, not a disagreement about which reads are
# blind. Since the fifth pass the SILENCING is looked for across the whole LOGICAL line while the
# count still lands on the physical lines that carry the `oc` token — see that pass's note). A
# file's count may only stay AT or FALL BELOW its baseline; a file absent from the table — including
# any brand-new module's verify script — gets baseline 0, so a single occurrence anywhere new fails
# immediately. Converting a listed file's reads to oc_read/oc_present/oc_absent should lower its
# baseline entry in the same change, or the ratchet stops ratcheting.
#
# ALLOWED, deliberately, per _lib.sh's own comments — read them before widening either exclusion:
#   • curl probes. A line with NO `oc` token never matches [1] at all (a pure `curl … 2>/dev/null` has
#     nothing to exclude) — "an app not answering IS the measured outcome, unlike an API that could
#     not be asked" (tools/verify/README.md). An `oc exec … -- curl …` line DOES carry an `oc` token
#     and is still counted: the ambiguity oc_read exists for (could the API connection itself be
#     established) is exactly as live there as anywhere else.
#   • gitea_host()'s route-then-domain fallback (`oc get route gitea … 2>/dev/null || true`, then
#     `oc get ingresses.config.openshift.io cluster … 2>/dev/null || true`) is excluded BY NAME, not by
#     the `|| true` shape in general — `|| true` alone is not a safety property here, it is what most
#     of the acknowledged debt above already does. gitea_host does not care WHY the route read failed;
#     it falls back to domain derivation either way and returns an empty string on total failure, which
#     every caller already treats as "could not determine the host". Named because that specific
#     design call is the only one this guard was told to trust; a new function inventing its own
#     "fall back regardless of why" is a NEW instance of the pattern, not this one.
#
# [3] is EXECUTED, never grepped — a source scan proves the text, not the behaviour. The real oc_read
# is extracted verbatim (tools/lint/_extract-func.sh) and driven against a stubbed `oc` for three
# scripted answers (NotFound, Forbidden, connection-refused) plus a real success, and the canary
# reproduces the regression byte-for-byte: the ONE `return 1` in oc_read (the NotFound/default arm at
# the bottom of its case statement) flipped to `return 0`.
#
# Exit codes: 0 contract holds · 1 contract broken, or under --self-test every canary was correctly
# caught · 2 this guard could not inspect what it claims to (extraction failed, tree missing).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LINT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/lint/_parse-guard-args.sh
source "${LINT_DIR}/_parse-guard-args.sh"
# shellcheck source=tools/lint/_extract-func.sh
source "${LINT_DIR}/_extract-func.sh"
# shellcheck source=tools/lint/_check-coverage.sh
source "${LINT_DIR}/_check-coverage.sh"

VERIFY_DIR="${REPO_ROOT}/tools/verify"
LIB_SH="${VERIFY_DIR}/_lib.sh"

bad()  { echo "❌ $*" >&2; }
note() { echo "   $*"; }
ok()   { echo "✅ $*"; }

# ── [1] the ratchet table ──────────────────────────────────────────────────────────────────────────
# One line per file, "<basename> <count>". A file not listed here defaults to baseline 0.
#
# Re-measured 2026-08-01 against the committed tree after the second conversion pass. Seven files
# reached ZERO and their rows are GONE rather than set to 0 — an absent file defaults to baseline 0, so
# deleting the row is what protects them: a single new silenced read in any of them now fails outright.
# Converted and proven byte-identical against live cluster 2 (healthy + genuine-absence + unreachable-API
# runs diffed against `git archive HEAD`): agentic-ai (4), ai-assisted-development (8), app-modernization
# (4), deployment-targets-scheduling (7), gitops-fundamentals (5), jobs-batch-kueue (9),
# serverless-zero-to-hero (4) — 41 lines, table total 98 → 57. No file's count rose.
#
# ── 2026-08-01, SAME DAY: the detector was matching HALF the debt ────────────────────────────────
# The header above documented `oc … 2>/dev/null` and the detector matched that literal string only.
# It never saw `>/dev/null 2>&1`, which is the MORE COMMON shape here — it is what an existence
# probe and a negation are written as:
#
#     deploy_present() { oc get deploy "$1" -n "$2" >/dev/null 2>&1; }
#     ! oc get networkpolicy default-deny-all -n "$NS" >/dev/null 2>&1
#
# Both silence stderr exactly as thoroughly as `2>/dev/null` and are blind in exactly the same way: a
# throttled API, an expired token or a network blip is indistinguishable from "the object is not
# there", and the attendee gets a false ❌ for correct work. Measured against the committed tree: 58
# additional LINES across 13 files, every one of them invisible to the old detector and therefore
# passing at whatever baseline the file happened to carry. tools/verify/networking-dev-devops.sh was
# the worst case — it carried ZERO of the old shape, so it had no row at all and sat at baseline 0
# while holding TEN blind reads.
#
# NOT ABSORBED SILENTLY. The table below is the honest re-measurement, and the debt it now admits to
# is 115 lines, not 57. Which files moved (old → new): build-deliver 3→4, eventing-deep-dive 3→9,
# gitops-at-scale 6→8, multi-tenancy-workload-security 4→9, networking-dev-devops 0→10 (NEW ROW),
# packaging-distributing 2→7, platform-orientation 4→5, registry-images-catalog-governance 8→15,
# resilience-multicluster-dr 10→22, securing-apps-keycloak 3→5, service-mesh-advanced-gateways 6→13.
# Six rows are unchanged. No file's count fell, because nothing was converted in this change — the
# detector simply stopped being half-blind.
#
# STILL A RATCHET, DELIBERATELY. A zero-tolerance gate over 58 newly-visible violations would be
# switched off inside a week, and these reads are pre-existing debt, not a regression someone just
# introduced. Recording them makes the size of the debt visible instead of laundering it. The
# direction of travel is unchanged: a count may only stay put or FALL, and converting a file's reads
# to oc_read/oc_present/oc_absent should lower its row in the same change.
#
# NOT matched, on purpose: `oc … 2>&1 >/dev/null` (one instance, jobs-batch-kueue.sh:198,
# `cq_err="$(oc get clusterqueue "$CQ" -o name 2>&1 >/dev/null || true)"`). The order is reversed:
# stderr goes to the ORIGINAL stdout and is captured, stdout is discarded. That is a deliberate
# capture-the-error idiom — the opposite of silencing one — and folding it in would punish the shape
# that keeps the diagnosis.
#
# ── 2026-08-01, THIRD PASS: the three worst rows converted, 115 → 80 ─────────────────────────────
# registry-images-catalog-governance (15) and service-mesh-advanced-gateways (13) reached ZERO and their
# rows are GONE rather than set to 0 — an absent file defaults to baseline 0, so deleting the row is what
# protects them going forward. networking-dev-devops falls 10 → 3 and KEEPS its row: the three survivors
# are `oc exec` PROBES (tcp_open_from, probe_machinery_ok, db_name_resolves_from_demo_client), not object
# reads, and that file's own comment records the measurement showing why converting them is a contract
# question for _lib.sh rather than a mechanical change. No file's count rose.
#
# Proven the same way the previous pass was, against live cluster 2 (attendee slots user5 and user7):
# the pristine `git archive HEAD` tree and the working tree run with identical arguments, combined
# stdout+stderr diffed, byte-identical across healthy / genuine-absence (--user user99) / namespace-
# exists-but-objects-absent, entry-only AND full, plus a 33-case predicate-level differential reaching
# branches the guarded end-state block hides. The outcomes that SHOULD differ do: on an unreachable API
# the three scripts previously printed 8, 9 and 11 false ❌ and now print zero red and skip everything.
#
# ── 2026-08-01, FOURTH PASS: the largest row converted, 80 → 64 ──────────────────────────────────
# resilience-multicluster-dr falls 22 → 6 and KEEPS its row. The 16 converted lines are every OBJECT
# READ in the file, including both `oc exec … -- curl` probes and both `oc logs` reads. On an
# unreachable API that script previously printed EIGHT false ❌ at entry mode and eight at full mode;
# it now prints zero red, 15/16 ⚠ and zero passes.
#
# THE SIX SURVIVORS ARE NOT READS. They are the five WRITES and one `oc rollout status` wait inside
# failover_drill — the opt-in active-drill region that tools/lint/verify-mutation-guard.sh reviews
# (`# ws-mutation-optin:`), all of the shape `oc scale … >/dev/null 2>&1 || true`. This detector WAS
# line-shaped: it saw "an `oc` line that silences stderr" and could not tell a blind READ from a
# deliberately-quiet WRITE. oc_read exists to classify an ANSWER so a check can be graded; a drill
# that scales a Deployment and ignores the result has no answer to classify, and rewriting those six
# lines to satisfy a read-oriented ratchet would be churn inside the one region of this suite where
# churn is most expensive. Recorded as a row instead — which left the file at a floor it could never
# honestly leave, and is what the fifth pass below fixes.
#
# Proven against live cluster 2 (attendee slots user2 = entry world, user8 = solved end world):
# byte-identical across TWELVE end-to-end runs per tree — healthy entry-only, healthy full, healthy
# --solve, entry-world-at-full-mode, end-world-at-entry-mode, genuine absence (--user user99, both
# modes), namespace-exists-but-objects-absent (--user user5, both modes), the --entry-only
# +--failover-drill refusal, AND a real ACTIVE FAILOVER DRILL (site-a scaled to 0 and restored, 38s,
# identical to the byte on both trees) — plus a 74-case predicate-level differential. Of the 74, 60
# are byte-identical, 11 differ only by VERIFY_INCONCLUSIVE flipping 0 → 1 on an unanswerable API
# (the whole point), and 3 were harness artifacts of the echo→global change, re-measured with both
# call shapes and confirmed value-identical.
#
# ── 2026-08-01, FIFTH PASS: the detector was LINE-shaped, and could not tell a read from a write ──
# Two corrections in OPPOSITE directions. Reported separately below, because netting them into one
# number would hide both: 64 → 68 (the detector stopped being blind) → 62 (writes stopped being
# counted as reads).
#
# (a) +4 — A SILENCED READ CAN SPAN TWO PHYSICAL LINES. The detector matched one physical line at a
# time, so a read whose `oc` token and whose `2>/dev/null` land on DIFFERENT lines was invisible:
#
#     oc get pipelineruns.tekton.dev -n "$1" -l tekton.dev/pipeline=parasol-claims-devsecops \
#       -o jsonpath='{range .items[*]}{…}{end}' 2>/dev/null | grep -qx True
#
# Neither line matches: the first carries no redirect, the second carries no `oc`. 80b4380 found five
# of these in resilience-multicluster-dr.sh (27 actual against 22 counted) while converting it, and
# recorded that the blind spot was live repo-wide and under-reporting by an unknown amount. The
# amount, measured: FOUR more lines in THREE files — app-security-testing 1→2, eventing-deep-dive
# 9→11, trusted-supply-chain 2→3. Every one is the identical `oc get … \` + `-o jsonpath=… 2>/dev/null`
# shape above, and every one is real debt that was passing at whatever baseline its file carried.
#
# The fix folds physical lines into LOGICAL lines first — a backslash continuation, and a pipeline or
# `&&`/`||` chain broken across lines in either direction — then asks the old question of the whole
# logical line while still COUNTING the physical lines that carry the `oc` token. Counting on the
# `oc` line, not on the logical line, is what keeps `[[ -n "$(oc get se … 2>/dev/null)" ]] &&` /
# `[[ -n "$(oc get vs … 2>/dev/null)" ]]` at TWO, as it has always been counted, instead of quietly
# collapsing a chain of blind reads into one. The change can therefore only ever ADD lines, never
# remove them: a physical line that matched before still matches, because it is contained in its own
# logical line. Trailing- and leading-operator joins find nothing this tree does not already write
# with a backslash — matched anyway, for the same reason `&>/dev/null` is matched with zero instances.
#
# (b) −6 — A QUIET WRITE IS NOT A BLIND READ. resilience-multicluster-dr sat at a floor of 6 that were
# ALL writes (`oc scale`, `oc annotate`, the restore trap, and an `oc rollout status` wait, each
# `>/dev/null 2>&1 || true`), so its row could never honestly reach the zero that deletes it.
# oc_read exists to classify an ANSWER so a check can be graded; a scale that ignores its result has
# no answer to classify, and converting it would satisfy the ratchet while meaning nothing.
#
# THE BASIS IS A CONJUNCTION, and the choice matters more than the code. A line is excluded only when
# it is BOTH (i) inside a `# ws-mutation-optin:` … `# ws-mutation-optin-end` region AND (ii) not an
# object read — a mutating verb, or an `oc rollout status` / `oc wait` whose stdout is progress text
# rather than an answer. Either half alone has a failure mode this guard cannot afford:
#   • MARKER ALONE would make an opt-in region a SAFE HARBOUR FOR READS. Nothing stops the next
#     author writing `oc get … 2>/dev/null` inside failover_drill; verify-mutation-guard's D4 only
#     requires the region to contain a write, not to contain nothing else. That is the same silent
#     under-report (a) exists to end. Canary [1]-J pins it: a blind read inside a marked region is
#     still counted.
#   • VERB ALONE would excuse a misclassified read anywhere in the tree, with no marker to make the
#     exclusion visible — and it still could not reach zero, because `oc rollout status` is not a
#     mutating verb, so the row would floor at 1 instead of 6.
# The conjunction gives up only "a quiet write OUTSIDE a marked region", which cannot legitimately
# exist: verify-mutation-guard's D1 already fails the build on exactly that. So nothing real is lost,
# and every exclusion this guard makes is one an author signed for in a reviewed marker comment.
# resilience-multicluster-dr.sh therefore reaches ZERO and its row is GONE rather than set to 0, the
# same way seven files' rows went in the second pass: an absent file defaults to baseline 0, so
# deleting the row is what protects it — one new blind read there now fails outright.
#
# THE CLASSIFIER IS BORROWED, NOT REBUILT. Whether a line writes, where the marker regions are, and
# where gitea_host() begins and ends all come from verify-mutation-guard.sh's OWN awk scanner,
# extracted from that file at runtime. A second copy of that logic would drift — printed hints,
# `--dry-run`, `oc auth can-i <verb>` (a permission QUESTION, and this suite is full of them: reading
# `can-i patch` as `patch` would excuse real blind reads) and the `rollout` sub-verb split are all
# nuance that took that guard two commits to get right. If the borrow fails, or the borrowed scanner
# stops classifying the four-shape fixture the way this guard needs, [1] exits 2 — never 0.
#
# KNOWN LIMITS of the logical-line matcher, stated rather than hidden (the sibling guard's convention):
#   • It asks whether the LOGICAL line silences stderr, not whether the silencing belongs to the `oc`
#     command in particular. `oc get pods | grep -q x 2>/dev/null` has always counted for the same
#     reason, so this is the existing rule applied consistently — but joined across lines it can now
#     also catch `oc get route … \` + `|| hint "…2>/dev/null…"`, where the redirect is inside a printed
#     string. ZERO instances in this tree (checked: exactly one hint anywhere contains `2>/dev/null`,
#     and it is a `helm version` substitution with no `oc` token). Quote-blanking the joined line would
#     fix it and would also REMOVE lines from the count, which is the one direction a ratchet
#     re-measurement must not move in silently; if it ever fires, blank quotes and re-measure the whole
#     table in that same change.
#   • A write is excluded on the physical line the borrowed scanner reports the VERB on. Split the verb
#     off its `oc` token (`oc \` + `scale …`) and the two line numbers disagree, so the line is COUNTED
#     rather than excluded. Conservative on purpose, and no such split exists here.
#
# ── 2026-08-01, SIXTH PASS: 62 → 33 ───────────────────────────────────────────────────────────────
# Four rows reach ZERO and are DELETED rather than set to 0 — an absent file defaults to baseline 0, so
# deleting the row is what protects it: multi-tenancy-workload-security (9), gitops-at-scale (8),
# packaging-distributing (7), app-security-testing (2). eventing-deep-dive falls 11 → 9 and
# trusted-supply-chain 3 → 2: only the identical `oc get … \` + `-o jsonpath=… 2>/dev/null | grep`
# continuation reads the fifth pass made visible were converted there, so both KEEP their rows. No
# file's count rose.
#
# Proven against live cluster 2 (attendee slots user1, user4, user5, user6, user7, user8): the pristine
# `git archive HEAD` tree and the working tree run with identical arguments, combined stdout+stderr
# diffed byte-for-byte, identical across healthy / genuine-absence (--user user99) / namespace-exists-
# but-objects-absent, entry-only AND full — plus solve→reset round trips on user7 and user1 that reach
# the end-state branches an entry-only run hides, and an ~80-case predicate-level differential under a
# scripted `oc`. Four checks that PASSED on an unreachable API now report ⚠ instead: mtws' sa_cannot and
# deploy_idle, gitops-at-scale's rollout_absent and packaging-distributing's no_deploy — three of them
# ENTRY negations, where a wrongly-green check sends `ws prep` down its "already prepared" fast path.
#
# ── 2026-08-01, SEVENTH PASS: 33 → 14 ─────────────────────────────────────────────────────────────
# Seven more rows reach ZERO and are DELETED (an absent file defaults to baseline 0, so deleting the
# row is what protects it): securing-apps-keycloak (5), build-deliver (4), observability-health-scale
# (2), trusted-supply-chain (2), developer-hub-golden-paths (1), devspaces-inner-loop (1),
# pipelines-fundamentals (1). platform-orientation falls 5 → 2 and KEEPS its row. No file's count rose.
#
# platform-orientation's REMAINING 2 are gitea_user_exists' route-then-domain fallback — the same
# shape gitea_host() is excluded by name for, inlined under a different name, which is why they are
# counted and the identical lines in three sibling files are not. They are NOT converted, on purpose:
# the route read is EXPECTED to be refused for an attendee, so its rc 2 must not become the check's
# verdict once the domain fallback yields a host — but check() consults VERIFY_INCONCLUSIVE on every
# predicate failure, so a raised-then-unwanted flag reports a genuinely MISSING Gitea account as ⚠
# instead of ❌. Expressing "stand the flag down" from a module script means assigning _lib.sh's shared
# flag in the wrong file, and shellcheck says so out loud (SC2034). What is missing is an _lib.sh
# primitive for an oc read whose refusal is EXPECTED because a fallback answers it. Renaming the
# function to gitea_host to inherit the by-name exclusion was considered and rejected — this header
# already says a new function inventing its own "fall back regardless of why" is a NEW instance of the
# pattern, so that would be gaming the ratchet rather than paying it.
#
# Proven against live cluster 2 (attendee slots user1, user2, user3, user5, user6, user7, plus scratch
# user9-dev / user9-cicd, deleted after): the pristine `git archive HEAD` tree and the working tree
# — pinned to the SAME _lib.sh, so a sibling lane's concurrent _lib.sh work is excluded — run with
# identical arguments, combined stdout+stderr diffed byte-for-byte, identical across healthy /
# genuine-absence (--user user99) / namespace-exists-but-objects-absent, entry-only AND full, plus
# solve→reset round trips. Under a scripted `oc` the equivalence that matters is exact: all 16
# module×mode pairs are BYTE-IDENTICAL on NotFound, on "the server doesn't have a resource type", and
# on the partial outage where the namespace reads fine and only the object read fails with NotFound.
# THREE checks that PASSED on an API that could not be asked now report ⚠: platform-orientation's
# clean-slate and securing-apps-keycloak's no_fraud_yet (both ENTRY negations, where a wrongly-green
# check sends `ws prep` down its "already prepared" fast path) and build-deliver's no_deploymentconfig
# (a banned-tech clean bill nobody checked). All three were invisible to a whole-cluster outage — every
# one has a namespace guard that fails closed — and only appeared under a PARTIAL outage.
# EMPTY, and that is the point: every tools/verify/*.sh is now at zero blind reads, so any file
# appearing here again is a regression rather than inherited debt. baseline_for() returns 0 for a
# file absent from the table, so an empty table means "nothing is allowed any" — the strictest
# possible setting. Do not add a row to make a new finding go away; convert the read instead.
BASELINE_TABLE=""

baseline_for() {  # <basename> → integer, 0 if not listed
  awk -v f="$1" '$1==f{print $2; found=1} END{if(!found) print 0}' <<< "$BASELINE_TABLE"
}

# A physical line counts iff: it is not a comment, it carries a standalone `oc` token (so a pure curl
# probe — no `oc` token at all — never matches), its LOGICAL line silences stderr into /dev/null in
# one of the shapes below, and it is not an excluded WRITE (see the fifth-pass note) or inside
# gitea_host().
#
# The three silencing shapes, all equally blind:
#   2>/dev/null              stderr discarded, stdout kept — the shape 51eb1b6 converted.
#   >/dev/null 2>&1          both discarded — the existence-probe / negation idiom, and the MORE
#                            COMMON one here; invisible to this detector until 2026-08-01.
#   &>/dev/null              bash shorthand for the same thing. Zero instances today; matched so the
#                            obvious one-character bypass does not exist the day someone reaches for it.
# The optional [[:space:]]* after `2>` / `&>` and the required whitespace before `2>&1` are what make
# `2> /dev/null` and `> /dev/null 2>&1` count too. `2>&1 >/dev/null` deliberately does NOT match —
# see the BASELINE_TABLE header.
OC_SILENCED_RE='2>[[:space:]]*/dev/null|>[[:space:]]*/dev/null[[:space:]]+2>&1|&>[[:space:]]*/dev/null'

# ── the logical-line matcher ──────────────────────────────────────────────────────────────────────
# Folds physical lines into logical ones, then emits "<line>\t<is-wait>" for every physical line of a
# SILENCED logical line that carries an `oc` token. Emitting the physical `oc` lines rather than the
# logical line is what keeps a two-line `&&` chain of blind reads counted as two — see (a) above.
#
# A group continues when the current line ENDS with `\`, `|`, `||` or `&&`, or when the next line
# BEGINS with `|`, `||` or `&&` (this tree writes `check … \` / `  || hint "…"` constantly, so both
# directions are real). A comment line ends the group: a `#` line is never part of a command here,
# and letting one join would splice a quoted repair hint onto live code.
#
# `is-wait` marks `oc rollout status` / `oc wait` — a blocking WAIT, whose stdout is progress text and
# not an answer oc_read could classify. It is only ever acted on INSIDE a marker region (the
# conjunction), so this flag can never excuse anything on its own.
read -r -d '' AWK_LOGICAL <<'AWK_PROGRAM'
function isoc(s)   { return (s ~ /(^|[^A-Za-z0-9_])oc([^A-Za-z0-9_]|$)/) }
function iswait(s) { return (s ~ /rollout[[:space:]]+status/ || s ~ /(^|[^A-Za-z0-9_.\/-])wait([^A-Za-z0-9_.\/-]|$)/) }
function rstrip(s) { sub(/[[:space:]]+$/, "", s); return s }
function lstrip(s) { sub(/^[[:space:]]+/, "", s); return s }
function wants_more(s,  t) { t = rstrip(s); return (t ~ /\\$/ || t ~ /(\|\||&&|\|)$/) }
function attaches(s,    t) { t = lstrip(s); return (t ~ /^(\|\||&&|\|[^|])/) }
function flush(   i, w) {
  if (NG > 0 && JOINED ~ SIL) {
    for (i = 1; i <= NG; i++) {
      # `w` is assigned first rather than printed as `… "\t" (cond ? 1 : 0)`: a parenthesised ternary
      # concatenated inside a print is parsed differently by different awks, and this file runs under
      # BSD awk on a maintainer's macOS and gawk on CI.
      if (isoc(GL[i])) { w = iswait(GL[i]) ? 1 : 0; print GN[i] "\t" w }
    }
  }
  NG = 0; JOINED = ""; PEND = 0
}
BEGIN { NG = 0; JOINED = ""; PEND = 0 }
{
  if ($0 ~ /^[[:space:]]*#/) { flush(); next }
  if (NG > 0 && PEND == 0 && !attaches($0)) flush()
  NG++; GL[NG] = $0; GN[NG] = NR
  JOINED = JOINED " " $0
  PEND = wants_more($0)
}
END { flush() }
AWK_PROGRAM

# ── the borrowed classifier ───────────────────────────────────────────────────────────────────────
# verify-mutation-guard.sh's own scanner, lifted from that file at runtime rather than copied. It
# answers all three questions this detector cannot answer with a regex — which lines WRITE (quote- and
# comment-aware, so a printed repair hint is not a write), where the opt-in marker regions are, and
# where gitea_host() starts and ends. See the fifth-pass note for why a second copy is not acceptable.
MUTATION_GUARD="${LINT_DIR}/verify-mutation-guard.sh"

borrowed_mutation_scanner() {  # → the sibling guard's AWK_SCAN program text, empty if it cannot be lifted
  [[ -f "$MUTATION_GUARD" ]] || return 0
  awk 'p==1 && $0=="AWK_PROGRAM"{exit} p==1{print} $0 ~ /AWK_SCAN <</{p=1}' "$MUTATION_GUARD"
}
MUT_SCAN="$(borrowed_mutation_scanner)"

# ALWAYS-ON, both modes. Four shapes in nine lines: a function whose range must be found, a marker
# region whose bounds must be found, a PRINTED mutation that must NOT be classified as a write, a
# genuine read, and a genuine write. If the borrowed scanner stops answering any of them the way this
# detector needs, [1] refuses to report rather than silently excluding nothing (counts jump) or
# everything (counts vanish).
mutation_scanner_probe() {  # → 0 the borrowed scanner still classifies the way this guard needs
  local d out muts optin funcs
  [[ -n "$MUT_SCAN" ]] || return 1
  d="$(mktemp -d)" || return 1
  cat >"$d/probe.sh" <<'PROBE'
#!/usr/bin/env bash
gitea_host() {
  host="$(oc get route gitea -n ogsr-gitea -o jsonpath='{.spec.host}' 2>/dev/null || true)"
}
# ws-mutation-optin: fixture region — the probe asserts this guard can still see marker bounds
hint "repair it yourself: oc delete pod broken -n ${NS}"
oc get deploy x -n "$NS" -o name 2>/dev/null || true
oc scale deploy/y -n "$NS" --replicas=0 >/dev/null 2>&1 || true
# ws-mutation-optin-end
PROBE
  out="$(awk "$MUT_SCAN" "$d/probe.sh")"
  rm -rf "$d"
  funcs="$(printf '%s\n' "$out" | awk -F'\t' '$1=="FUNC"{printf "%s:%s-%s ", $2, $3, $4}')"
  muts="$(printf '%s\n' "$out"  | awk -F'\t' '$1=="MUT"{printf "%s:%s ", $2, $4}')"
  optin="$(printf '%s\n' "$out" | awk -F'\t' '$1=="OPTIN"{printf "%s-%s ", $2, $3}')"
  [[ "$funcs" == "gitea_host:2-4 " && "$muts" == "8:scale " && "$optin" == "5-9 " ]]
}

# Returns 1 — never an empty answer — when the borrowed classifier cannot be run over this file. An
# awk that fails to compile emits nothing, and "nothing" here would read as "no blind reads in this
# file": measured, a truncated borrow silently took EVERY file to zero and the whole guard to rc 0.
# The caller turns this into rc 2. Inspecting nothing is never a pass.
counted_read_lines() {  # <file> → the line numbers this detector counts, one per line; rc 1 = could not classify
  local f="$1" cand scan writes gh_s=0 gh_e=0 ln iswait i excluded
  cand="$(awk -v SIL="$OC_SILENCED_RE" "$AWK_LOGICAL" "$f")" || return 1
  [[ -n "$cand" ]] || return 0
  scan="$(awk "$MUT_SCAN" "$f")" || return 1

  # Space-delimited sets and index-addressed arrays, not associative ones: this runs on the bash 3.2
  # every maintainer's macOS ships. A TRAPBODY with a verb writes exactly as surely as a bare `oc
  # scale` does; one with an EMPTY verb (a trap naming a mutating function) is deliberately NOT
  # treated as a write here — the sibling resolves those in bash, and guessing would EXCLUDE lines,
  # which is the one direction this detector must never err in.
  writes=" $(printf '%s\n' "$scan" | awk -F'\t' '($1=="MUT")||($1=="TRAPBODY"&&$4!=""){printf "%s ", $2}')"
  local -a os=() oe=()
  while IFS=$'\t' read -r rec a b c; do
    case "$rec" in
      OPTIN) os+=("$a"); oe+=("$b") ;;
      FUNC)  [[ "$a" == "gitea_host" ]] && { gh_s="$b"; gh_e="$c"; } ;;
    esac
  done <<<"$scan"

  while IFS=$'\t' read -r ln iswait; do
    [[ -n "$ln" ]] || continue
    # gitea_host()'s route-then-domain fallback: excluded BY NAME, see the header.
    if [[ "$gh_s" -gt 0 && "$ln" -ge "$gh_s" && "$ln" -le "$gh_e" ]]; then continue; fi
    # The conjunction: inside a signed opt-in region AND not an object read.
    excluded=0
    if [[ "$writes" == *" ${ln} "* || "$iswait" == "1" ]]; then
      for (( i = 0; i < ${#os[@]}; i++ )); do
        if [[ "$ln" -ge "${os[i]}" && "$ln" -le "${oe[i]}" ]]; then excluded=1; break; fi
      done
    fi
    [[ "$excluded" -eq 1 ]] || printf '%s\n' "$ln"
  done <<<"$cand"
  return 0
}

check_no_new_raw_oc_devnull() {  # <verify-dir> → 0 within baseline, 1 a file exceeds it, 2 inspected nothing
  ran_check
  local dir="$1" f base lines actual base_count rc=0 n=0
  if ! mutation_scanner_probe; then
    bad "[1] could not borrow a working write/marker classifier from ${MUTATION_GUARD}."
    note "    This detector must tell a blind READ from a deliberately-quiet WRITE, and it does that"
    note "    with that guard's own awk scanner rather than a second copy of the logic. Without it,"
    note "    every count here would be wrong in one direction or the other — so it reports nothing."
    return 2
  fi
  shopt -s nullglob
  for f in "$dir"/*.sh; do
    n=$((n + 1))
    base="$(basename "$f")"
    if ! lines="$(counted_read_lines "$f")"; then
      shopt -u nullglob
      bad "[1] ${base}: the borrowed write/marker classifier could not be run over this file."
      note "    A classifier that fails emits nothing, and 'nothing' would read as 'no blind reads'"
      note "    — every file would silently go to zero. Refusing to report instead."
      return 2
    fi
    lines="$(printf '%s' "$lines" | tr '\n' ' ')"
    actual="$(printf '%s' "$lines" | wc -w | tr -d ' ')"
    base_count="$(baseline_for "$base")"
    if [[ "$actual" -gt "$base_count" ]]; then
      bad "[1] ${base}: ${actual} stderr-silenced 'oc' READ line(s) (2>/dev/null, >/dev/null 2>&1 or &>/dev/null), baseline allows ${base_count} (excess $((actual - base_count))). Lines: ${lines% }"
      note "    Each one hides a real API failure (throttling, an expired token, a blip) as a genuine"
      note "    absence — the attendee gets a false ❌ for correct work. Route it through oc_read /"
      note "    oc_present / oc_absent (tools/verify/_lib.sh) instead of adding another one."
      note "    A line whose redirect sits on a CONTINUATION line counts too, and a quiet WRITE inside"
      note "    a '# ws-mutation-optin:' region does not — so this list is reads, and only reads."
      rc=1
    fi
  done
  shopt -u nullglob
  if [[ "$n" -eq 0 ]]; then
    bad "[1] ${dir}: zero *.sh files found — this detector inspected nothing."
    return 2
  fi
  [[ "$rc" -eq 0 ]] && ok "[1] no tools/verify/*.sh file exceeds its recorded stderr-silenced-oc-read baseline"
  return "$rc"
}

# ── [2] shared-predicate shadowing ────────────────────────────────────────────────────────────────
check_no_local_predicate_shadow() {  # <verify-dir> → 0 none shadowed, 1 a module redefines a shared predicate, 2 inspected nothing
  ran_check
  local dir="$1" f base fn rc=0 n=0
  shopt -s nullglob
  for f in "$dir"/*.sh; do
    base="$(basename "$f")"
    [[ "$base" == "_lib.sh" ]] && continue   # the one legitimate definition site
    n=$((n + 1))
    for fn in deploy_ready deploy_ready_min cm_key_set; do
      if grep -qE "^${fn}\\(\\)[[:space:]]*\\{" "$f"; then
        bad "[2] ${base}: re-defines ${fn}(), which tools/verify/_lib.sh already provides."
        note "    A local copy silently SHADOWS the library for THIS caller only — the two definitions"
        note "    then drift apart while both look correct in isolation (the exact six-copies-of-a-"
        note "    walker failure tools/lint/_extract-func.sh was deduplicated to stop). Delete it, or"
        note "    move the change into _lib.sh so every caller gets it."
        rc=1
      fi
    done
  done
  shopt -u nullglob
  if [[ "$n" -eq 0 ]]; then
    bad "[2] ${dir}: zero non-_lib.sh *.sh files found — this detector inspected nothing."
    return 2
  fi
  [[ "$rc" -eq 0 ]] && ok "[2] no module verify script redefines deploy_ready / deploy_ready_min / cm_key_set"
  return "$rc"
}

# ── [3] the three-outcome contract, EXECUTED ─────────────────────────────────────────────────────────
# Fixtures for `oc`'s three real shapes (captured live 2026-08-01, same text _lib.sh's own header
# cites) plus a genuine success. Written once per run, not per case — cheap and avoids quoting the
# error text through multiple layers of sed/printf.
_write_oc_read_stubs() {  # <dir> → writes stub-notfound.sh / stub-forbidden.sh / stub-refused.sh / stub-success.sh
  local d="$1"
  cat > "${d}/stub-notfound.sh" <<'STUB'
oc() {
  printf ''
  printf 'Error from server (NotFound): deployments.apps "widget" not found\n' >&2
  return 1
}
STUB
  cat > "${d}/stub-forbidden.sh" <<'STUB'
oc() {
  printf ''
  printf 'Error from server (Forbidden): deployments.apps "widget" is forbidden: User "system:serviceaccount:x:y" cannot get resource "deployments" in API group "apps" in the namespace "ns"\n' >&2
  return 1
}
STUB
  cat > "${d}/stub-refused.sh" <<'STUB'
oc() {
  printf ''
  printf 'The connection to the server 127.0.0.1:6443 was refused - did you specify the right host or port?\n' >&2
  return 1
}
STUB
  cat > "${d}/stub-success.sh" <<'STUB'
oc() {
  printf '1'
  return 0
}
STUB
  # A failure that says NOTHING. This is the shape of `oc` killed before it could be told anything —
  # the OOM-killer, a timeout wrapper, SIGPIPE — and the one shape this detector did not have until
  # 2026-08-06, which is exactly why _lib.sh graded it as the server's real NO for as long as it did.
  # The detector was GREEN the whole time. rc 137 rather than 1 so the stub cannot be mistaken for a
  # NotFound whose message went missing.
  cat > "${d}/stub-silent.sh" <<'STUB'
oc() {
  printf ''
  return 137
}
STUB
}

# run_oc_read_case <lib-file> <stub-file> <oc-args…> → stdout "RC=<n> INCONCLUSIVE=<0|1> OUT=<text>"
#
# Runs under `set -euo pipefail`, exactly like the real verify scripts oc_read is written for — and
# the call is guarded with `|| rc=$?`, not bare, because a bare call whose function RETURNS non-zero
# (rc 1 or 2 are both non-zero BY DESIGN here) would itself be killed by that same `-e` before this
# harness ever reached its own reporting line. That is the identical trap CLAUDE.md's "set -e + cond
# && cmd" note describes for a different shape; this harness cannot demonstrate oc_read's contract
# while falling into it.
run_oc_read_case() {
  local lib="$1" stub="$2" script rc a
  shift 2
  script="$(mktemp)"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    cat "$stub"
    extract_func "$lib" oc_read
    printf 'OC_OUT=""; OC_ERR=""; VERIFY_INCONCLUSIVE=0\n'
    printf 'rc=0\n'
    printf 'oc_read'
    for a in "$@"; do printf ' %q' "$a"; done
    printf ' || rc=$?\n'
    # shellcheck disable=SC2016
    printf 'printf "RC=%%s INCONCLUSIVE=%%s OUT=%%s\\n" "$rc" "$VERIFY_INCONCLUSIVE" "$OC_OUT"\n'
  } > "$script"
  bash "$script" 2>/dev/null
  rc=$?
  rm -f "$script"
  return "$rc"
}

_oc_read_field() {  # <harness-output> <field-name> → value
  sed -nE "s/.*${2}=([^ ]*).*/\\1/p" <<< "$1"
}

check_oc_read_notfound_not_folded() {  # <lib-file-or-snippet> → 0 all three outcomes classified correctly, 1 wrong, 2 could not extract
  ran_check
  local lib="$1" rc=0 out got_rc got_inc
  local stubdir; stubdir="$(mktemp -d)"
  _write_oc_read_stubs "$stubdir"

  if [[ -z "$(extract_func "$lib" oc_read)" ]]; then
    bad "[3] oc_read() could not be extracted from ${lib} — this detector inspected nothing."
    rm -rf "$stubdir"
    return 2
  fi

  # (a) NotFound is a real NO — the exact regression: folding it into rc 0 made a missing-object
  # check PASS. Must stay rc=1, and must NOT raise VERIFY_INCONCLUSIVE (that would make it a ⚠, the
  # opposite mistake — an absence going ungraded instead of a false pass).
  out="$(run_oc_read_case "$lib" "${stubdir}/stub-notfound.sh" get deploy widget -n ns -o 'jsonpath={.status.readyReplicas}')"
  got_rc="$(_oc_read_field "$out" RC)"; got_inc="$(_oc_read_field "$out" INCONCLUSIVE)"
  if [[ "$got_rc" != "1" ]]; then
    bad "[3a] NotFound must classify as a real NO (rc=1); got rc=${got_rc:-<none>}. Output: ${out}"
    note "    Folding NotFound into rc 0 made a check for a missing PodDisruptionBudget PASS on a"
    note "    namespace that had none — the first draft of oc_read shipped exactly this."
    rc=1
  elif [[ "$got_inc" != "0" ]]; then
    bad "[3a] NotFound must NOT set VERIFY_INCONCLUSIVE; got ${got_inc:-<none>}. Output: ${out}"
    rc=1
  fi

  # (b) Forbidden — could not ask, ⚠ not ❌ (rule 10: not this identity's check to run).
  out="$(run_oc_read_case "$lib" "${stubdir}/stub-forbidden.sh" get deploy widget -n ns)"
  got_rc="$(_oc_read_field "$out" RC)"; got_inc="$(_oc_read_field "$out" INCONCLUSIVE)"
  if [[ "$got_rc" != "2" || "$got_inc" != "1" ]]; then
    bad "[3b] Forbidden must be 'could not ask' (rc=2, VERIFY_INCONCLUSIVE=1); got rc=${got_rc:-<none>} inconclusive=${got_inc:-<none>}. Output: ${out}"
    rc=1
  fi

  # (c) connection refused — could not ask, same as (b) but the transport-failure branch of the case.
  out="$(run_oc_read_case "$lib" "${stubdir}/stub-refused.sh" get deploy widget -n ns)"
  got_rc="$(_oc_read_field "$out" RC)"; got_inc="$(_oc_read_field "$out" INCONCLUSIVE)"
  if [[ "$got_rc" != "2" || "$got_inc" != "1" ]]; then
    bad "[3c] connection-refused must be 'could not ask' (rc=2, VERIFY_INCONCLUSIVE=1); got rc=${got_rc:-<none>} inconclusive=${got_inc:-<none>}. Output: ${out}"
    rc=1
  fi

  # (d) a genuine success must still classify as rc=0 — a detector that only ever demanded "not 0"
  # would trivially pass on ANY nonzero rc, including a NotFound miscategorized as could-not-ask.
  out="$(run_oc_read_case "$lib" "${stubdir}/stub-success.sh" get deploy widget -n ns -o 'jsonpath={.status.readyReplicas}')"
  got_rc="$(_oc_read_field "$out" RC)"
  if [[ "$got_rc" != "0" ]]; then
    bad "[3d] a genuine oc success must classify as rc=0; got rc=${got_rc:-<none>}. Output: ${out}"
    rc=1
  fi

  # (e) a failure with NOTHING on stderr — "could not ask", never the server's real NO. Added
  # 2026-08-06 after measuring that _lib.sh graded it rc=1, i.e. IDENTICALLY to a genuine NotFound:
  # an OOM-killed read and a genuinely absent object produced the same ❌ against the attendee. Note
  # what this says about (a)-(d): they were all GREEN while that hole was open, because none of them
  # supplied an empty stderr. A contract test proves the cases it enumerates and nothing else, so the
  # honest reading of a green [3] is "these four shapes classify correctly", never "the contract holds".
  #
  # This cannot re-open (a): that regression upgraded a real, TEXT-carrying answer to success. This
  # downgrades a NO-TEXT non-answer to inconclusive. Opposite directions, and (a) still runs.
  out="$(run_oc_read_case "$lib" "${stubdir}/stub-silent.sh" get deploy widget -n ns)"
  got_rc="$(_oc_read_field "$out" RC)"; got_inc="$(_oc_read_field "$out" INCONCLUSIVE)"
  if [[ "$got_rc" != "2" || "$got_inc" != "1" ]]; then
    bad "[3e] a failure with EMPTY stderr must be 'could not ask' (rc=2, VERIFY_INCONCLUSIVE=1); got rc=${got_rc:-<none>} inconclusive=${got_inc:-<none>}. Output: ${out}"
    note "    Every genuine NO the server sends carries text (NotFound prints a message). Silence"
    note "    means oc never got far enough to be told anything — signal-killed, OOM, dead early."
    note "    Grading that a real NO manufactures a ❌ against an attendee whose cluster simply could"
    note "    not be reached, and CLAUDE.md is explicit that one false ❌ destroys every other ✅."
    rc=1
  fi

  rm -rf "$stubdir"
  [[ "$rc" -eq 0 ]] && ok "[3] oc_read: NotFound stays a real NO; Forbidden, connection-refused and a silent failure all stay 'could not ask'; success stays a pass"
  return "$rc"
}

# ── driver ────────────────────────────────────────────────────────────────────────────────────────
run_check() {  # <verify-dir> <lib-file> → 0 clean · 1 finding(s) · 2 could not inspect
  coverage_reset
  local dir="$1" lib="$2" rc=0 one=0

  check_no_new_raw_oc_devnull "$dir" || one=$?
  [[ "$one" -gt "$rc" ]] && rc="$one"

  one=0; check_no_local_predicate_shadow "$dir" || one=$?
  [[ "$one" -gt "$rc" ]] && rc="$one"

  one=0; check_oc_read_notfound_not_folded "$lib" || one=$?
  [[ "$one" -gt "$rc" ]] && rc="$one"

  if [[ "$rc" -ne 2 ]]; then
    assert_all_checks_ran || rc=2
  fi
  return "$rc"
}

# ── canaries ─────────────────────────────────────────────────────────────────────────────────────
# Each canary is a real copy of the tree's own tools/verify/*.sh with ONE defect injected — an empty
# fixture trips every detector at once and proves nothing about any of them.
_canary_verify_dir() {  # [target-basename] [sed-expr] → a temp copy of tools/verify/ with the edit applied
  local target="$1" expr="$2" d
  d="$(mktemp -d)"
  cp "${VERIFY_DIR}"/*.sh "$d"/
  if [[ -n "$target" ]]; then
    sed -i.bak "$expr" "${d}/${target}"
    rm -f "${d}/${target}.bak"
  fi
  printf '%s' "$d"
}

# A continuation canary is two physical lines by definition, which sed's `$a\` cannot append
# portably — so those fixtures are `cat >>` heredocs onto a plain `_canary_verify_dir '' ''` copy.
#
# THE HEREDOC MUST NOT SIT INSIDE `$( … )`. Written as `d="$(_canary_append f <<'FIX' … FIX)"` the
# fixture arrives as ONE line: bash's command-substitution reader applies backslash-newline joining to
# the heredoc body even though the delimiter is QUOTED (measured on bash 3.2, 2026-08-01 — two lines
# in, one line out). A continuation canary that collapses into a single line is INERT: it still fails
# the ratchet, so it still looks like a pass, but it is testing the shape the guard already caught.
# Found by blinding the join and watching the canary keep passing. Keep the append at statement level.

_expect_rc() {  # <label> <want-rc> <got-rc> → 0 match, 1 mismatch (and prints)
  local label="$1" want="$2" got="$3"
  if [[ "$got" -ne "$want" ]]; then
    bad "SELF-TEST FAILED: ${label} → rc=${got}, expected ${want}."
    return 1
  fi
  return 0
}

# Extracts oc_read verbatim and flips its ONE `return 1` (the NotFound/default case arm) to
# `return 0` — reproducing 51eb1b6's own first-draft regression, not a made-up mutation.
_build_notfound_folding_canary() {  # → path to a temp file containing the mutated oc_read()
  local body mutated tmp
  body="$(extract_func "$LIB_SH" oc_read)"
  if [[ -z "$body" ]]; then
    bad "could not extract oc_read() from ${LIB_SH} to build the NotFound-folding canary."
    return 2
  fi
  mutated="${body/return 1/return 0}"
  if [[ "$mutated" == "$body" ]]; then
    bad "could not build the NotFound-folding canary — no 'return 1' found in the extracted oc_read() to mutate."
    return 2
  fi
  tmp="$(mktemp)"
  printf '%s\n' "$mutated" > "$tmp"
  printf '%s' "$tmp"
}

# The mutation for canary [3e]: remove oc_read's empty-stderr guard so a silent failure falls through
# to the `case`'s `*)` arm again — i.e. reintroduce the exact 2026-08-06 defect, where an OOM-killed
# read and a genuinely absent object both became a ❌ against the attendee.
#
# THE ANCHOR MUST CONTAIN NO GLOB METACHARACTERS, and the first draft of this function is why that
# sentence is here. `${var/pattern/repl}` matches `pattern` as a GLOB, not as a literal, so an anchor
# written as `if [[ -z "${OC_ERR// /}" ]]; then` has its `[[ … ]` read as a bracket expression — a
# one-character class. It matched SOMETHING, somewhere else in the body, so the "did the mutation
# land?" check below was satisfied while the guard clause was never touched. The canary then passed
# because a DIFFERENT case failed on a differently-broken mutant. Caught 2026-08-06 by blinding [3e]
# and watching --self-test stay green; `mutated != body` distinguishes "changed something" from
# "changed nothing", which is not the same as "changed the right thing".
#
# So: anchor on `-z "${OC_ERR// /}"`, which is glob-safe (`{`, `}`, `$`, `/`, `"` are all literal in a
# bash pattern) and unique inside oc_read — the only other OC_ERR emptiness test is `-n`, the klog
# fallback. Flipping it to a non-empty literal makes the condition false and disables the clause
# without changing its shape, so the mutant differs from the real body in exactly one predicate.
_build_silent_failure_canary() {  # → path to a temp file containing oc_read() with the guard disabled
  local body mutated tmp
  body="$(extract_func "$LIB_SH" oc_read)"
  if [[ -z "$body" ]]; then
    bad "could not extract oc_read() from ${LIB_SH} to build the silent-failure canary."
    return 2
  fi
  # sed with a `|` delimiter, NOT bash's ${var/pat/rep}. Two separate reasons, both measured here on
  # 2026-08-06: (i) ${var/…} matches its pattern as a GLOB, so `[[` becomes a bracket expression;
  # (ii) escaping `$`, `/` and `"` through ${var/…} to dodge that produced a mutant that did not
  # PARSE — every case then came back `rc=<none>`, which still made [3e] "fire" and the canary still
  # "pass". A broken mutant is the most dangerous kind: it fails everything, so it satisfies any
  # assertion phrased as "something failed". In BRE with `|` as the delimiter, `$` mid-pattern, `{`,
  # `}` and `"` are all literal and no escaping is needed at all.
  # shellcheck disable=SC2016  # the single quotes are the POINT: this is a literal source-text
  # pattern matched against oc_read's body, not an expression to expand. Expanding ${OC_ERR// /}
  # here would substitute this process's own (empty) OC_ERR and the anchor would match nothing —
  # turning the canary inert in precisely the way the header above documents.
  mutated="$(printf '%s\n' "$body" | sed 's|-z "${OC_ERR// /}"|-z "canary-guard-disabled"|')"
  if [[ "$mutated" == "$body" ]]; then
    bad "could not build the silent-failure canary — oc_read()'s empty-stderr guard was not found by" \
        "its condition text. It was either renamed or REMOVED; if removed, that is the 2026-08-06" \
        "regression itself and [3e] is what should be telling you. Do not 'fix' this by loosening" \
        "the anchor: a canary that mutates the wrong thing passes for the wrong reason."
    return 2
  fi
  tmp="$(mktemp)"
  printf '%s\n' "$mutated" > "$tmp"
  printf '%s' "$tmp"
}

self_test() {
  local bad_seen=0 d got mutated_file cov

  # Proof 0: the real tree passes. A guard that fires on everything proves nothing.
  got=0; run_check "$VERIFY_DIR" "$LIB_SH" >/dev/null 2>&1 || got=$?
  if ! _expect_rc "the real tools/verify/ tree satisfies the contract" 0 "$got"; then
    bad "run 'bash tools/lint/verify-oc-read-guard.sh' without --self-test to see the finding."
    return 2
  fi

  # Canary [1]-A — a file's ratchet exceeded: one new raw 'oc … 2>/dev/null' appended beyond baseline.
  # shellcheck disable=SC2016  # sed PROGRAM text: this is fixture source for the copy, not an expansion.
  d="$(_canary_verify_dir platform-orientation.sh '$a\
oc get secret ratchet-canary -n foo -o jsonpath="{.data.x}" 2>/dev/null')"
  got=0; check_no_new_raw_oc_devnull "$d" >/dev/null 2>&1 || got=$?
  rm -rf "$d"
  _expect_rc "canary [1]-A (a file's ratchet baseline exceeded)" 1 "$got" || bad_seen=1

  # Canary [1]-B — a brand-new file (absent from BASELINE_TABLE, i.e. baseline 0) with one occurrence.
  # This is what a NEW module's verify script introducing the shape for the first time looks like.
  d="$(_canary_verify_dir '' '')"
  printf 'oc get secret new-module-canary -n foo -o jsonpath="{.data.x}" 2>/dev/null\n' > "${d}/zzz-not-a-real-module.sh"
  got=0; check_no_new_raw_oc_devnull "$d" >/dev/null 2>&1 || got=$?
  rm -rf "$d"
  _expect_rc "canary [1]-B (unlisted file, baseline 0, one occurrence)" 1 "$got" || bad_seen=1

  # Canary [1]-C — gitea_host()'s named exclusion, isolated: a fixture containing ONLY its real
  # two-line fallback (both lines DO match the raw shape) must stay clean against its unlisted (0)
  # baseline, or the exclusion is not actually applied.
  d="$(mktemp -d)"
  cat > "${d}/only-gitea-host.sh" <<'FIXTURE'
gitea_host() {
  local host domain
  host="$(oc get route gitea -n ogsr-gitea -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -z "$host" ]]; then
    domain="$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
    [[ -n "$domain" ]] && host="gitea-ogsr-gitea.${domain}"
  fi
  echo "$host"
}
FIXTURE
  got=0; check_no_new_raw_oc_devnull "$d" >/dev/null 2>&1 || got=$?
  rm -rf "$d"
  _expect_rc "canary [1]-C (gitea_host's own fallback excluded, isolated fixture)" 0 "$got" || bad_seen=1

  # Canary [1]-D — a pure curl probe (no 'oc' token at all) must stay clean, unlisted baseline or not.
  d="$(mktemp -d)"
  cat > "${d}/only-curl.sh" <<'FIXTURE'
probe() { curl -ksf --max-time 15 "https://example.com/health" 2>/dev/null | grep -q ok; }
FIXTURE
  got=0; check_no_new_raw_oc_devnull "$d" >/dev/null 2>&1 || got=$?
  rm -rf "$d"
  _expect_rc "canary [1]-D (pure curl probe stays clean)" 0 "$got" || bad_seen=1

  # Canary [1]-E — the `>/dev/null 2>&1` shape, which this detector was blind to until 2026-08-01.
  # Appended to a file at its recorded baseline, so ONLY the extended matcher can turn it into a
  # finding: with the old literal-'2>/dev/null' matcher this canary is silently clean.
  # shellcheck disable=SC2016  # sed PROGRAM text: fixture source for the copy, not an expansion.
  d="$(_canary_verify_dir platform-orientation.sh '$a\
oc get ns default >/dev/null 2>&1')"
  got=0; check_no_new_raw_oc_devnull "$d" >/dev/null 2>&1 || got=$?
  rm -rf "$d"
  _expect_rc "canary [1]-E ('>/dev/null 2>&1' existence probe, the shape the detector used to miss)" 1 "$got" || bad_seen=1

  # Canary [1]-F — the `&>/dev/null` shorthand, the one-character bypass of [1]-E. Zero instances in
  # the tree today, which is exactly why it needs a canary rather than a measurement.
  d="$(mktemp -d)"
  cat > "${d}/only-ampersand.sh" <<'FIXTURE'
route_present() { oc get route parasol-web -n "$1" &>/dev/null; }
FIXTURE
  got=0; check_no_new_raw_oc_devnull "$d" >/dev/null 2>&1 || got=$?
  rm -rf "$d"
  _expect_rc "canary [1]-F ('&>/dev/null' shorthand, unlisted file at baseline 0)" 1 "$got" || bad_seen=1

  # Canary [1]-G — the NEGATIVE canary for the extension: `2>&1 >/dev/null` REVERSES the order, so
  # stderr goes to the original stdout and is captured while stdout is discarded. That keeps the
  # diagnosis rather than silencing it, and jobs-batch-kueue.sh:198 does exactly this on purpose.
  # Without this canary a lazily-widened regex would quietly start punishing the good shape.
  d="$(mktemp -d)"
  cat > "${d}/only-captured-stderr.sh" <<'FIXTURE'
cq_probe() { cq_err="$(oc get clusterqueue "$1" -o name 2>&1 >/dev/null || true)"; }
FIXTURE
  got=0; check_no_new_raw_oc_devnull "$d" >/dev/null 2>&1 || got=$?
  rm -rf "$d"
  _expect_rc "canary [1]-G (NEGATIVE: '2>&1 >/dev/null' captures stderr and must stay clean)" 0 "$got" || bad_seen=1

  # Canary [1]-H — the CONTINUATION shape: the `oc` token and the `2>/dev/null` on different physical
  # lines. Neither line matches on its own, which is exactly how four of these survived every earlier
  # pass. Appended to a file already AT its baseline, so only the logical-line matcher can find it.
  d="$(_canary_verify_dir '' '')"
  cat >> "${d}/platform-orientation.sh" <<'FIXTURE'
oc get pipelineruns.tekton.dev -n foo -l tekton.dev/pipeline=continuation-canary \
  -o jsonpath='{range .items[*]}{.status.conditions[0].status}{"\n"}{end}' 2>/dev/null | grep -qx True
FIXTURE
  got=0; check_no_new_raw_oc_devnull "$d" >/dev/null 2>&1 || got=$?
  rm -rf "$d"
  _expect_rc "canary [1]-H (silenced read split across a backslash continuation)" 1 "$got" || bad_seen=1

  # Canary [1]-H2 — the OTHER split: no backslash at all, the pipeline broken at the operator. Two
  # reads, one per direction — the first leaves the operator LEADING the next line, the second leaves
  # it TRAILING the current one. Zero instances in tools/verify/ today (every continuation there is a
  # backslash), which is precisely why they need a canary and not a measurement — the same argument
  # `&>/dev/null` is matched under. Blinding the operator joins while leaving the backslash join in
  # place is caught by this canary and by nothing else.
  d="$(_canary_verify_dir '' '')"
  cat >> "${d}/platform-orientation.sh" <<'FIXTURE'
oc get pods -n foo -l app=chain-canary -o name
  | grep -q parasol 2>/dev/null
oc get cm split-canary -n foo -o name |
  grep -q data 2>/dev/null
FIXTURE
  got=0; check_no_new_raw_oc_devnull "$d" >/dev/null 2>&1 || got=$?
  rm -rf "$d"
  _expect_rc "canary [1]-H2 (pipeline split with no backslash — operator trailing, and operator leading)" 1 "$got" || bad_seen=1

  # Canary [1]-I — the NEGATIVE canary for the write exclusion. Every shape of failover_drill's floor
  # of six: an annotate, the restore trap, two scales and a rollout-status wait, all inside a signed
  # marker region — plus a continued `oc get` that silences NOTHING, which the logical-line matcher
  # must not sweep up. An unlisted file, so its baseline is 0: anything counted here fails. Without
  # this canary a future widening could quietly start punishing writes again, which is the churn the
  # fourth pass refused to do in the one region of this suite where churn is most expensive.
  d="$(mktemp -d)"
  cat > "${d}/only-marked-writes.sh" <<'FIXTURE'
gitea_route() {
  oc get route gitea -n ogsr-gitea \
    -o jsonpath='{.spec.host}' || true
}
# ws-mutation-optin: the drill takes the primary site down; only --failover-drill asks for it
failover_drill() {
  oc annotate deploy/parasol-claims -n "$SITEA_NS" --overwrite "${DRILL_ANN}=${orig}" >/dev/null 2>&1 || true
  trap 'oc scale deploy/parasol-claims -n "$SITEA_NS" --replicas="${SITEA_RESTORE:-3}" >/dev/null 2>&1 || true' EXIT INT TERM HUP
  oc scale deploy/parasol-claims -n "$SITEA_NS" --replicas=0 >/dev/null 2>&1 || true
  oc scale deploy/parasol-claims -n "$SITEA_NS" --replicas="$orig" >/dev/null 2>&1 || true
  oc rollout status deploy/parasol-claims -n "$SITEA_NS" --timeout=60s >/dev/null 2>&1 || true
  oc annotate deploy/parasol-claims -n "$SITEA_NS" "${DRILL_ANN}-" >/dev/null 2>&1 || true
  trap - EXIT INT TERM HUP
}
# ws-mutation-optin-end
FIXTURE
  got=0; check_no_new_raw_oc_devnull "$d" >/dev/null 2>&1 || got=$?
  rm -rf "$d"
  _expect_rc "canary [1]-I (NEGATIVE: marked WRITES and a silence-free continuation stay clean)" 0 "$got" || bad_seen=1

  # Canary [1]-J — the other half of the conjunction, and the reason the basis is not "marker alone".
  # The SAME marker region, with one blind READ added inside it. A marker says "a write lives here",
  # never "stop grading reads here" — nothing in verify-mutation-guard's D4 stops the next author
  # putting an `oc get … 2>/dev/null` in a region that already contains a write, and that would be the
  # same silent under-report this whole pass exists to end.
  d="$(mktemp -d)"
  cat > "${d}/read-inside-marker.sh" <<'FIXTURE'
# ws-mutation-optin: the drill takes the primary site down; only --failover-drill asks for it
failover_drill() {
  have="$(oc get deploy parasol-claims -n "$SITEA_NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
  oc scale deploy/parasol-claims -n "$SITEA_NS" --replicas=0 >/dev/null 2>&1 || true
}
# ws-mutation-optin-end
FIXTURE
  got=0; check_no_new_raw_oc_devnull "$d" >/dev/null 2>&1 || got=$?
  rm -rf "$d"
  _expect_rc "canary [1]-J (a blind READ inside a marker region is still counted)" 1 "$got" || bad_seen=1

  # Canary [1]-K — the borrowed classifier is load-bearing, so losing it must be rc=2 (could not
  # inspect), never rc=0. Blinding the borrow is the one failure that would silently turn every write
  # in the tree back into a "read" — or, with the exclusion inverted, hide every read.
  (
    MUT_SCAN=""
    got=0; check_no_new_raw_oc_devnull "$VERIFY_DIR" >/dev/null 2>&1 || got=$?
    [[ "$got" -eq 2 ]]
  ) || { bad "SELF-TEST FAILED: an unavailable write/marker classifier did not force rc=2."; bad_seen=1; }

  # Canary [1]-L — the same failure one step later, and the one that was NOT loud when this pass was
  # written: a classifier that is present at probe time but fails while scanning a file emits nothing,
  # and an empty answer read as "no blind reads here" took every file to zero and the whole guard to
  # rc 0. Measured by truncating the borrowed program with the probe also blinded. Must be rc 2.
  (
    # shellcheck disable=SC2317,SC2329  # called indirectly by the detector under test in this subshell
    counted_read_lines() { return 1; }
    got=0; check_no_new_raw_oc_devnull "$VERIFY_DIR" >/dev/null 2>&1 || got=$?
    [[ "$got" -eq 2 ]]
  ) || { bad "SELF-TEST FAILED: a classifier that fails mid-scan produced a PASS instead of rc=2."; bad_seen=1; }

  # Canary [2] — a module script shadows a shared predicate with a local copy.
  d="$(_canary_verify_dir platform-orientation.sh '1i\
deploy_ready() { return 0; }')"
  got=0; check_no_local_predicate_shadow "$d" >/dev/null 2>&1 || got=$?
  rm -rf "$d"
  _expect_rc "canary [2] (deploy_ready() shadowed locally)" 1 "$got" || bad_seen=1

  # Canary [3] — the NotFound-folding regression, byte-for-byte: oc_read's one `return 1` flipped to
  # `return 0`. Must be caught, and must be caught specifically on the NotFound case (not by accident
  # on the success case, which the mutation does not touch).
  mutated_file="$(_build_notfound_folding_canary)"
  if [[ -z "$mutated_file" ]]; then
    bad "SELF-TEST FAILED: could not build the NotFound-folding canary."
    return 2
  fi
  got=0; check_oc_read_notfound_not_folded "$mutated_file" >/dev/null 2>&1 || got=$?
  rm -f "$mutated_file"
  _expect_rc "canary [3] (NotFound folded into rc 0, oc_read's first-draft regression)" 1 "$got" || bad_seen=1

  # Canary [3e] — REVERTING the 2026-08-06 silent-failure fix must be caught. This one exists because
  # its absence was itself the bug: for as long as _lib.sh graded an empty stderr as the server's real
  # NO, this detector was GREEN, because none of cases (a)-(d) ever supplied an empty stderr. A
  # contract test proves the cases it enumerates and nothing else.
  #
  # The mutation deletes the guard clause by name rather than by line, so it cannot silently become a
  # no-op if the file moves — and if the clause is ever renamed, the builder below fails loudly
  # instead of leaving a canary that proves nothing. That distinction is the whole lesson of this
  # file: an inert canary and a passing one are indistinguishable from the exit code alone.
  mutated_file="$(_build_silent_failure_canary)"
  if [[ -z "$mutated_file" ]]; then
    bad "SELF-TEST FAILED: could not build the silent-failure canary."
    return 2
  fi
  # RC IS NOT THE ASSERTION HERE — the reported SENTENCE is. `check_oc_read_notfound_not_folded`
  # returns 1 if ANY of its five cases fails, so "rc 1" is satisfied by a mutant that broke something
  # else entirely. That is not a hypothetical: the first draft of this canary mutated the wrong text
  # (see _build_silent_failure_canary's header) and passed on rc alone while [3e] never fired. Blind
  # [3e] and this must go red; blind any other case and it must not. Requiring the "[3e]" prefix back
  # is what makes that true, and it is the same fix the Dev Spaces guard needed for the same reason.
  # ONLY [3e] MAY FIRE. Requiring the [3e] sentence is necessary but NOT sufficient: a mutant that
  # fails to parse reports every case as `rc=<none>`, which fires [3e] too and would sign this canary
  # off on a mutant that proves nothing. Measured, not imagined — the second draft of this canary did
  # exactly that. So the assertion is two-sided: [3e] must be reported AND no sibling case may be,
  # which is only true when the mutant still runs and differs in precisely the one predicate.
  got=0; mutant_out="$(check_oc_read_notfound_not_folded "$mutated_file" 2>&1)" || got=$?
  rm -f "$mutated_file"
  siblings=""
  for _c in 3a 3b 3c 3d; do
    [[ "$mutant_out" == *"[${_c}]"* ]] && siblings="${siblings}${_c} "
  done
  if [[ "$got" -ne 1 || "$mutant_out" != *"[3e]"* || -n "$siblings" ]]; then
    bad "SELF-TEST FAILED: canary [3e] (empty-stderr failure graded as the server's real NO — a" \
        "false ❌ for an unreachable cluster) → rc=${got}, wanted rc 1 with a [3e] finding and NO" \
        "sibling findings.${siblings:+ Siblings also fired: ${siblings}— the mutant is broken rather}" \
        "${siblings:+than narrowly disabled, so this canary would prove nothing.}" \
        "Reported: ${mutant_out:-<nothing>}"
    bad_seen=1
  fi

  # Canary — coverage wiring: a detector declared but never called by run_check must be rc=2, never
  # silently tolerated. Mirrors cohort-ops-guard.sh's own canary F.
  cov=0
  (
    # shellcheck disable=SC2317,SC2329
    check_never_called() { ran_check; return 0; }
    run_check "$VERIFY_DIR" "$LIB_SH" >/dev/null 2>&1
  ) || cov=$?
  if [[ "$cov" -ne 2 ]]; then
    bad "SELF-TEST FAILED: a declared-but-never-called detector was not caught (rc=${cov}) — the coverage assertion is inert."
    bad_seen=1
  fi

  if [[ "$bad_seen" -ne 0 ]]; then
    return 2
  fi
  ok "self-test ok — ratchet-exceeded, unlisted-file, '>/dev/null 2>&1', '&>/dev/null', a read split"
  ok "   across a CONTINUATION, a blind read inside a marker region, a lost classifier (rc 2), predicate"
  ok "   shadow, NotFound-folding and an uncalled detector all caught; gitea_host exclusion, pure-curl"
  ok "   probe, the stderr-CAPTURING '2>&1 >/dev/null' shape and a marked WRITE all stay clean; real"
  ok "   tree within baseline."
  # House convention: --self-test exits EXACTLY 1 when every canary was correctly caught.
  return 1
}

parse_guard_args "$@"

if [[ "$GUARD_SELF_TEST" -eq 1 ]]; then
  self_test
  exit $?
fi

if [[ ! -d "$VERIFY_DIR" ]]; then
  bad "${VERIFY_DIR} not found"
  exit 2
fi
if [[ ! -f "$LIB_SH" ]]; then
  bad "${LIB_SH} not found"
  exit 2
fi
RC=0
run_check "$VERIFY_DIR" "$LIB_SH" || RC=$?
if [[ "$RC" -eq 0 ]]; then
  ok "verify-oc-read-guard: no new stderr-silenced 'oc' reads beyond baseline, no shared-predicate shadowing, oc_read's three-outcome contract intact."
fi
exit "$RC"
