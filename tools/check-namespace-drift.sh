#!/usr/bin/env bash
# check-namespace-drift.sh — guards against the ogsr- namespace-rename drift class.
#
# ORIGIN (SEV1, 2026-07-18): gitops/workshop-config/templates/per-user-namespaces.yaml labeled
# every {user}-dev/stage/prod with `argocd.argoproj.io/managed-by: student-gitops` — the ArgoCD
# CR's .metadata.NAME — but the operator's namespace-scoped enrollment keys off the CR's
# .metadata.NAMESPACE (ogsr-student-gitops). The label matched nothing, the operator never created
# the RoleBindings, and every attendee Application sync failed "namespace ... is not managed". The
# root cause was a bare pre-rename short-name left behind in a NAMESPACE-valued position during the
# ogsr- rename. This guard makes that class fail CI instead of a live workshop.
#
# WHAT IT FLAGS: any of the six historical workshop namespace short-names appearing BARE (no ogsr-
# prefix) in a position that names a NAMESPACE — a `namespace:` field, an `oc -n`/`--namespace`
# flag, an `argocd.argoproj.io/managed-by` label value, or an in-cluster `<svc>.<ns>.svc` DNS name.
#
# WHAT IT DELIBERATELY DOES NOT FLAG (the audit's documented invariants — none need an allowlist,
# they simply are not namespace-valued positions):
#   • instance/resource NAMEs — `name: student-gitops`, `gitea-fork-{user}`, route `student-gitops-server`
#   • the pinned Route HOST `student-gitops-server-student-gitops.<domain>` (not a `.svc` DNS name)
#   • the `gitea` CRD kind / `oc get gitea gitea -n "$VAR"` (the `-n` there takes a variable, not a bare name)
#   • longer real namespaces that merely start with a short-name — `gitea-operator`, `…-server`,
#     `parasol-images-pull` (the trailing-terminator excludes '-', so only the exact bare name trips)
#   • already-correct `ogsr-`-prefixed names and `{{ .Values.* }}` template expressions
#   • prose/comments (they say "the gitea namespace", never "namespace: gitea")
#
# Runnable standalone (CI lint gate) and by hand; no dependencies beyond git + grep.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ok()  { echo "✅ $*"; }
err() { echo "❌ $*" >&2; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { err "not a git work tree ($REPO_ROOT)"; exit 2; }

# The six pre-ogsr-rename workshop namespace short-names. Their correct forms all carry ogsr-.
names='student-gitops|gitea|showroom|parasol-tasks|parasol-images|observability-workshop'
# One quote char (single or double), so `namespace: "gitea"` and `-n 'gitea'` are covered.
q='["'"'"']'
# Token terminator: end-of-line, or any char that is NOT a dash and NOT alphanumeric. Excluding '-'
# is what keeps gitea-operator / student-gitops-server / parasol-images-pull GREEN — only the exact
# bare short-name (nothing appended) trips. The leading context of each pattern below (`namespace: `,
# `-n `, `managed-by: `, or a literal `.`) is the LEFT anchor: an ogsr- prefix puts `ogsr-` between
# that context and the name, so the ogsr- forms never match.
term='([^-[:alnum:]]|$)'

patterns=(
  "namespace:[[:space:]]*${q}?(${names})${term}"          # YAML  namespace: <bare>
  "(-n|--namespace)[[:space:]=]+${q}?(${names})${term}"   # shell  oc -n <bare> / --namespace=<bare>
  "managed-by:[[:space:]]*${q}?(${names})${term}"         # label  argocd.argoproj.io/managed-by: <bare>
  "\\.(${names})\\.svc"                                    # DNS    <svc>.<bare>.svc[.cluster.local]
)

# The rename touched these trees; bootstrap/ added per the coordinator's scope.
scan=(gitops platform-portfolio helm tools bootstrap)
# This script necessarily embeds the bare names in its own patterns — exclude it from its own scan.
self='tools/check-namespace-drift.sh'

found=0
for pat in "${patterns[@]}"; do
  status=0
  git grep -nE "$pat" -- "${scan[@]}" ":!${self}" || status=$?
  case "$status" in
    0) found=1 ;;   # matches were printed above
    1) ;;           # no matches — clean for this pattern
    *) err "git grep failed (exit ${status}) on pattern: ${pat}"; exit 2 ;;
  esac
done

if [[ "$found" -ne 0 ]]; then
  err "Bare pre-rename workshop namespace found in a namespace-valued position (see matches above)."
  err "When one of these names identifies a NAMESPACE it must carry the ogsr- prefix (or be a chart value):"
  err "  student-gitops→ogsr-student-gitops   gitea→ogsr-gitea   showroom→ogsr-showroom"
  err "  parasol-tasks→ogsr-parasol-tasks   parasol-images→ogsr-parasol-images   observability-workshop→ogsr-observability-workshop"
  err "Prefer the chart value: .Values.studentArgoNamespace / giteaNamespace / showroom.namespace / parasolImages.namespace."
  err "(Instance/resource NAMEs, the pinned Route host, and the 'gitea' CRD kind are not namespace positions and never trip this.)"
  exit 1
fi
ok "namespace-drift guard clean — no bare pre-rename workshop namespaces in namespace-valued positions (gitops/ platform-portfolio/ helm/ tools/ bootstrap/)."
