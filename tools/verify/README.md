# Verify scripts — the module truth harness

One script per module, named for the module slug: `tools/verify/<slug>.sh` (e.g. `gitops-at-scale.sh`).
Called by `ws verify <slug> [--user U]` — `mNN` also resolves, a module's number being its position in
`/modules.yaml` — by CI, and standalone by instructors.

**"rule 10"**, cited across these scripts and the entry charts, is
[`docs/module-template/README.md`](../../docs/module-template/README.md) rule 10: *verify scripts run as
the attendee — no reads outside the user's namespaces* (derive the Gitea host from the ingress domain
rather than reading the route cross-namespace, and so on). The two bullets below extend it.

## Contract

- Args: `--user <name>` (default `user1`), `--entry-only` (skip end-state checks).
- **Entry checks**: assert exactly what `ws start mNN` materializes (the world before exercise 1).
- **End checks**: assert what a *completed* lab looks like (used after `ws solve` and by graders).
- Exit 0 only when every check passes; one `✅/❌` line per check with a `↳ fix:` hint on failure.
- Source `_lib.sh` for `check`, `hint`, `parse_verify_args`, `verify_summary`.
- Scripts must be runnable with only `oc` + `curl` available (Showroom terminal reality).
- **Prove the ATTENDEE-visible state, not the admin-visible one.** An object existing is not proof the
  attendee's page, UI or API call works — `observability-health-scale` shipped a green
  `oc get prometheusrule` while the attendee's Alerting rules page was empty (403 on the backing API).
  Where a check backs an attendee-facing claim, assert it as the attendee: `oc auth can-i` with literal
  `--as=<user> --as-group=workshop-attendees` when the caller can impersonate (admin/CI) and plain
  self-review when the attendee runs it themselves, and/or query the real endpoint with the caller's
  own token.
- A check the CALLER cannot evaluate (missing impersonation rights, an in-cluster-only endpoint on an
  off-cluster run) is **inconclusive, never a failure**: print a `⚠` line plus a `↳ fix:` retry hint and
  skip it — it must not touch the pass/fail counters. A reachable endpoint returning the *wrong answer*
  is still a hard `❌`. A false `❌` destroys attendee trust in every other `✅`.

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
