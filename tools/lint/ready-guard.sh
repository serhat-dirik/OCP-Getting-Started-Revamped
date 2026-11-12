#!/usr/bin/env bash
# ready-guard.sh — drives `adm ready` (cmd_ready in tools/ws/ws) with its checks stubbed, no cluster.
#
# Asserts: [green] every check green → rc 0 and "workshop ready"; [red] one check red at the deadline →
# rc 1 and the red check named; [doctor] the slow doctor sweep is not run while a cheap check is red;
# [parse] --timeout spellings. --self-test swaps in a cmd_ready that always says ready: the guard must
# catch it and exit EXACTLY 1.
set -euo pipefail
# shellcheck source=tools/lint/_parse-guard-args.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_parse-guard-args.sh"
parse_guard_args "$@"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export WS_AUDIENCE=admin
# shellcheck source=/dev/null
source "${ROOT}/tools/ws/ws"
set +e
need_oc() { :; }
fails=0
bad() { echo "❌ [$1] $2"; fails=$((fails + 1)); }

if [[ "$GUARD_SELF_TEST" -eq 1 ]]; then
  cmd_ready() { echo "✅ workshop ready in 0 min"; return 0; }   # canary: a ready that never waits
fi

for c in $READY_CHECKS; do eval "ready_${c}() { echo stub; }"; done
out="$(cmd_ready --timeout 0s --interval 0s 2>&1)"; rc=$?
[[ "$rc" -eq 0 && "$out" == *"workshop ready"* ]] || bad green "all green should exit 0, got rc=${rc}"

doctor_ran="$(mktemp)"; trap 'rm -f "$doctor_ran"' EXIT
ready_istags() { echo "missing: x/y:z"; return 1; }
ready_doctor() { echo ran > "$doctor_ran"; echo stub; }
out="$(cmd_ready --timeout 0s --interval 0s 2>&1)"; rc=$?
[[ "$rc" -eq 1 ]] || bad red "a red check at the deadline should exit 1, got rc=${rc}"
grep -q '❌ istags .*missing: x/y:z' <<< "$out" || bad red "the red check is not named in the output"
[[ ! -s "$doctor_ran" ]] || bad doctor "doctor ran while a cheap check was red"

for t in 60m=3600 90s=90 2h=7200 45=45; do
  [[ "$(ready_parse_timeout "${t%=*}" 2>/dev/null)" == "${t#*=}" ]] || bad parse "${t%=*} should be ${t#*=}s"
done
for t in "" m 5x -1; do ready_parse_timeout "$t" >/dev/null 2>&1 && bad parse "'${t}' should be refused"; done

if [[ "$fails" -gt 0 ]]; then echo "ready-guard: ${fails} failure(s)"; exit 1; fi
echo "✅ ready-guard: cmd_ready waits, names what is red, and parses its timeout"
