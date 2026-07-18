#!/usr/bin/env bash
# Workshop bootstrap — the thin layer ON TOP of the workshop-agnostic platform portfolio.
# It does the imperative, workshop-specific things the portfolio must never know about:
#   1. install the mapped portfolio stacks (core-devtools [+ ai-assist])
#   2. create the secret CONTRACTS (htpasswd users, MaaS token, shared Gitea password)
#   3. wait for the in-cluster Gitea mirror (git-localize, D15) to be ready
#   4. materialize the workshop layer (users, RBAC, quotas, AppProject, IdP, Gitea seeding)
#      as ONE Argo CD Application sourced from the LOCAL mirror — the git-localize payoff
#
# All inputs come from vars.yaml (same dir, gitignored). Idempotent: safe to re-run.
#
# Usage: ./install.sh          (reads ./vars.yaml)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VARS="${SCRIPT_DIR}/vars.yaml"
PORTFOLIO_INSTALL="${SCRIPT_DIR}/../platform-portfolio/argocd-bootstrap/install.sh"
CREDS_FILE="${SCRIPT_DIR}/.credentials.local.txt"

GITEA_NS="ogsr-gitea"
MIRROR_ORG="parasol"
MIRROR_REPO="ocp-getting-started"
USER_PREFIX="user"

ok()   { echo "✅ $*"; }
err()  { echo "❌ $*" >&2; }
info() { echo "▶ $*"; }
die()  { err "$*"; exit 1; }

# ── preflight: tooling + vars file ────────────────────────────────────────────
command -v oc >/dev/null || die "oc not found in PATH"
command -v yq >/dev/null || die "yq not found — install it (brew install yq / dnf install yq); mikefarah/go yq v4 syntax expected"
command -v htpasswd >/dev/null || die "htpasswd not found — install it (brew install httpd / dnf install httpd-tools)"
command -v openssl >/dev/null || die "openssl not found — needed to generate/handle passwords"
[[ -f "$VARS" ]] || die "missing ${VARS} — copy vars.example.yaml to vars.yaml and fill it in"
[[ -x "$PORTFOLIO_INSTALL" ]] || die "portfolio installer not found/executable: ${PORTFOLIO_INSTALL}"

v() { yq "$1" "$VARS" 2>/dev/null || true; }

# ── read inputs (with safe defaults) ──────────────────────────────────────────
USERS="$(v '.users')";           [[ "$USERS" =~ ^[0-9]+$ ]] || USERS=5
LIGHTSPEED="$(v '.lightspeed')"; [[ "$LIGHTSPEED" == "false" ]] || LIGHTSPEED="true"
AUTH="$(v '.auth')";             [[ "$AUTH" == "true" ]] || AUTH="false"
RESILIENCE="$(v '.resilience')"; [[ "$RESILIENCE" == "true" ]] || RESILIENCE="false"
CONSOLE_PLUGINS="$(v '.console_plugins')"; [[ "$CONSOLE_PLUGINS" == "true" ]] || CONSOLE_PLUGINS="false"
REPO_URL="$(v '.repo_url')";     [[ -n "$REPO_URL" && "$REPO_URL" != "null" ]] || REPO_URL="https://github.com/serhat-dirik/OCP-Getting-Started-Revamped"
REVISION="$(v '.revision')";     [[ -n "$REVISION" && "$REVISION" != "null" ]] || REVISION="main"
DOMAIN="$(v '.cluster_domain')"
MAAS_KEY="$(v '.maas.api_key')"
WS_PASS="$(v '.workshop_user_password')"

echo "▶ Workshop bootstrap"
echo "  users     : ${USER_PREFIX}1..${USER_PREFIX}${USERS}"
echo "  lightspeed: ${LIGHTSPEED}"
echo "  source    : ${REPO_URL} @ ${REVISION}"

# ── preflight: cluster + cluster-admin ────────────────────────────────────────
info "preflight — cluster access"
oc whoami >/dev/null 2>&1 || die "not logged in — run: oc login …"
oc auth can-i '*' '*' --all-namespaces >/dev/null 2>&1 || die "need cluster-admin (oc auth can-i '*' '*' failed as $(oc whoami))"
ok "logged in as $(oc whoami) @ $(oc whoami --show-server)"

if [[ -z "$DOMAIN" || "$DOMAIN" == "null" ]]; then
  DOMAIN="$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)"
  if [[ -n "$DOMAIN" ]]; then ok "auto-detected cluster domain: ${DOMAIN}"; else err "could not auto-detect cluster domain — content attributes may be blank"; fi
fi

# Resolve the shared workshop password (generate if asked / unset / still placeholder).
if [[ -z "$WS_PASS" || "$WS_PASS" == "null" || "$WS_PASS" == "generate" || "$WS_PASS" == "CHANGEME" ]]; then
  [[ "$WS_PASS" == "CHANGEME" ]] && err "workshop_user_password is still CHANGEME — generating a random one instead"
  WS_PASS="$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | cut -c1-16)"
  [[ -n "$WS_PASS" ]] || die "failed to generate a random password"
  info "generated a random shared workshop password (recorded in ${CREDS_FILE})"
fi

# ── [0/6] uninstall-state capture (non-invasive delivery, Wave 1) ─────────────
# Record the PRIOR state of every shared/default object the install is about to touch, into a
# ConfigMap that bootstrap/ogsr-uninstall.sh reads to RESTORE (not blindly delete). Created FIRST,
# before any mutation, in a workshop-owned namespace. Snapshots are first-write-wins so the TRUE
# prior state survives re-runs (idempotent). # TODO(verify-on-cluster): every oc read here needs a cluster.
OWNER_LABEL="workshop.redhat.com/owner=ogsr"
STATE_NS="ogsr-system"
STATE_CM="ogsr-uninstall-state"

owner_stamp() { oc label --local --overwrite -f - "$OWNER_LABEL" -o yaml; }  # add the owner label to a piped manifest

record_once() {  # key value — write to the state CM only if the key is unset (true first-install snapshot)
  local k="$1" v="$2" cur
  cur="$(oc get configmap "$STATE_CM" -n "$STATE_NS" -o jsonpath="{.data['$k']}" 2>/dev/null || true)"
  [[ -n "$cur" ]] && return 0
  oc patch configmap "$STATE_CM" -n "$STATE_NS" --type merge -p "{\"data\":{\"$k\":\"$v\"}}" >/dev/null 2>&1 || true
}

# Operator adoption snapshot: for each operator the SELECTED stacks will install, record whether it
# already exists (adopted → uninstall NEVER removes it) or will be created by us (created → uninstall
# may remove it). Source of truth is the component subscription manifests — no brittle hardcoded map.
snapshot_operators() {
  local stacks_csv="$1" stack app comp_path sub name ns _stacks
  IFS=',' read -ra _stacks <<< "$stacks_csv"
  for stack in "${_stacks[@]}"; do
    stack="$(echo "$stack" | xargs)"
    [[ -d "${SCRIPT_DIR}/../platform-portfolio/stacks/${stack}/apps" ]] || continue
    for app in "${SCRIPT_DIR}/../platform-portfolio/stacks/${stack}/apps"/*.yaml; do
      [[ -e "$app" ]] || continue
      comp_path="$(yq '.spec.source.path' "$app" 2>/dev/null || true)"
      [[ -n "$comp_path" && "$comp_path" != "null" ]] || continue
      for sub in "${SCRIPT_DIR}/../${comp_path}"/subscription*.yaml; do
        [[ -e "$sub" ]] || continue
        name="$(yq '.metadata.name' "$sub" 2>/dev/null || true)"
        ns="$(yq '.metadata.namespace' "$sub" 2>/dev/null || true)"
        [[ -n "$name" && "$name" != "null" ]] || continue
        if oc get subscription "$name" -n "$ns" >/dev/null 2>&1; then
          record_once "op_${name}" "adopted:${ns}"
        else
          record_once "op_${name}" "created:${ns}"
        fi
      done
    done
  done
  # gitea-operator comes from an external rhpds OLMDeploy kustomize base (fetched at build time), so
  # the subscription*.yaml glob above can never find it — record it explicitly, gated on core-devtools
  # (the stack carrying the gitea component). Same treatment ogsr-uninstall.sh's enumerate_operators()
  # and helm/bootstrap's job-state-capture give it (c50067d / cf79b0d).
  if [[ ",${stacks_csv}," == *",core-devtools,"* ]]; then
    if oc get subscription gitea-operator -n gitea-operator >/dev/null 2>&1; then
      record_once "op_gitea-operator" "adopted:gitea-operator"
    else
      record_once "op_gitea-operator" "created:gitea-operator"
    fi
  fi
}

info "[0/6] capturing uninstall-state (prior cluster state for a non-destructive uninstall)"
oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${STATE_NS}
  labels:
    workshop.redhat.com/owner: ogsr
EOF
oc get configmap "$STATE_CM" -n "$STATE_NS" >/dev/null 2>&1 \
  || oc create configmap "$STATE_CM" -n "$STATE_NS" --dry-run=client -o yaml | owner_stamp | oc apply -f - >/dev/null

# cluster-monitoring-config: the portfolio flips enableUserWorkload=true — remember its prior value.
if oc get configmap cluster-monitoring-config -n openshift-monitoring >/dev/null 2>&1; then
  record_once monitoring_cm_existed true
  UWM_NOW="$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null || true)"
  if echo "$UWM_NOW" | grep -qE 'enableUserWorkload:[[:space:]]*true'; then
    record_once monitoring_uwm_prior true
  elif echo "$UWM_NOW" | grep -qE 'enableUserWorkload:[[:space:]]*false'; then
    record_once monitoring_uwm_prior false
  else
    record_once monitoring_uwm_prior absent
  fi
else
  record_once monitoring_cm_existed false
  record_once monitoring_uwm_prior absent
fi

# GitOps operator: adopted (pre-existing) or created by us? If adopted, remember the openshift-gitops
# ArgoCD controller.resources we are about to raise, so uninstall can restore the org's prior value.
if oc get subscription openshift-gitops-operator -n openshift-gitops-operator >/dev/null 2>&1; then
  record_once gitops_preexisted true
  ARGO_RES_PRIOR="$(oc get argocd openshift-gitops -n openshift-gitops -o jsonpath='{.spec.controller.resources}' 2>/dev/null | base64 | tr -d '\n' || true)"
  [[ -n "$ARGO_RES_PRIOR" ]] && record_once gitops_argocd_controller_resources_b64 "$ARGO_RES_PRIOR"
else
  record_once gitops_preexisted false
fi

# Gateway API: did the openshift-default GatewayClass already exist (activates a cluster istiod)?
if oc get gatewayclass openshift-default >/dev/null 2>&1; then
  record_once gatewayclass_preexisted true
else
  record_once gatewayclass_preexisted false
fi

# ── workshop node substrate (M16 scheduling / M21 resilience) ─────────────────
# Cluster-scoped, one-time, idempotent node shaping the per-user entry charts must NOT own (ADR-0001
# Rule 13 — entry charts never own cluster policy). Two pieces, both workshop-specific substrate:
#   • a dedicated BATCH POOL: one worker labeled+tainted workshop.redhat.com/pool=batch so M16's
#     toleration+nodeSelector beat is real (a toleration only PERMITS the tainted node; the nodeSelector
#     ATTRACTS the pod — you need both). NoSchedule evicts nothing; it only blocks NEW untolerated pods.
#   • synthetic FAILURE-DOMAIN labels workshop.redhat.com/zone={a,b,c} for M16's optional zone-spread
#     narrative and M21's chaos drill. Deliberately workshop-namespaced — NOT the well-known
#     topology.kubernetes.io/zone, which volume/scheduler controllers would treat as a real cloud AZ on
#     this single-AZ bare-metal cluster. Inert metadata: nothing keys on it unless a workload's
#     topologySpreadConstraints opts in.
# Idempotent: --overwrite makes a re-run a no-op. This is bootstrap (not the portfolio) because node
# objects can't be cleanly GitOps-reconciled and this is workshop substrate, not an operator install.
info "shaping workshop node substrate (M16 batch pool + M16/M21 synthetic zones)"
POOL_LABEL="workshop.redhat.com/pool=batch"
ZONE_KEY="workshop.redhat.com/zone"
# Pick a real worker (worker role, NOT also control-plane) as the batch pool node; deterministic (first
# by name). Fall back to any node if a cluster has no pure-worker split (so the beat always has a target).
BATCH_NODE="$(oc get nodes -l 'node-role.kubernetes.io/worker,!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | sort | head -1)"
[[ -n "$BATCH_NODE" ]] || BATCH_NODE="$(oc get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | sort | head -1)"
if [[ -n "$BATCH_NODE" ]]; then
  oc label node "$BATCH_NODE" "$POOL_LABEL" --overwrite >/dev/null
  oc adm taint nodes "$BATCH_NODE" "${POOL_LABEL}:NoSchedule" --overwrite >/dev/null
  ok "batch pool: worker ${BATCH_NODE} labeled+tainted ${POOL_LABEL}:NoSchedule"
else
  err "no nodes found to shape a batch pool — M16's dedicated-pool beat will have no target"
fi
# Synthesize zones a/b/c round-robin across all nodes (idempotent --overwrite).
read -ra SHAPE_NODES <<<"$(oc get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"
ZONES=(a b c)
zi=0
for n in "${SHAPE_NODES[@]}"; do
  oc label node "$n" "${ZONE_KEY}=${ZONES[zi % 3]}" --overwrite >/dev/null
  zi=$((zi + 1))
done
ok "synthetic ${ZONE_KEY} labels applied across ${#SHAPE_NODES[@]} node(s) (a/b/c round-robin)"
# Record the node mutations for the uninstall report. (Uninstall reverses by label selector, so this
# is documentation — it removes pool/zone labels + the batch taint from ANY node still carrying them.)
record_once nodes_batch "${BATCH_NODE:-}"
record_once nodes_zoned "${SHAPE_NODES[*]:-}"

# ── 1. portfolio stacks ───────────────────────────────────────────────────────
# Pre-installed detection: managed/demo clusters (RHDP) often ship Lightspeed already wired
# to their own LLM. Fighting that wiring breaks a working assistant (duplicate OperatorGroup
# → OLM ResolutionFailed; secret/OLSConfig clobbering) — reuse it instead.
LIGHTSPEED_PREINSTALLED="false"
if oc get olsconfig cluster >/dev/null 2>&1; then
  LIGHTSPEED_PREINSTALLED="true"
  PROVIDER="$(oc get olsconfig cluster -o jsonpath='{.spec.llm.providers[0].type}' 2>/dev/null || echo '?')"
  ok "OpenShift Lightspeed pre-installed (provider: ${PROVIDER}) — reusing it; ai-assist stack skipped"
fi
# batch stack (Kueue + KEDA) is a HARD baseline dependency, NOT optional: the workshop-config
# layer below unconditionally ships per-user Kueue queues (kueue-queues + per-user-batch). Omit
# batch and workshop-config's sync dies on missing kueue.x-k8s.io CRDs — which also aborts the
# in-app Gitea/Argo seed hooks riding the same Application, blocking the whole workshop. M06 also
# teaches Kueue. Verified: a clean bootstrap without it broke cluster-km7vw's seed (2026-07-12).
STACKS="core-devtools,batch"
[[ "$LIGHTSPEED" == "true" && "$LIGHTSPEED_PREINSTALLED" == "false" ]] && STACKS="${STACKS},ai-assist"
# auth stack (Red Hat build of Keycloak) for M13. Workshop-agnostic; per-user realms are seeded by the
# workshop layer below (sso.enabled). Its own OwnNamespace operator never touches a cluster login IdP.
[[ "$AUTH" == "true" ]] && STACKS="${STACKS},auth"
# resilience stack (OADP/Velero + in-cluster NooBaa S3) for M21. Opt-in; PREREQ ODF/MCG for the S3 target.
# The RHSI (Skupper v2) add-on stays commented out in the stack unless the catalog offers channel stable-2.
[[ "$RESILIENCE" == "true" ]] && STACKS="${STACKS},resilience"
# Snapshot operator adoption BEFORE Argo installs anything (created vs adopted → safe uninstall).
record_once lightspeed_preinstalled "$LIGHTSPEED_PREINSTALLED"
record_once installed_stacks "$STACKS"
snapshot_operators "$STACKS"
info "[1/6] installing portfolio stacks: ${STACKS}"
"$PORTFOLIO_INSTALL" --stacks "$STACKS" --repo-url "$REPO_URL" --revision "$REVISION"

# ── 2. secret contracts (imperative by design; never in git) ──────────────────
info "[2/6] creating secret contracts"

# 2a. htpasswd secret for the console/CLI IdP. Secret key MUST be 'htpasswd' (OpenShift contract).
HTP_FILE="$(mktemp)"; trap 'rm -f "$HTP_FILE"' EXIT
htpasswd -B -b -c "$HTP_FILE" "${USER_PREFIX}1" "$WS_PASS" >/dev/null 2>&1
i=2
while [[ "$i" -le "$USERS" ]]; do
  htpasswd -B -b "$HTP_FILE" "${USER_PREFIX}${i}" "$WS_PASS" >/dev/null 2>&1
  i=$((i + 1))
done
oc create secret generic htpasswd-workshop-users \
  --from-file=htpasswd="$HTP_FILE" -n openshift-config \
  --dry-run=client -o yaml | owner_stamp | oc apply -f - >/dev/null
ok "htpasswd-workshop-users (openshift-config) — ${USERS} users"

# 2a'. Merge the workshop IdP into the OAuth SINGLETON imperatively (append-if-absent).
# Deliberately NOT GitOps-managed: clusters arrive with pre-existing IdPs (this RHDP cluster
# has an 'rhbk' OpenID provider backing the admin login) and a forced server-side apply from
# Argo would replace the atomic identityProviders list — locking everyone out.
if oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}' | grep -qw "workshop-users"; then
  # first-write-wins: only records false if WE did not already claim ownership on an earlier run.
  record_once oauth_idp_ownedbyus false
  ok "OAuth IdP 'workshop-users' already present"
else
  IDP_JSON='{"name":"workshop-users","mappingMethod":"claim","type":"HTPasswd","htpasswd":{"fileData":{"name":"htpasswd-workshop-users"}}}'
  if [[ -z "$(oc get oauth cluster -o jsonpath='{.spec.identityProviders}')" ]]; then
    oc patch oauth cluster --type=json -p "[{\"op\":\"add\",\"path\":\"/spec/identityProviders\",\"value\":[${IDP_JSON}]}]" >/dev/null
  else
    oc patch oauth cluster --type=json -p "[{\"op\":\"add\",\"path\":\"/spec/identityProviders/-\",\"value\":${IDP_JSON}}]" >/dev/null
  fi
  # WE appended it — uninstall removes exactly this entry (preserving any other IdPs).
  record_once oauth_idp_ownedbyus true
  ok "OAuth IdP 'workshop-users' appended (existing IdPs preserved)"
fi

# 2b. MaaS token for OpenShift Lightspeed (only when WE install it — a pre-installed
# Lightspeed brings its own provider secret, which we must never overwrite).
if [[ "$LIGHTSPEED" == "true" && "$LIGHTSPEED_PREINSTALLED" == "false" ]]; then
  [[ -n "$MAAS_KEY" && "$MAAS_KEY" != "null" && "$MAAS_KEY" != "CHANGEME" ]] \
    || die "lightspeed: true but maas.api_key is unset/CHANGEME in ${VARS}"
  # Remember whether the namespace pre-existed — uninstall deletes it ONLY if WE created it.
  if oc get namespace openshift-lightspeed >/dev/null 2>&1; then record_once lightspeed_ns_created false; else record_once lightspeed_ns_created true; fi
  oc create namespace openshift-lightspeed --dry-run=client -o yaml | owner_stamp | oc apply -f - >/dev/null
  oc create secret generic credentials \
    --from-literal=apitoken="$MAAS_KEY" -n openshift-lightspeed \
    --dry-run=client -o yaml | owner_stamp | oc apply -f - >/dev/null
  record_once lightspeed_secret_created true
  ok "credentials (openshift-lightspeed/apitoken) — MaaS token"
fi

# ── 3. wait for the in-cluster Gitea mirror (git-localize) ────────────────────
info "[3/6] waiting for the in-cluster Gitea mirror (up to 15m)…"
GITEA_HOST=""
MIRROR_API=""
for _ in $(seq 1 90); do
  GITEA_HOST="$(oc get route gitea -n "$GITEA_NS" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -n "$GITEA_HOST" ]]; then
    MIRROR_API="https://${GITEA_HOST}/api/v1/repos/${MIRROR_ORG}/${MIRROR_REPO}"
    curl -ksf "$MIRROR_API" >/dev/null 2>&1 && break
  fi
  printf '.'; sleep 10
done
echo
[[ -n "$GITEA_HOST" ]] || die "gitea route not found after 15m — check: oc get pods -n ${GITEA_NS}"
curl -ksf "$MIRROR_API" >/dev/null 2>&1 \
  || die "mirror repo ${MIRROR_ORG}/${MIRROR_REPO} absent after 15m — check the mirror job: oc get jobs -n ${GITEA_NS}"
ok "Gitea mirror ready: https://${GITEA_HOST}/${MIRROR_ORG}/${MIRROR_REPO}"

# Freshness: the workshop chart must actually be IN the mirror at the target revision
# (mirrors pull on interval — force a sync so a just-pushed chart is served now).
info "refreshing the mirror and confirming the workshop chart is present…"
ADMIN_PASS="$(oc get gitea gitea -n "$GITEA_NS" -o jsonpath='{.status.adminPassword}' 2>/dev/null || true)"
if [[ -n "$ADMIN_PASS" ]]; then
  curl -ksf -u "gitea-admin:${ADMIN_PASS}" -X POST \
    "https://${GITEA_HOST}/api/v1/repos/${MIRROR_ORG}/${MIRROR_REPO}/mirror-sync" >/dev/null 2>&1 || true
fi
CHART_RAW="https://${GITEA_HOST}/${MIRROR_ORG}/${MIRROR_REPO}/raw/branch/${REVISION}/gitops/workshop-config/Chart.yaml"
for _ in $(seq 1 30); do
  curl -ksf "$CHART_RAW" >/dev/null 2>&1 && break
  printf '.'; sleep 5
done
echo
curl -ksf "$CHART_RAW" >/dev/null 2>&1 \
  || die "workshop chart not in the mirror at revision ${REVISION} — push it upstream, then re-run (or: ws git-refresh)"
ok "mirror serves gitops/workshop-config@${REVISION}"

# ── 4. shared workshop password for Gitea seeding (ogsr-gitea ns now exists) ───────
info "[4/6] recording the shared workshop password (secret workshop-user-creds)"
oc create secret generic workshop-user-creds \
  --from-literal=password="$WS_PASS" -n "$GITEA_NS" \
  --dry-run=client -o yaml | owner_stamp | oc apply -f - >/dev/null
ok "workshop-user-creds (ogsr-gitea/password)"

# ── 5. materialize the workshop layer from the LOCAL mirror ───────────────────
info "[5/6] materializing the workshop layer (Argo Application workshop-config)"
cat <<EOF | oc apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: workshop-config
  namespace: openshift-gitops
  labels:
    workshop.redhat.com/layer: workshop-config
    workshop.redhat.com/owner: ogsr
spec:
  project: default
  source:
    repoURL: https://${GITEA_HOST}/${MIRROR_ORG}/${MIRROR_REPO}.git
    targetRevision: ${REVISION}
    path: gitops/workshop-config
    helm:
      parameters:
        - name: userCount
          value: "${USERS}"
        - name: clusterDomain
          value: "${DOMAIN}"
        # Seed per-user realm-{user} imports only when the auth stack is installed (M13).
        - name: sso.enabled
          value: "${AUTH}"
        # Console plugins opt-in (backlog #24) — OFF unless vars.yaml sets console_plugins: true.
        - name: consolePlugins.enabled
          value: "${CONSOLE_PLUGINS}"
  destination:
    server: https://kubernetes.default.svc
    namespace: openshift-gitops
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: 10
      backoff: {duration: 15s, factor: 2, maxDuration: 3m}
EOF
ok "workshop-config Application applied (source: local mirror)"

# ── 6. wait for the workshop layer to be Healthy ──────────────────────────────
info "[6/6] waiting for workshop-config to become Healthy (up to 10m)…"
HEALTH=""; SYNC=""
for _ in $(seq 1 60); do
  HEALTH="$(oc get application workshop-config -n openshift-gitops -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  SYNC="$(oc get application workshop-config -n openshift-gitops -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  [[ "$HEALTH" == "Healthy" && "$SYNC" == "Synced" ]] && break
  printf '.'; sleep 10
done
echo
if [[ "$HEALTH" == "Healthy" && "$SYNC" == "Synced" ]]; then
  ok "workshop-config is Synced/Healthy"
else
  err "workshop-config not ready yet (health=${HEALTH:-?} sync=${SYNC:-?}) — selfHeal continues; inspect: oc describe application workshop-config -n openshift-gitops"
fi

# ── credentials summary + next steps ──────────────────────────────────────────
CONSOLE_URL="$(oc whoami --show-console 2>/dev/null || true)"
{
  echo "# Workshop credentials — generated $(date -u +%FT%TZ). DO NOT COMMIT (gitignored)."
  echo "console : ${CONSOLE_URL:-<oc whoami --show-console>}"
  echo "gitea   : https://${GITEA_HOST}"
  echo "users   : ${USER_PREFIX}1 .. ${USER_PREFIX}${USERS}"
  echo "# shared password — console/CLI login AND Gitea. Bare value on its own line:"
  echo "# an inline comment here poisons every naive parser (two QA agents read"
  echo "# 'password + comment' as the literal secret and reported 401s — 2026-07-09)."
  echo "password: ${WS_PASS}"
} > "$CREDS_FILE"
chmod 600 "$CREDS_FILE"

echo
ok "workshop bootstrap complete"
echo "   console : ${CONSOLE_URL:-<run: oc whoami --show-console>}"
echo "   gitea   : https://${GITEA_HOST}"
echo "   users   : ${USER_PREFIX}1 … ${USER_PREFIX}${USERS} (shared password)"
echo "   creds   : ${CREDS_FILE} (gitignored)"
echo "   next    : ws doctor   ·   ws start m01 --user ${USER_PREFIX}1"
