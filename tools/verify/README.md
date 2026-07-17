# Verify scripts — the module truth harness

One script per module: `tools/verify/mNN.sh`. Called by `ws verify mNN [--user U]`, by CI (cluster-e2e), and standalone by instructors.

## Contract

- Args: `--user <name>` (default `user1`), `--entry-only` (skip end-state checks).
- **Entry checks**: assert exactly what `ws start mNN` materializes (the world before exercise 1).
- **End checks**: assert what a *completed* lab looks like (used after `ws solve` and by graders).
- Exit 0 only when every check passes; one `✅/❌` line per check with a `↳ fix:` hint on failure.
- Source `_lib.sh` for `check`, `hint`, `parse_verify_args`, `verify_summary`.
- Scripts must be runnable with only `oc` + `curl` available (Showroom terminal reality).

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
