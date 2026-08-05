# Verify scripts — the module truth harness

One script per module, named for the module slug: `tools/verify/<slug>.sh` (e.g. `gitops-at-scale.sh`).
Called by `ws verify <slug> [--user U]` — `mNN` also resolves, a module's number being its position in
`/modules.yaml` — by CI, and standalone by instructors.

**"rule 10"**, cited across these scripts and the entry charts, is
the module template's rule 10 (maintainer notes, kept outside this repo): *verify scripts run as
the attendee — no reads outside the user's namespaces* (derive the Gitea host from the ingress domain
rather than reading the route cross-namespace, and so on). The two bullets below extend it.

## Contract

- Args: `--user <name>` (default `user1`), `--entry-only` (skip end-state checks).
- **Entry checks**: assert exactly what `ws start mNN` materializes (the world before exercise 1).
- **End checks**: assert what a *completed* lab looks like (used after `ws solve` and by graders).
- Exit 0 only when no check failed; one `✅/❌` line per check with a `↳ fix:` hint on failure.
  A run that SKIPPED checks (see the inconclusive bullet below) still exits 0 — `ws prep` reads
  `--entry-only`'s rc as "is this world already prepared?" and would otherwise offer to wipe a
  healthy environment — but its banner says so: `⚠ 7 passed · 6 SKIPPED (not graded)`. Automation
  that must fail closed sets `VERIFY_STRICT=1` and then gets rc **3** when some checks were skipped
  and every graded one passed, or rc **4** when NOTHING was graded (1 = a check failed, 2 = usage).
  Fail on 4, not on 3: several modules carry a check an attendee legitimately cannot answer (a
  cluster-scoped read), so a gate that rejects rc 3 makes those modules permanently unpassable —
  measured on `jobs-batch-kueue` in user5's cockpit, 2026-08-05, at 13 passed · 1 skipped.
- Source `_lib.sh` for `check`, `hint`, `warn`, `parse_verify_args`, `verify_summary`, and the
  cluster-read helpers below.
- Scripts must be runnable with only `oc` + `curl` available (Showroom terminal reality).
- **Never write `oc get … 2>/dev/null`.** It cannot tell "the object is not there" (a real ❌) from
  "the cluster did not answer" — throttling, an apiserver blip, an expired token, a network hiccup —
  and both come back as an empty string, so a transient failure blames the attendee's correct work.
  Read the cluster through `_lib.sh` instead; all three set `OC_OUT` (stdout) and `OC_ERR` (stderr):

  | helper | use it for | rc |
  |---|---|---|
  | `oc_read <args…>` | any value read | `0` oc succeeded · `1` real NO (NotFound, or the server's own answer) · `2` **could not ask** — sets `VERIFY_INCONCLUSIVE` |
  | `oc_present <args…>` | "this exists / is non-empty" | `0` only when the API answered AND something is there |
  | `oc_absent <args…>` | "this does NOT exist" | `0` only when the API answered AND nothing is there |
  | `oc_read_optional <args…>` | a read whose refusal is EXPECTED because a fallback answers the same question (the `gitea` route before deriving the host from the ingress domain) | `0` + `OC_OUT` · `1` on any failure, `VERIFY_INCONCLUSIVE` left untouched |

  In a predicate, `oc_read … \|\| return 1` is almost always right: a real NO and an unanswerable read
  both return non-zero, and the flag — not the exit code — tells `check` which one it was. Negation is
  the dangerous direction: `! oc get … 2>/dev/null` and `[[ -z "$(oc get …)" ]]` certify a clean slate
  from an API that never answered, which is why `oc_absent` exists. `check "…" oc get …` is classified
  automatically, so those call sites need no change.
- **Never write `code="$(curl … || true)"` either.** An HTTP probe has exactly the same three outcomes
  as a cluster read, and the same trust bug when it only has two: `[[ "$code" == "200" ]]` prints the
  identical ❌ for "the app returned 503" (the attendee's lab, gradeable, and a thing these labs
  deliberately teach) and for "there is no route from here to this cluster at all" (not the attendee's
  lab, not gradeable). Use `http_read`:

  | helper | use it for | rc |
  |---|---|---|
  | `http_read <url> [curl args…]` | any HTTP probe | `0` a response ARRIVED — grade `HTTP_CODE` / `HTTP_OUT` yourself · `1` real NO · `2` **could not ask** — sets `VERIFY_INCONCLUSIVE` |

  A status code — any status code, 404 and 503 included — is a real answer and is graded as one; the
  cluster is never consulted for it. Only a TRANSPORT failure (no HTTP response at all: DNS, refused,
  timeout, TLS) triggers a **second probe against the cluster API**. If the API answers, the path from
  here to the cluster works, so this URL specifically is broken → still a hard ❌. If the API is silent
  too → ⚠. `--max-time 15` is the default; pass your own to override it. The predicate shape is
  `http_read "$url" … || return 1` then a test on `HTTP_CODE`, exactly like `oc_read`'s.
  **Derive the host in the predicate's OWN shell** (`read_ingress_domain`-style globals, never
  `h="$(host_helper)"`): a `$( )` is a subshell, and a flag raised in one never reaches `check`.
- **Three outcomes, and the third is not optimism.** A check whose answer could not be determined
  prints `⚠ … SKIPPED (not a failure)` and touches neither counter; a genuinely absent thing is a real,
  gradeable answer and stays `❌`. `Forbidden` is a skip (rule 10 — not this identity's check to run)
  and says so with a different hint from a connection failure, because "retry" is the wrong advice for
  an RBAC denial. Shared, correct implementations of the common predicates — `deploy_ready`,
  `deploy_ready_min`, `cm_key_set` — live in `_lib.sh`; do not copy them back into a module.
- **Prove the ATTENDEE-visible state, not the admin-visible one.** An object existing is not proof the
  attendee's page, UI or API call works — `observability-health-scale` shipped a green
  `oc get prometheusrule` while the attendee's Alerting rules page was empty (403 on the backing API).
  Where a check backs an attendee-facing claim, assert it as the attendee: `oc auth can-i` with literal
  `--as=<user> --as-group=workshop-attendees` when the caller can impersonate (admin/CI) and plain
  self-review when the attendee runs it themselves, and/or query the real endpoint with the caller's
  own token.
- A check the CALLER cannot evaluate (missing impersonation rights, an in-cluster-only endpoint on an
  off-cluster run) is **inconclusive, never a failure**: call `warn "<what> — <why not evaluable>"` plus a
  `↳ fix:` retry hint and skip it — it must not touch the pass/fail counters. A reachable endpoint
  returning the *wrong answer* is still a hard `❌`. A false `❌` destroys attendee trust in every other `✅`.
  **Route every skip through `warn`, never a bare `echo`/`info`** — `warn` is what increments the skip
  counter, and a skip the summary cannot see is a skip the attendee is never told about (11 of 26 scripts
  once ended `✅ all N checks passed` with the whole graded lesson skipped; guard:
  `tools/lint/verify-summary-skip-guard.sh`).

## Skeleton

```bash
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-dev"

# --- entry state ---
check "namespace ${NS} exists" oc get ns "$NS" || hint "run: ws start platform-orientation --user ${USER_NAME}"
check "entry marker present"   oc get cm ws-entry-platform-orientation -n "$NS" || hint "entry app not synced — ws start platform-orientation"

if [[ "$ENTRY_ONLY" != "true" ]]; then
  # --- end state ---
  check "parasol-web deployed" oc get deploy parasol-web -n "$NS" || hint "complete exercise 2"
fi
verify_summary
```
