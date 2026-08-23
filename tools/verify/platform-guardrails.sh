#!/usr/bin/env bash
# Verify platform-guardrails — Platform Guardrails (Policy-as-Code & External Secrets).
#   Entry: {user}-dev runs an OpenBao dev server holding parasol/claims-db, a SecretStore that
#          reaches it, and an ExternalSecret that materializes Secret claims-creds — from which BOTH
#          claims-db (PostgreSQL) and parasol-claims read POSTGRESQL_PASSWORD. The password is in no
#          manifest anywhere; that absence IS the module, so the checks below grade the credential
#          PATH (store Ready, secret Synced, and the Secret's value equal to what the vault holds
#          right now) rather than any object merely existing. With --entry-only, also asserts the
#          CLEAN SLATE: OpenBao at kv-v2 version 1 — the rotation exercise needs a version left to
#          add — and no leftover Git-style claims-db Secret to muddy "where does the password come
#          from?", which is the module's opening question.
#   End:   a rotation happened. OpenBao's parasol/claims-db is at version 2 or more, and the
#          Kubernetes Secret still matches the vault's CURRENT value, which together are the whole
#          lesson: a write to the vault moved the cluster.
#          GRADED BY VERSION COUNT, NEVER BY VALUE, and deliberately: the attendee chooses their own
#          rotation string (the lab suggests one; `ws solve` uses another), so asserting a literal
#          would print ❌ over correct work. ">= 2", not "== 2", for the same reason — an attendee
#          who rotated three times while watching the re-sync has done the lesson three times, not
#          got it wrong.
#          The POLICY half of this module grades nothing here: the attendee reads a live
#          ValidatingAdmissionPolicy, gets denied by it, and authors a manifest they never apply —
#          three outcomes that leave no state behind. What IS checked (in both modes) is that the
#          policy object the lab reads exists at all; see that check's comment.
# Runnable with only oc + curl (Showroom terminal reality). See tools/verify/README.md.
set -euo pipefail
# shellcheck disable=SC1091  # _lib.sh is linted standalone; its path is runtime-derived
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
parse_verify_args "$@"
NS="${USER_NAME}-dev"

# The ESO OPERAND namespace — where the operator installs its own NetworkPolicies, and where the one
# piece of this module's plumbing that no entry chart can ship has to live. NOT the operator's own
# namespace (external-secrets-operator), which runs only the controller-manager and carries none.
# Set by eso_namespace() below, which discovers it rather than hardcoding it; `external-secrets` is
# the product default and the fallback.
ESO_NS="external-secrets"

# The cluster-wide policy the module's policy half is ABOUT. Owned by gitops/workshop-config, not by
# this module's entry state — named here because a module whose central artefact has been renamed or
# removed should fail loudly in verify rather than at the attendee's first command.
ENTRY_APP_GUARD="ogsr-attendee-entry-app-guard"

# --- helpers (kept dependency-free: oc + curl only) ------------------------------------------------

# deploy_ready (<deployment> [namespace]) is shared — tools/verify/_lib.sh. It polls to a small budget
# so a workload that `ws prep` created seconds ago is not failed for being slow, and it classifies the
# API's answer so a cluster that could not be asked reports ⚠ SKIP instead of a false ❌.

# A status condition on an external-secrets.io object reads the way the operator writes it: one
# `Ready` condition whose REASON carries the interesting half (Valid / InvalidProviderConfig on a
# SecretStore, SecretSynced / SecretSyncedError on an ExternalSecret).
# BOTH status AND reason are asserted, not just status: an ExternalSecret that has never synced at
# all has no condition, `{.status.conditions[?(@.type=="Ready")].status}` renders empty, and an
# empty string is not "True" — so this stays a ❌ exactly as it should. Matching on reason too keeps
# the check honest if a future operator build reports Ready=True with a degraded reason.
eso_condition_is() {  # <resource> <name> <expected-reason>
  oc_read get "$1" "$2" -n "$NS" \
    -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}/{.reason}{end}' || return 1
  [[ "$OC_OUT" == "True/$3" ]]
}

# The Secret ESO produced carries the key the workloads actually read, and carries something in it.
# Existence of the Secret is NOT enough and is the trap this check exists to avoid: ESO creates the
# target Secret as soon as the ExternalSecret is admitted, before it has read anything, so a Secret
# with an empty (or absent) POSTGRESQL_PASSWORD is a perfectly normal intermediate state that would
# pass `oc get secret claims-creds`. cm_key_set in _lib.sh makes the same argument for ConfigMaps
# written by a hook; this is its Secret-shaped twin, kept local because it reads .data (base64) where
# cm_key_set reads .data (plain) and folding the two would need a decode neither of them wants.
secret_key_set() {  # <secret> <key>
  oc_read get secret "$1" -n "$NS" -o jsonpath="{.data.$2}" || return 1
  [[ -n "$OC_OUT" ]]
}

# THE CENTRAL CHECK, and the only one that proves the module's claim rather than its scaffolding: the
# Kubernetes Secret holds what OpenBao holds RIGHT NOW. Everything else above it (store Ready, secret
# Synced) describes a controller's opinion of its own health, and a controller can be perfectly happy
# serving a value it read an hour ago from a vault that has since moved on.
#
# NEITHER VALUE IS EVER PRINTED. The vault side is read as plaintext (there is no other way to ask
# OpenBao), the Secret side is read as base64 and the vault value is ENCODED to compare — rather than
# the Secret being decoded — so the script never materializes the stored credential from the cluster
# side at all. check() discards a predicate's stdout, and only OC_ERR (stderr) ever reaches the ⚠
# line, so no path here can surface either value in output an attendee pastes into a chat.
#
# `oc exec` and not a port-forward: exec is one call, it needs no background process to clean up, and
# pods/exec is a verb the attendee already holds as namespace admin (it is also what the lab's own
# rotation command uses, so a cluster where this check cannot run is a cluster where the lab cannot
# be done — which is why it is graded rather than skipped).
secret_matches_vault() {
  local vault_b64
  oc_read exec "deploy/openbao" -n "$NS" -- sh -c 'bao kv get -mount=parasol -field=password claims-db' || return 1
  [[ -n "$OC_OUT" ]] || return 1
  vault_b64="$(printf '%s' "$OC_OUT" | base64 | tr -d '\n')"
  oc_read get secret claims-creds -n "$NS" -o jsonpath='{.data.POSTGRESQL_PASSWORD}' || return 1
  [[ "$OC_OUT" == "$vault_b64" ]]
}

# kv-v2's version counter for parasol/claims-db — the entry/end discriminator, and value-free.
# Read with -format=json and parsed with a jsonpath-free `sed`, because verify scripts run with only
# oc and curl: `bao`'s human output prints the field but jq is the LAB's tool, not this script's.
# Two spellings of the same field are accepted because `bao kv metadata get -format=json` nests it
# under .data while some builds print it at the top level; matching the key rather than the path
# survives both without pretending to parse JSON.
vault_kv_version() {  # → 0 + VAULT_KV_VERSION set; 1/2 exactly as oc_read
  VAULT_KV_VERSION=""
  oc_read exec "deploy/openbao" -n "$NS" -- sh -c 'bao kv metadata get -mount=parasol -format=json claims-db' || return $?
  VAULT_KV_VERSION="$(tr -d ' "' <<<"$OC_OUT" | sed -n 's/^current_version:\([0-9]*\),*$/\1/p' | head -1)"
  [[ -n "$VAULT_KV_VERSION" ]]
}
VAULT_KV_VERSION=""

vault_kv_version_is() {  # <n> — exactly n versions written (entry: exactly 1)
  vault_kv_version || return $?
  [[ "$VAULT_KV_VERSION" == "$1" ]]
}

vault_kv_version_at_least() {  # <n> — n or more versions written (end: 2+, a rotation happened)
  vault_kv_version || return $?
  [[ "$VAULT_KV_VERSION" -ge "$1" ]]
}

# ESO owns the Secret it created, via an ownerReference. Asserted because `ws reset` DEPENDS on it and
# nothing else would notice it breaking: claims-creds is the one object in this namespace that the
# chart does not render, so Argo's prune cannot see it and the reset purge does not name it. What
# actually removes it is Kubernetes garbage collection when the ExternalSecret goes. Flip the
# ExternalSecret's creationPolicy to Orphan and every check in this file stays green while a stale
# credential survives every reset.
secret_owned_by_externalsecret() {
  oc_read get secret claims-creds -n "$NS" \
    -o jsonpath='{range .metadata.ownerReferences[*]}{.kind}/{.name}{"\n"}{end}' || return 1
  grep -qx -- "ExternalSecret/claims-creds" <<<"$OC_OUT"
}

# The claims Route answers HTTP 200 on the readiness endpoint — which, for this module specifically,
# is the end-to-end proof that the app authenticated to PostgreSQL with a password it was never
# given in a manifest: Quarkus gates /q/health/ready on the datasource.
# The ROUTE READ is classified (no Route object and no answer from the API are different things); the
# HTTP probe goes through http_read, so a status code — any status code — is graded as the real
# answer it is, while a transport failure that the cluster API cannot corroborate stays ⚠.
# The host is derived IN THIS FUNCTION'S OWN SHELL, never `h="$(…)"`: a $( ) is a subshell and a flag
# raised inside one never reaches check().
route_ready_200() {
  local host
  oc_read get route parasol-claims -n "$NS" -o jsonpath='{.spec.host}' || return 1
  host="$OC_OUT"
  [[ -n "$host" ]] || return 1
  http_read "http://${host}/q/health/ready" || return 1
  [[ "$HTTP_CODE" == "200" ]]
}

# A named object of any kind is ABSENT from a namespace. The namespace must actually exist first —
# otherwise this is vacuously true on a cluster where nothing materialized at all.
# NEGATION NEEDS THE THIRD OUTCOME MOST: `! oc get … 2>/dev/null` turns a cluster that could not be
# asked into a PASS, the one direction this must never take. oc_absent answers 0 only when the API
# ANSWERED and nothing is there.
obj_absent() {
  oc_present get ns "$3" -o name || return 1
  oc_absent  get "$1" "$2" -n "$3" -o name
}

# --- the one piece of plumbing no entry chart can ship ---------------------------------------------
#
# The ESO operator installs `eso-sys-deny-all-traffic` in its operand namespace (podSelector {},
# Ingress AND Egress) plus allow-lists for the API server and DNS only. Its controller therefore
# cannot open a TCP connection to port 8200 in ANY tenant namespace until something grants that
# egress. Measured on cluster-m24jn 2026-08-23 by taking the workshop owner label off a namespace so
# the allow policy's namespaceSelector stopped matching it — the SAME chart, token and store then
# produced, within ~60s:
#     Warning  InvalidProviderConfig  secretstore/parasol-bao
#              invalid vault credentials: context deadline exceeded
#     Warning  UpdateFailed           externalsecret/claims-creds
#              cannot read secret data from Vault: context deadline exceeded
# "invalid vault credentials" is a blocked TCP connection wearing an auth failure's clothes, and it
# is worth knowing where to read it: the CONDITION messages are terse ("unable to validate store",
# "could not get secret data from provider") and say nothing about the network. The sentence above
# only appears in `oc get events -n {user}-dev`.
#
# ASKED NAME-AGNOSTICALLY, on purpose. The grant belongs in the portfolio's `secrets` stack
# (modules.yaml already declares it) and that stack does not exist yet, so hardcoding a policy name
# would pin this check to a guess about what someone else will call theirs. Any NetworkPolicy in the
# ESO namespace that permits egress to TCP 8200 answers the question this check is really asking.
# WHERE the operand runs is DISCOVERED, not assumed. `external-secrets` is the operator's default and
# is what this cluster uses (read 2026-08-23), but the operand namespace is a property of the
# operator's install rather than of the API, and this suite has to be right on any OpenShift 4.20+
# cluster — including one where a customer already ran ESO somewhere else. Same shape as _lib.sh's
# gitea_host(): a best-effort read, then a fallback that answers the same question.
# oc_read_OPTIONAL, not oc_read: a cluster-wide Deployment list is not an attendee's to run, and that
# refusal is the EXPECTED case here — it must not become the caller's verdict, because the fallback
# is correct on every cluster this workshop has ever been installed on.
# GLOBAL, not echo-shaped, for the reason gitea_host() documents at length: `ns="$(eso_namespace)"`
# runs the body in a subshell, and any flag raised in there dies with it.
eso_namespace() {  # → always 0; ESO_NS set to the discovered namespace or the product default
  if oc_read_optional get deployments -A -l app.kubernetes.io/name=external-secrets \
      -o jsonpath='{.items[0].metadata.namespace}' && [[ -n "$OC_OUT" ]]; then
    ESO_NS="$OC_OUT"
    return 0
  fi
  ESO_NS="external-secrets"
}

eso_egress_allowed() {  # 0 = something permits egress to the vault port from the ESO namespace
  oc_read get networkpolicies -n "$ESO_NS" \
    -o jsonpath='{range .items[*]}{range .spec.egress[*]}{range .ports[*]}{.port}{"\n"}{end}{end}{end}' || return 1
  grep -qx -- "8200" <<<"$OC_OUT"
}

# Is the controller restricted at all? Three answers, because they need three different verdicts:
# an unrestricted ESO namespace makes the allow question genuinely INAPPLICABLE (na, not a pass and
# not a warning), while a namespace we could not read is UNKNOWN (warn). Collapsing the two would
# certify a clean bill of health from an API that never answered.
# Calling oc_read outside check() is safe and is what oc_absent/oc_present already do: check() clears
# VERIFY_INCONCLUSIVE at the top of every assertion, so a flag raised here cannot leak into the next.
eso_egress_gate() {  # 0 = an allow is REQUIRED · 1 = nothing restricts egress · 2 = could not ask
  local rc=0
  oc_read get networkpolicy eso-sys-deny-all-traffic -n "$ESO_NS" -o name || rc=$?
  if (( rc >= 2 )); then return 2; fi
  if (( rc == 1 )); then return 1; fi
  if [[ -z "$OC_OUT" ]]; then return 1; fi
  return 0
}

# --- shared checks (hold at BOTH entry and end) ----------------------------------------------------
check "namespace ${NS} exists"                                oc get ns "$NS"                                    || hint "run: ws prep platform-guardrails (or ws start platform-guardrails --user ${USER_NAME})"
check "entry marker ws-entry-platform-guardrails in ${NS}"    oc get cm ws-entry-platform-guardrails -n "$NS"     || hint "entry app not synced — ws start platform-guardrails --user ${USER_NAME}"
check "workshop quota present in ${NS}"                       oc get resourcequota workshop-quota -n "$NS"        || hint "workshop layer not applied — run bootstrap/install.sh"
check "openbao deployment ready in ${NS}"                     deploy_ready openbao "$NS"                          || hint "the vault is not up: oc get pods -l app=openbao -n ${NS}. A pod that unseals and then exits 1 is the read-only-\$HOME trap — the chart sets HOME=/home/bao onto an emptyDir for exactly that reason, so a pod without it has been edited"
check "SecretStore parasol-bao is Ready (store validated)"    eso_condition_is secretstore parasol-bao Valid      || hint "ESO cannot validate the store. If openbao itself is Ready above, this is almost certainly NOT the token: it is the ESO namespace's deny-all NetworkPolicy blocking egress to port 8200 — read the real reason with 'oc get events -n ${NS} | grep secretstore', where a blocked connection prints 'invalid vault credentials: context deadline exceeded'. The egress allow is platform-layer (see the check below), not something you can fix from this namespace"
check "ExternalSecret claims-creds reports SecretSynced"      eso_condition_is externalsecret claims-creds SecretSynced || hint "ESO is not producing the Secret: oc describe externalsecret claims-creds -n ${NS}. If the SecretStore above is Ready, the usual cause is the vault having no parasol/claims-db to read — check with 'oc exec deploy/openbao -n ${NS} -- bao kv get -mount=parasol claims-db'"
check "Secret claims-creds carries POSTGRESQL_PASSWORD"       secret_key_set claims-creds POSTGRESQL_PASSWORD     || hint "the Secret exists but the key the workloads read is empty — ESO creates the target Secret before it has read anything, so this is what a never-completed first sync looks like: oc describe externalsecret claims-creds -n ${NS}"
check "claims-creds matches what OpenBao holds right now"     secret_matches_vault                                || hint "the Secret and the vault have drifted. If you JUST rotated, wait one refresh interval (15s) and re-run — the re-sync is not instant. If it persists, the ExternalSecret has stopped reading: oc describe externalsecret claims-creds -n ${NS}"
check "claims-creds is owned by the ExternalSecret"           secret_owned_by_externalsecret                      || hint "the Secret has lost its ownerReference, so nothing garbage-collects it — 'ws reset platform-guardrails --user ${USER_NAME}' would leave a stale credential behind. Re-materialize: ws reset platform-guardrails --user ${USER_NAME}"
check "claims-db deployment ready in ${NS}"                   deploy_ready claims-db "$NS"                        || hint "wait for rollout: oc rollout status deploy/claims-db -n ${NS}. A pod stuck in CreateContainerConfigError is waiting for Secret claims-creds — fix the ESO checks above first, then it starts on its own"
check "parasol-claims deployment ready in ${NS}"              deploy_ready parasol-claims "$NS"                   || hint "wait for rollout: oc rollout status deploy/parasol-claims -n ${NS}. If the new pod crash-loops on a datasource error after you rotated the credential, that is the two-sided half of the lesson: restart the DATABASE too (oc rollout restart deploy/claims-db deploy/parasol-claims -n ${NS}), because PostgreSQL took its password at init time"
check "route parasol-claims answers 200 in ${NS}"             route_ready_200                                     || hint "the app is not serving — readiness gates on the datasource, so a red line here usually means the app cannot authenticate: oc get pods -n ${NS}"

# The policy half's subject. Cluster-scoped and owned by gitops/workshop-config, so it is NOT this
# module's entry state to create — but the lab reads it, tries to violate it and expects a denial by
# name, and all three of those are dead if the object has been renamed or removed. Graded here so a
# workshop-config change surfaces in this module's verify instead of in an attendee's terminal.
# AN ATTENDEE CANNOT ANSWER THIS ONE and is not meant to: probed as a real read on cluster-m24jn
# 2026-08-23 (impersonating user1 with --as-group=workshop-attendees, not `oc auth can-i`),
# validatingadmissionpolicies is Forbidden at cluster scope. oc_read files Forbidden under "could not
# ask", so the attendee gets ⚠ with _lib.sh's "not yours to fix and not graded" line, and an
# instructor or CI run — which is where a missing platform object should be caught — gets ✅ or ❌.
check "policy ${ENTRY_APP_GUARD} exists (the policy the lab reads)"  oc get validatingadmissionpolicy "$ENTRY_APP_GUARD" -o name || hint "the ValidatingAdmissionPolicy this module is about is missing — the lab's read, its deliberate violation and its denial message all reference it by name. It is owned by gitops/workshop-config, not by this module: re-sync the workshop-config Application"

# The egress grant, with all three of its honest outcomes.
eso_namespace
eso_gate_rc=0
eso_egress_gate || eso_gate_rc=$?
case "$eso_gate_rc" in
  0)
    check "ESO may reach the vault: egress to TCP 8200 allowed from ${ESO_NS}" eso_egress_allowed || hint "the ESO operand namespace denies all egress (eso-sys-deny-all-traffic) and nothing re-opens port 8200, so this module's SecretStore cannot work on this cluster. The grant is platform-layer and belongs in the portfolio's 'secrets' stack: a NetworkPolicy in ${ESO_NS} selecting app.kubernetes.io/name=external-secrets with egress to namespaceSelector workshop.redhat.com/owner=ogsr on TCP 8200. One policy covers every attendee — every workshop namespace carries that label"
    ;;
  1)
    # na(), not warn(): nothing is unknown and there is nowhere else to ask. This cluster's ESO simply
    # does not restrict its controller's egress, so "is the vault port re-opened?" grades a condition
    # that does not exist here. As a warn() it would drag a completely and correctly graded run into
    # "this run did NOT fully verify the lab" (U8-F-03) on a cluster with nothing wrong with it.
    na "egress allow for the ESO controller — this cluster's ${ESO_NS} carries no deny-all NetworkPolicy, so nothing is blocking port 8200 and there is no allow to require. The credential path itself IS graded above (SecretStore Ready, ExternalSecret SecretSynced), which is the outcome the allow exists to produce"
    ;;
  *)
    warn "could not check: the ESO controller's egress to TCP 8200 — ${ESO_NS} is not readable as this identity"
    hint "not yours to fix and not graded: NetworkPolicies in a platform namespace are not an attendee's to read. The checks above already grade the OUTCOME (SecretStore Ready, ExternalSecret SecretSynced); run this one from an instructor or CI session if you need the cause rather than the symptom"
    ;;
esac

if [[ "$ENTRY_ONLY" == "true" ]]; then
  # Entry-only: prove the world is the one the lab STARTS from. `ws prep` reads this run's rc as
  # "is this environment already prepared?", so every absence the lab depends on has to be asserted
  # here — an attendee who already rotated the credential and stopped must NOT be told "already
  # prepared", because the rotation exercise's whole payoff is watching a value CHANGE, and a value
  # that is already the rotated one changes to nothing.
  check "OpenBao holds exactly one version of parasol/claims-db (you rotate it)"  vault_kv_version_is 1                                   || hint "parasol/claims-db is already at version ${VAULT_KV_VERSION:-2+}, so someone has rotated it and the exercise has nothing left to show — ws reset platform-guardrails --user ${USER_NAME} for a clean entry (the vault is in-memory, so a reset genuinely starts it over)"
  check "no ws-solve marker in ${NS} (this world was not machine-solved)"         obj_absent configmap ws-solve-platform-guardrails "$NS"  || hint "this namespace was materialized by 'ws solve', which rotates the credential for you — that is the END state, not the entry one. ws reset platform-guardrails --user ${USER_NAME} to start the lab from the beginning"
  check "no Git-style claims-db Secret in ${NS} (the password is not in Git)"     obj_absent secret claims-db "$NS"                       || hint "a claims-db Secret survives from another module in this shared namespace — nothing here reads it, but the module opens by asking WHERE the password comes from and a second candidate makes that question unanswerable. ws reset platform-guardrails --user ${USER_NAME}"
else
  # --- end state (what a completed lab looks like) ---------------------------
  info "end state — these checks grade a COMPLETED lab; every ❌ hint says whether it means 'not done yet' (expected before you start) or 'actually broken'"
  check "OpenBao's parasol/claims-db has been rotated (kv version >= 2)"          vault_kv_version_at_least 2                             || hint "not done yet — the rotation exercise writes a new value with 'oc exec deploy/openbao -n ${NS} -- bao kv put -mount=parasol claims-db password=<yours>', and kv-v2 counts that as a new version. It is still at version ${VAULT_KV_VERSION:-1}. Note the vault is in-memory: if the openbao pod restarted, your rotation went with it and the counter is back at 1"
  # The re-sync itself is graded in the shared block (claims-creds matches what OpenBao holds right
  # now), which is the check that actually proves a rotation propagated. Re-asserted here only as
  # context, not as a second graded outcome — see that check for the mechanism.
  if [[ "$SOLVE_MODE" == "true" ]]; then
    # ONLY under --solve. An attendee who rotated by hand has a fully correct end state and no
    # marker, and a ❌ over correct work destroys trust in every other ✅ (parse_verify_args, _lib.sh).
    check "ws-solve marker present in ${NS}"                                      oc get cm ws-solve-platform-guardrails -n "$NS"          || hint "'ws solve platform-guardrails' did not complete — re-run it: ws solve platform-guardrails --user ${USER_NAME}"
  fi
fi

verify_summary
