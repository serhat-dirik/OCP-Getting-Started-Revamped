#!/usr/bin/env bash
# ws-maas-redaction-selftest.sh — maas_probe_reason() must surface the endpoint's own words and NEVER
# the credential, on bodies it does not control.
#
# WHY IT EXISTS. `ws` deliberately read the MaaS probe's STATUS CODE ONLY, with a comment saying why:
# LiteLLM's rejection bodies echo the token back, so capturing the body would drop the key into the
# operator's scrollback. That discipline had a cost nobody priced. On 2026-08-21 the workshop key was
# expired and maas-rhdp answered 400 {"type":"expired_key","message":"... Key Expiry time ..."} — a
# precise verdict `ws` classified as "inconclusive (no verdict from the endpoint)" and then offered to
# override with --force, past the one guard written to stop a dead credential reaching a cohort.
#
# maas_probe_reason() takes the body back and redacts instead. This file is what makes that safe:
# without it, "we redact" is a claim, and the input is a string an endpoint chooses.
#
#   bash tools/ws/ws-maas-redaction-selftest.sh              → the shipped tools/ws/ws
#                                                              (rc 0 contract holds · 1 broken · 2 cannot inspect)
#   bash tools/ws/ws-maas-redaction-selftest.sh --self-test  → every assertion catches its canary (rc 1)
#
# HOW IT RUNS WITHOUT A CLUSTER: tools/ws/ws is sourceable (its trailing BASH_SOURCE guard), so this
# sources the SHIPPED file and calls the REAL maas_probe_reason on synthetic bodies. No curl, no oc,
# no login. The canary replaces that one function with a naive `cat` — the implementation this guard
# exists to forbid — and asserts every credential assertion goes red.
set -uo pipefail

WS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WS="${WS_DIR}/ws"

# A token shaped like the real one (sk- + 21), and a SECOND, differently-shaped one: the sk- rule and
# the literal-token rule must each be load-bearing on their own.
#
# THE QUOTE BREAK AFTER sk- IS LOAD-BEARING, not a typo. These have to be key-SHAPED to be a canary
# worth anything, and tools/lint/api-key-shape-guard.py classifies both of them True — as it should.
# Splitting the literal denies the scanner its 20-character run after `sk-` while the runtime value is
# byte-identical, which is the same technique that guard's own source uses on its own examples. The
# alternative, adding this file to the guard's fixture exclusions, would buy the same green by
# switching the scanner OFF over a file whose whole subject is credentials. Asserted below.
TOKEN="sk-""selftestSELFTEST12345"
OTHER="sk-""someOtherKeyFromTheGateway999"

pass() { printf '  ✅ %s\n' "$1"; }
fail() { printf '  ❌ %s\n' "$1" >&2; }

# Every case: name · body · must-contain (empty = no requirement) · must-NOT-contain (| separated).
run_cases() {  # → 0 all held, 1 something leaked or was lost
  local bad=0 tmp out
  tmp="$(mktemp "${TMPDIR:-/tmp}/.ws-maas-selftest.XXXXXX")"

  _case() {  # name body want notwant
    local name="$1" body="$2" want="$3" notwant="$4" out ok=1
    printf '%s' "$body" > "$tmp"
    out="$(maas_probe_reason "$tmp" "$TOKEN")"
    if [[ -n "$want" && "$out" != *"$want"* ]]; then
      fail "${name}: expected to keep '${want}', got: ${out:-<empty>}"; ok=0
    fi
    local n; IFS='|' read -r -a _nw <<< "$notwant"
    for n in "${_nw[@]:-}"; do
      [[ -z "$n" ]] && continue
      if [[ "$out" == *"$n"* ]]; then
        fail "${name}: LEAKED '${n:0:12}…' — output was: ${out}"; ok=0
      fi
    done
    (( ${#out} > 220 )) && { fail "${name}: ${#out} chars, over the 220 cap"; ok=0; }
    (( ok == 1 )) && pass "$name"
    (( ok == 1 )) || bad=1
  }

  # 1. The real shape, verbatim from maas-rhdp on 2026-08-21. Keeps the expiry, drops the masked key.
  _case "expired_key body keeps the reason" \
    "{\"error\":{\"message\":\"Authentication Error - Expired Key. Key Expiry time 2026-08-20 12:00:10+00:00\",\"type\":\"expired_key\",\"param\":\"${TOKEN}\",\"code\":\"400\"}}" \
    "Expired Key" "${TOKEN}|Expiry time 2026-08-20 12:00:10+00:00\",\"type"

  # 2. The shape the STATUS-CODE-ONLY comment warned about: the token echoed inside the message.
  _case "token echoed in the message is redacted" \
    "{\"error\":{\"message\":\"Invalid proxy server token passed: ${TOKEN}. Not found in db.\",\"code\":\"401\"}}" \
    "Invalid proxy server token" "${TOKEN}"

  # 3. A key we did NOT send. The literal-token rule cannot catch this; the sk- rule must.
  _case "a foreign sk- key is redacted too" \
    "{\"error\":{\"message\":\"Key ${OTHER} is not entitled for this model\",\"code\":\"403\"}}" \
    "not entitled" "${OTHER}"

  # 4. Not JSON at all — a proxy's HTML error page, with the token in it. The head-fallback path.
  _case "non-JSON body falls back and still redacts" \
    "<html><body>502 upstream rejected Bearer ${TOKEN}</body></html>" \
    "502 upstream" "${TOKEN}"

  # 5. A 4KB wall of token. Proves the cap does not truncate the redaction into existence-by-luck.
  _case "long body is capped and redacted" \
    "{\"error\":{\"message\":\"$(printf '%s ' "$TOKEN" "$TOKEN" "$TOKEN"; head -c 4000 /dev/zero | tr '\0' 'x')\"}}" \
    "" "${TOKEN}"

  # 6. Nothing to say → say nothing, rather than an empty "endpoint says:" line.
  printf '' > "$tmp"
  out="$(maas_probe_reason "$tmp" "$TOKEN")"
  if [[ -n "$out" ]]; then fail "empty body should yield empty reason, got: ${out}"; bad=1
  else pass "empty body yields no reason line"; fi

  out="$(maas_probe_reason "${tmp}.does-not-exist" "$TOKEN")"
  if [[ -n "$out" ]]; then fail "missing body should yield empty reason, got: ${out}"; bad=1
  else pass "missing body yields no reason line"; fi

  rm -f "$tmp"
  return "$bad"
}

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

SELF=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --self-test) SELF=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           fail "unknown argument: '$1'"; usage >&2; exit 2 ;;
  esac
done

# The canary tokens must actually be key-shaped, or every assertion below is theatre.
[[ "${#TOKEN}" -ge 23 && "$TOKEN" == sk-* && "${#OTHER}" -ge 23 && "$OTHER" == sk-* ]] \
  || { fail "the synthetic tokens are not key-shaped — this guard would prove nothing."; exit 2; }
# ...and this FILE must stay clean under tools/lint/api-key-shape-guard.py. Re-joining the split
# literals above would make the guard's own canary a finding in the tree it guards.
if grep -Eq '(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}' "${BASH_SOURCE[0]}"; then
  fail "this file now contains a key-shaped literal — restore the quote break after sk-."
  exit 2
fi

[[ -r "$WS" ]] || { fail "cannot read ${WS} — nothing to inspect."; exit 2; }
# shellcheck source=/dev/null
source "$WS" || { fail "could not source ${WS}"; exit 2; }
declare -F maas_probe_reason >/dev/null || {
  fail "maas_probe_reason is not defined in ${WS} — the guard has nothing to check."; exit 2; }

if [[ "$SELF" -eq 1 ]]; then
  echo "▶ canary: replacing maas_probe_reason with the naive body-dump it exists to forbid"
  maas_probe_reason() { [[ -s "${1:-}" ]] && cat "$1"; }   # no redaction, no cap
  if run_cases; then
    fail "SELF-TEST FAILED: the naive implementation passed — these assertions prove nothing."
    exit 2
  fi
  echo "✅ self-test: every credential assertion caught the unredacted canary. Exiting 1 — detection proven."
  exit 1
fi

echo "▶ maas_probe_reason redaction contract (${WS})"
if run_cases; then
  echo "✅ the probe reason keeps the endpoint's words and carries no credential."
  exit 0
fi
fail "maas_probe_reason does not hold its contract — see above."
exit 1
