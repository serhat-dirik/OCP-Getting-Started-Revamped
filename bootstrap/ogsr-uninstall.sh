#!/usr/bin/env bash
# ogsr-uninstall.sh — non-destructive uninstall for the OCP-Getting-Started workshop.
#
# Removes EXACTLY what this workshop installed onto a cluster and reverses every shared/default-object
# mutation, while NEVER touching operators, namespaces, or config the org already had. It is the
# inverse of bootstrap/install.sh and reads the ogsr-uninstall-state ConfigMap that install.sh writes.
#
# The two guarantees:
#   1. Adopted operators are NEVER removed. install.sh recorded, per operator, whether it pre-existed
#      (adopted) or was created by us; only "created" operators are removed here. Unknown → preserved.
#   2. Deleting our Argo Applications never cascade-prunes an adopted operator: each app is stripped of
#      its resources-finalizer and deleted with --cascade=orphan, so component resources are ORPHANED,
#      then only our owner-labeled (workshop.redhat.com/owner=ogsr) resources + created operators are
#      deleted explicitly.
#
# Shared/default objects are RESTORED, not blindly deleted: cluster-monitoring-config's
# enableUserWorkload returns to its recorded prior value (or the ConfigMap is removed if we created it);
# the workshop-users OAuth IdP entry is removed while every other IdP is preserved; node labels/taint
# are reversed; the GatewayClass / GitOps operator are removed only if we created them.
#
# Usage:
#   ./ogsr-uninstall.sh --dry-run     # print the WIPE/PRESERVE plan and intended actions; change nothing
#   ./ogsr-uninstall.sh               # interactive confirm, then uninstall
#   ./ogsr-uninstall.sh --yes         # no prompt (CI / scripted)
#
# Idempotent: safe to re-run; already-absent objects are skipped with a printed reason.
# NOTE: every cluster interaction below is unverified off-cluster — run against a disposable cluster
# first. Lines that need live verification are marked  # TODO(verify-on-cluster).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OWNER_LABEL="workshop.redhat.com/owner=ogsr"
STATE_NS="ogsr-system"
STATE_CM="ogsr-uninstall-state"
ARGO_NS="openshift-gitops"
POOL_KEY="workshop.redhat.com/pool"
ZONE_KEY="workshop.redhat.com/zone"

DRY_RUN="false"
ASSUME_YES="false"

ok()   { echo "✅ $*"; }
err()  { echo "❌ $*" >&2; }
info() { echo "▶ $*"; }
die()  { err "$*"; exit 1; }

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//' | sed -n '1,28p'; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN="true"; shift;;
    --yes|-y)  ASSUME_YES="true"; shift;;
    -h|--help) usage;;
    *) err "unknown flag: $1"; usage;;
  esac
done

# ── preflight ─────────────────────────────────────────────────────────────────
command -v oc >/dev/null || die "oc not found in PATH"
command -v yq >/dev/null || die "yq not found — needed to read component manifests (brew install yq)"
oc whoami >/dev/null 2>&1 || die "not logged in — run: oc login …"
oc auth can-i '*' '*' --all-namespaces >/dev/null 2>&1 \
  || die "need cluster-admin to uninstall (oc auth can-i '*' '*' failed as $(oc whoami))"

if ! oc get configmap "$STATE_CM" -n "$STATE_NS" >/dev/null 2>&1; then
  err "uninstall-state ConfigMap ${STATE_NS}/${STATE_CM} not found."
  err "Without it, adopted-vs-created is unknown and this script defaults to PRESERVING operators/shared"
  err "objects (safe). It still removes owner-labeled (${OWNER_LABEL}) resources + workshop namespaces."
fi

# ── state helpers ─────────────────────────────────────────────────────────────
state() {  # key [default] — echo a recorded value from the uninstall-state ConfigMap (or the default)
  local k="$1" def="${2:-}" v
  v="$(oc get configmap "$STATE_CM" -n "$STATE_NS" -o jsonpath="{.data['$k']}" 2>/dev/null || true)"
  if [[ -n "$v" ]]; then echo "$v"; else echo "$def"; fi
}

# Re-derive the operators the install installed, from the SAME component manifests + recorded stacks.
# Echoes one "subname namespace state" line per operator (state = created|adopted|unknown).
enumerate_operators() {
  local stacks stack app comp_path sub name ns st _stacks
  stacks="$(state installed_stacks)"
  [[ -n "$stacks" ]] || return 0
  IFS=',' read -ra _stacks <<< "$stacks"
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
        st="$(state "op_${name}" | cut -d: -f1)"
        [[ -n "$st" ]] || st="unknown"
        echo "${name} ${ns} ${st}"
      done
    done
  done
}

# ── delete helpers (all dry-run aware, all tolerant of already-absent objects) ─
del_obj() {  # kind name [ns] — delete one object if it exists; print a skip reason if absent
  local kind="$1" name="$2" ns="${3:-}" loc
  loc="${kind}/${name}"; [[ -n "$ns" ]] && loc="${loc} -n ${ns}"
  if [[ -n "$ns" ]]; then
    oc get "$kind" "$name" -n "$ns" >/dev/null 2>&1 || { echo "   • skip ${loc} (absent)"; return 0; }
  else
    oc get "$kind" "$name" >/dev/null 2>&1 || { echo "   • skip ${loc} (absent)"; return 0; }
  fi
  if [[ "$DRY_RUN" == "true" ]]; then echo "   • WOULD delete ${loc}"; return 0; fi
  if [[ -n "$ns" ]]; then
    oc delete "$kind" "$name" -n "$ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  else
    oc delete "$kind" "$name" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
  ok "deleted ${loc}"
}

del_labeled_cluster() {  # kind — delete owner-labeled objects of a CLUSTER-SCOPED kind (skips if CRD absent)
  local kind="$1" name
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    del_obj "$kind" "$name"
  done < <(oc get "$kind" -l "$OWNER_LABEL" -o name 2>/dev/null | sed 's|.*/||' || true)
}

del_labeled_namespaced() {  # kind — delete owner-labeled objects of a NAMESPACED kind across all namespaces
  local kind="$1" line ns name
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    ns="${line%% *}"; name="${line##* }"
    [[ -n "$ns" && -n "$name" ]] || continue
    del_obj "$kind" "$name" "$ns"
  done < <(oc get "$kind" -l "$OWNER_LABEL" -A \
            -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
}

# ── reverse the imperative bootstrap mutations ────────────────────────────────
remove_oauth_idp() {  # remove ONLY the workshop-users IdP entry, preserving every other identity provider
  local owned names n idx i backing
  owned="$(state oauth_idp_ownedbyus)"
  if [[ "$owned" != "true" ]]; then
    # Retrofit safety: a pre-Wave-1 install (no state ConfigMap) leaves oauth_idp_ownedbyus unrecorded,
    # so this branch would PRESERVE 'workshop-users' — but step 4 deletes the htpasswd secret it points
    # at, stranding a broken login provider on the org's cluster (fails "uninstall fully reverses"). The
    # IdP is unambiguously ours when it is backed by OUR htpasswd-workshop-users secret; remove it then.
    backing="$(oc get oauth cluster -o jsonpath='{.spec.identityProviders[?(@.name=="workshop-users")].htpasswd.fileData.name}' 2>/dev/null || true)"
    if [[ "$backing" != "htpasswd-workshop-users" ]]; then
      echo "   • preserve OAuth IdP 'workshop-users' (not ours: no state record, not backed by htpasswd-workshop-users)"; return 0
    fi
    echo "   • OAuth IdP 'workshop-users' is backed by our htpasswd-workshop-users secret — removing (retrofit-safe)"
  fi
  names="$(oc get oauth cluster -o jsonpath='{range .spec.identityProviders[*]}{.name}{"\n"}{end}' 2>/dev/null || true)"
  idx=-1; i=0
  while IFS= read -r n; do
    if [[ "$n" == "workshop-users" ]]; then idx="$i"; break; fi
    i=$((i + 1))
  done <<< "$names"
  if [[ "$idx" -lt 0 ]]; then echo "   • skip OAuth IdP 'workshop-users' (already absent)"; return 0; fi
  if [[ "$DRY_RUN" == "true" ]]; then echo "   • WOULD remove OAuth IdP 'workshop-users' (index ${idx}; other IdPs preserved)"; return 0; fi
  oc patch oauth cluster --type=json -p "[{\"op\":\"remove\",\"path\":\"/spec/identityProviders/${idx}\"}]" >/dev/null 2>&1 || true
  ok "removed OAuth IdP 'workshop-users' (existing IdPs preserved)"  # TODO(verify-on-cluster)
}

remove_console_plugins() {  # remove ONLY the plugin names workshop-config recorded as added (backlog #24)
  local added n idx i cur
  added="$(state console_plugins_added)"
  if [[ -z "$added" ]]; then
    echo "   • skip console plugins (no console_plugins_added recorded — feature never enabled, or nothing was newly added)"
    return 0
  fi
  for n in $added; do
    [[ -n "$n" ]] || continue
    # Recompute the index every iteration: removing one entry shifts every index after it.
    idx=-1; i=0
    while IFS= read -r cur; do
      if [[ "$cur" == "$n" ]]; then idx="$i"; break; fi
      i=$((i + 1))
    done < <(oc get consoles.operator.openshift.io cluster -o jsonpath='{range .spec.plugins[*]}{@}{"\n"}{end}' 2>/dev/null || true)
    if [[ "$idx" -lt 0 ]]; then
      echo "   • skip console plugin '${n}' (already absent)"
      continue
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "   • WOULD remove console plugin '${n}' from spec.plugins (index ${idx}; other plugins preserved)"
      continue
    fi
    oc patch consoles.operator.openshift.io cluster --type=json -p "[{\"op\":\"remove\",\"path\":\"/spec/plugins/${idx}\"}]" >/dev/null 2>&1 || true
    ok "removed console plugin '${n}' from spec.plugins (existing plugins preserved)"  # TODO(verify-on-cluster)
  done
}

restore_monitoring() {  # put cluster-monitoring-config back the way we found it
  local existed prior
  existed="$(state monitoring_cm_existed)"
  prior="$(state monitoring_uwm_prior)"
  if [[ "$existed" == "false" ]]; then
    # Default clusters ship WITHOUT this ConfigMap — the portfolio created it, so we remove it.
    del_obj configmap cluster-monitoring-config openshift-monitoring
    return 0
  fi
  if [[ "$existed" != "true" ]]; then
    echo "   • skip cluster-monitoring-config (no recorded prior state — left as-is)"; return 0
  fi
  case "$prior" in
    true)
      echo "   • preserve cluster-monitoring-config (user-workload monitoring was already ON before install)";;
    false)
      if [[ "$DRY_RUN" == "true" ]]; then echo "   • WOULD restore enableUserWorkload=false in cluster-monitoring-config"; return 0; fi
      oc get configmap cluster-monitoring-config -n openshift-monitoring -o yaml 2>/dev/null \
        | sed 's/enableUserWorkload: *true/enableUserWorkload: false/' \
        | oc apply -f - >/dev/null 2>&1 || true
      ok "restored enableUserWorkload=false in cluster-monitoring-config";;  # TODO(verify-on-cluster)
    *)
      err "cluster-monitoring-config pre-existed WITHOUT enableUserWorkload; we added it. Remove it manually:"
      echo "      oc -n openshift-monitoring edit configmap cluster-monitoring-config   # delete the enableUserWorkload line";;
  esac
}

reverse_node_shaping() {  # remove the batch pool label+taint and the synthetic zone labels
  local node
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    if [[ "$DRY_RUN" == "true" ]]; then echo "   • WOULD untaint+unlabel node/${node} (${POOL_KEY})"; continue; fi
    oc adm taint nodes "$node" "${POOL_KEY}=batch:NoSchedule-" >/dev/null 2>&1 || true
    oc label node "$node" "${POOL_KEY}-" >/dev/null 2>&1 || true
    ok "removed batch pool label+taint from node/${node}"
  done < <(oc get nodes -l "$POOL_KEY" -o name 2>/dev/null | sed 's|.*/||' || true)
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    if [[ "$DRY_RUN" == "true" ]]; then echo "   • WOULD remove ${ZONE_KEY} label from node/${node}"; continue; fi
    oc label node "$node" "${ZONE_KEY}-" >/dev/null 2>&1 || true
    ok "removed ${ZONE_KEY} label from node/${node}"
  done < <(oc get nodes -l "$ZONE_KEY" -o name 2>/dev/null | sed 's|.*/||' || true)
}

handle_lightspeed() {  # remove our MaaS secret / namespace only when WE installed Lightspeed
  local preinstalled ns_created
  preinstalled="$(state lightspeed_preinstalled)"
  ns_created="$(state lightspeed_ns_created)"
  if [[ "$preinstalled" == "true" ]]; then
    echo "   • preserve OpenShift Lightspeed (pre-installed / adopted — untouched)"; return 0
  fi
  del_obj secret credentials openshift-lightspeed
  if [[ "$ns_created" == "true" ]]; then
    del_obj namespace openshift-lightspeed
  else
    echo "   • preserve namespace/openshift-lightspeed (pre-existed; removed only our secret + operator)"
  fi
}

handle_gitops() {  # remove the GitOps operator ONLY if we created it; otherwise preserve (+ note the memory bump)
  local preexisted csv b64
  preexisted="$(state gitops_preexisted)"
  if [[ "$preexisted" == "false" ]]; then
    info "GitOps was installed by us — removing operator + default instance"
    del_obj argocd openshift-gitops openshift-gitops
    csv="$(oc get subscription openshift-gitops-operator -n openshift-gitops-operator -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
    del_obj subscription openshift-gitops-operator openshift-gitops-operator
    [[ -n "$csv" ]] && del_obj clusterserviceversion "$csv" openshift-gitops-operator
    del_obj operatorgroup openshift-gitops-operator openshift-gitops-operator
    del_obj namespace openshift-gitops
    del_obj namespace openshift-gitops-operator
  else
    info "GitOps was adopted (pre-existing) — operator + instance preserved"
    b64="$(state gitops_argocd_controller_resources_b64)"
    if [[ -n "$b64" ]]; then
      err "install raised the adopted openshift-gitops controller memory (limit 6Gi). Prior spec.controller.resources:"
      echo "      $(echo "$b64" | base64 --decode 2>/dev/null || echo '<unreadable>')"
      echo "      restore manually if the org relied on it: oc -n openshift-gitops edit argocd openshift-gitops"
    fi
  fi
}

cleanup_created_operators() {  # remove Subscription+CSV for operators WE created (covers shared-ns operators)
  local name ns st csv
  while read -r name ns st; do
    [[ -n "$name" ]] || continue
    if [[ "$st" == "created" ]]; then
      csv="$(oc get subscription "$name" -n "$ns" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
      del_obj subscription "$name" "$ns"
      [[ -n "$csv" ]] && del_obj clusterserviceversion "$csv" "$ns"
    else
      echo "   • preserve operator ${name} in ${ns} (${st} — not created by us)"
    fi
  done < <(enumerate_operators)
}

delete_workshop_namespaces() {  # delete owner-labeled namespaces, skipping adopted-operator namespaces
  local adopted_ns="" name ns st n
  while read -r name ns st; do
    [[ -n "$ns" ]] || continue
    if [[ "$st" != "created" ]]; then adopted_ns="${adopted_ns} ${ns}"; fi  # adopted OR unknown → preserve its ns
  done < <(enumerate_operators)
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    # These are handled elsewhere (state CM lives in ogsr-system; Lightspeed has its own guard).
    [[ "$n" == "$STATE_NS" || "$n" == "openshift-lightspeed" ]] && continue
    case " $adopted_ns " in
      *" $n "*) echo "   • preserve namespace/${n} (adopted-operator namespace)"; continue;;
    esac
    del_obj namespace "$n"
  done < <(oc get namespaces -l "$OWNER_LABEL" -o name 2>/dev/null | sed 's|.*/||' || true)
}

# ── plan ──────────────────────────────────────────────────────────────────────
print_plan() {
  local apps ns_list created adopted name ns st gitops_plan mon_plan gw_plan
  apps="$(oc get applications -n "$ARGO_NS" -l "$OWNER_LABEL" -o name 2>/dev/null | wc -l | tr -d ' ' || echo '?')"
  ns_list="$(oc get namespaces -l "$OWNER_LABEL" -o name 2>/dev/null | sed 's|.*/||' | tr '\n' ' ' || true)"
  created=""; adopted=""
  while read -r name ns st; do
    [[ -n "$name" ]] || continue
    if [[ "$st" == "created" ]]; then created="${created} ${name}"; else adopted="${adopted} ${name}(${st})"; fi
  done < <(enumerate_operators)

  # Three-way plans: created-by-us → REMOVE/restore; recorded-adopted → PRESERVE; NO state record at all
  # (pre-Wave-1 install, or the state CM was lost) → PRESERVE and say so honestly. Found in the 2026-07-17
  # verification pass: the old two-way else printed "restore → ?" on a stateless cluster while step 4
  # correctly skipped — the summary must match the action.
  case "$(state gitops_preexisted '')" in
    false) gitops_plan="REMOVE (we installed it)";;
    true)  gitops_plan="PRESERVE (adopted)";;
    *)     gitops_plan="PRESERVE (no state recorded)";;
  esac
  case "$(state monitoring_cm_existed '')" in
    false) mon_plan="REMOVE (we created it)";;
    true)  mon_plan="restore enableUserWorkload → $(state monitoring_uwm_prior '?')";;
    *)     mon_plan="PRESERVE (no state recorded)";;
  esac
  case "$(state gatewayclass_preexisted '')" in
    false) gw_plan="REMOVE (we created it)";;
    true)  gw_plan="PRESERVE (adopted)";;
    *)     gw_plan="PRESERVE (no state recorded)";;
  esac

  echo "ogsr-uninstall — WIPE the workshop, PRESERVE everything the org owns"
  echo
  echo "WILL WIPE:"
  echo "  • ${apps} owner-labeled Argo Applications (pp-*, workshop-config, entry-*) — orphaned, not pruned"
  echo "  • owner-labeled namespaces: ${ns_list:-<none / cluster unreachable>}"
  echo "  • owner-labeled cluster RBAC (platform-observer, lightspeed-query, argo controller CRB),"
  echo "    Group workshop-attendees, Kueue cluster objects, AppProjects, openshift/java-21 ImageStream"
  echo "  • imperative bootstrap objects: htpasswd-workshop-users, workshop-users OAuth IdP entry, node labels/taint"
  echo "  • console plugins WE added to consoles.operator.openshift.io (backlog #24): $(state console_plugins_added '<none recorded>')"
  echo "  • operators WE created:${created:-<none recorded>}"
  echo
  echo "WILL PRESERVE (untouched):"
  echo "  • operators the org already had:${adopted:-<none recorded>}"
  echo "  • GitOps operator: ${gitops_plan}"
  echo "  • cluster-monitoring-config: ${mon_plan}"
  echo "  • openshift-default GatewayClass: ${gw_plan}"
  echo "  • every namespace/operator/CR the org owns and we never labeled"
  echo
}

# ── main ──────────────────────────────────────────────────────────────────────
echo "▶ ogsr-uninstall  (cluster: $(oc whoami --show-server 2>/dev/null || echo '?') as $(oc whoami 2>/dev/null || echo '?'))"
[[ "$DRY_RUN" == "true" ]] && echo "  MODE: --dry-run (no changes will be made)"
echo
print_plan

if [[ "$DRY_RUN" == "true" ]]; then
  info "dry-run — showing intended actions (no changes made):"
else
  if [[ "$ASSUME_YES" != "true" ]]; then
    if [[ -t 0 ]]; then
      read -r -p "Proceed — WIPE the workshop, PRESERVE the org? [y/N] " reply
      [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]] || { info "nothing changed. Re-run with --yes when ready."; exit 0; }
    else
      die "not a terminal and no --yes given — re-run: ./ogsr-uninstall.sh --yes"
    fi
  fi
fi

# 1. Stop reconciliation on ALL our apps first, so no app-of-apps re-creates a child mid-teardown.
info "[1/9] stopping reconciliation on workshop Argo Applications"
while IFS= read -r app; do
  [[ -n "$app" ]] || continue
  if [[ "$DRY_RUN" == "true" ]]; then echo "   • WOULD disable automated sync on application/${app}"; continue; fi
  oc patch application "$app" -n "$ARGO_NS" --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null 2>&1 || true
done < <(oc get applications -n "$ARGO_NS" -l "$OWNER_LABEL" -o name 2>/dev/null | sed 's|.*/||' || true)

# 2. Orphan + delete our apps (drop the resources-finalizer, --cascade=orphan) so deleting them NEVER
#    prunes an adopted operator. The workshop's own resources are removed explicitly in later steps.
info "[2/9] deleting workshop Argo Applications (orphaning their resources)"
while IFS= read -r app; do
  [[ -n "$app" ]] || continue
  if [[ "$DRY_RUN" == "true" ]]; then echo "   • WOULD orphan+delete application/${app}"; continue; fi
  oc patch application "$app" -n "$ARGO_NS" --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null 2>&1 || true
  oc delete application "$app" -n "$ARGO_NS" --cascade=orphan --ignore-not-found --wait=false >/dev/null 2>&1 || true
  ok "orphaned + deleted application/${app}"
done < <(oc get applications -n "$ARGO_NS" -l "$OWNER_LABEL" -o name 2>/dev/null | sed 's|.*/||' || true)

# 3. Remove Subscriptions/CSVs for operators WE created (dedicated-ns ones also go with their namespace).
info "[3/9] removing operators we created (adopted operators preserved)"
cleanup_created_operators

# 4. Reverse the imperative, cluster-global mutations.
info "[4/9] reversing imperative cluster mutations (OAuth IdP, console plugins, monitoring, nodes, htpasswd)"
remove_oauth_idp
remove_console_plugins
del_obj secret htpasswd-workshop-users openshift-config
handle_lightspeed
restore_monitoring
reverse_node_shaping

# 5. GatewayClass — remove only if we created it.
info "[5/9] Gateway API"
if [[ "$(state gatewayclass_preexisted)" == "false" ]]; then
  del_obj gatewayclass.gateway.networking.k8s.io openshift-default
else
  echo "   • preserve GatewayClass/openshift-default (adopted / pre-existing)"
fi

# 6. Cluster-scoped workshop objects (always created by us — safe to delete by owner label).
info "[6/9] deleting owner-labeled cluster-scoped resources"
del_labeled_cluster clusterrolebindings.rbac.authorization.k8s.io
del_labeled_cluster clusterroles.rbac.authorization.k8s.io
del_labeled_cluster groups.user.openshift.io
del_labeled_cluster resourceflavors.kueue.x-k8s.io
del_labeled_cluster workloadpriorityclasses.kueue.x-k8s.io
del_labeled_cluster clusterqueues.kueue.x-k8s.io

# 7. Namespaced workshop objects that live in shared namespaces we must NOT delete.
info "[7/9] deleting owner-labeled objects in shared namespaces (java-21 ImageStream, AppProjects)"
del_obj imagestream.image.openshift.io java-21 openshift
del_labeled_namespaced appprojects.argoproj.io

# 8. GitOps operator — remove only if we created it (else preserve + note the controller-memory bump).
info "[8/9] GitOps operator"
handle_gitops

# 9. Workshop namespaces (per-user + shared), then the state namespace last.
info "[9/9] deleting workshop namespaces (org / adopted-operator namespaces preserved)"
delete_workshop_namespaces
del_obj namespace "$STATE_NS"

echo
ok "ogsr-uninstall complete${DRY_RUN:+ (dry-run)}"
cat <<'VERIFY'

   Verify (run after the namespaces finish terminating):
     oc get ns -l workshop.redhat.com/owner=ogsr                 # expect: no resources
     oc get applications -n openshift-gitops | grep -E 'pp-|entry-|workshop-config'   # expect: none
     oc get clusterrole,clusterrolebinding -l workshop.redhat.com/owner=ogsr          # expect: none
     oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}'; echo       # expect: workshop-users absent
     oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}'; echo  # expect: names WE added absent, everything else preserved
     # Adopted operators must still be Present/Succeeded:
     oc get csv -A | grep -Ev 'ogsr'                             # org operators intact
VERIFY
