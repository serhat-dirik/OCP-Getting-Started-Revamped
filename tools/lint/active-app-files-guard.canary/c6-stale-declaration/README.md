CANARY (no files of its own). The skeleton is clean, and the self-test runs this case under a ledger
declaring `bootstrap/install.sh` as still globbing. It does not glob, so the declaration has outlived
its defect and must fail: a suppression that survives the fix is a false all-clear over the next one.
`.md` is not a scanned suffix, so this note cannot itself become a finding.
