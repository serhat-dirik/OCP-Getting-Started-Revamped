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

GITEA_NS="gitea"
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

# ── 1. portfolio stacks ───────────────────────────────────────────────────────
STACKS="core-devtools"
[[ "$LIGHTSPEED" == "true" ]] && STACKS="core-devtools,ai-assist"
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
  --dry-run=client -o yaml | oc apply -f - >/dev/null
ok "htpasswd-workshop-users (openshift-config) — ${USERS} users"

# 2a'. Merge the workshop IdP into the OAuth SINGLETON imperatively (append-if-absent).
# Deliberately NOT GitOps-managed: clusters arrive with pre-existing IdPs (this RHDP cluster
# has an 'rhbk' OpenID provider backing the admin login) and a forced server-side apply from
# Argo would replace the atomic identityProviders list — locking everyone out.
if oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}' | grep -qw "workshop-users"; then
  ok "OAuth IdP 'workshop-users' already present"
else
  IDP_JSON='{"name":"workshop-users","mappingMethod":"claim","type":"HTPasswd","htpasswd":{"fileData":{"name":"htpasswd-workshop-users"}}}'
  if [[ -z "$(oc get oauth cluster -o jsonpath='{.spec.identityProviders}')" ]]; then
    oc patch oauth cluster --type=json -p "[{\"op\":\"add\",\"path\":\"/spec/identityProviders\",\"value\":[${IDP_JSON}]}]" >/dev/null
  else
    oc patch oauth cluster --type=json -p "[{\"op\":\"add\",\"path\":\"/spec/identityProviders/-\",\"value\":${IDP_JSON}}]" >/dev/null
  fi
  ok "OAuth IdP 'workshop-users' appended (existing IdPs preserved)"
fi

# 2b. MaaS token for OpenShift Lightspeed (only when ai-assist is enabled).
if [[ "$LIGHTSPEED" == "true" ]]; then
  [[ -n "$MAAS_KEY" && "$MAAS_KEY" != "null" && "$MAAS_KEY" != "CHANGEME" ]] \
    || die "lightspeed: true but maas.api_key is unset/CHANGEME in ${VARS}"
  oc create namespace openshift-lightspeed --dry-run=client -o yaml | oc apply -f - >/dev/null
  oc create secret generic credentials \
    --from-literal=apitoken="$MAAS_KEY" -n openshift-lightspeed \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
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

# ── 4. shared workshop password for Gitea seeding (gitea ns now exists) ───────
info "[4/6] recording the shared workshop password (secret workshop-user-creds)"
oc create secret generic workshop-user-creds \
  --from-literal=password="$WS_PASS" -n "$GITEA_NS" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null
ok "workshop-user-creds (gitea/password)"

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
  echo "password: ${WS_PASS}   # shared — console/CLI login AND Gitea"
} > "$CREDS_FILE"
chmod 600 "$CREDS_FILE"

echo
ok "workshop bootstrap complete"
echo "   console : ${CONSOLE_URL:-<run: oc whoami --show-console>}"
echo "   gitea   : https://${GITEA_HOST}"
echo "   users   : ${USER_PREFIX}1 … ${USER_PREFIX}${USERS} (shared password)"
echo "   creds   : ${CREDS_FILE} (gitignored)"
echo "   next    : ws doctor   ·   ws start m01 --user ${USER_PREFIX}1"
