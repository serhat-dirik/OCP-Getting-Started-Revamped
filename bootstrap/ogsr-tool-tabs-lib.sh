#!/usr/bin/env bash
# ogsr-tool-tabs-lib.sh — the `cockpit_tool_tabs: auto` rule (bootstrap/vars.yaml), in one place.
# SOURCED, never executed: bootstrap/install.sh resolves with it, `adm doctor` explains with it, and
# tools/lint/tool-tabs-auto-guard.sh drives it under a stubbed `oc`. helm/bootstrap's
# job-cockpit-attributes.yaml carries a copy (its image has no repo); the guard runs both.
#
# oauth-openshift is a passthrough route, so a page it renders itself (the provider chooser, a password
# form) never shows inside a frame. It renders none only when it can redirect straight on: exactly ONE
# identity provider, of a redirect type, and no kubeadmin Secret (kube:admin is a second chooser entry).
# Then every cockpit tab embeds; otherwise the three that sign in through it (OCP Console, Dev Spaces,
# Argo CD) open in a new browser tab ("mixed").

# cockpit_tool_tabs_auto → "embedded|mixed<TAB>why" on stdout, rc 0; "unknown<TAB>why", rc 2, when the
# cluster cannot be read. `workshop-users` is skipped: install.sh retires that legacy IdP (step 6b).
cockpit_tool_tabs_auto() {
  local out rc=0 n t count=0 names="" pw="" ka="" why
  out="$(oc get oauth cluster -o jsonpath='{range .spec.identityProviders[*]}{.name}{"\t"}{.type}{"\n"}{end}' 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then printf 'unknown\tOAuth config not readable: %s\n' "${out%%$'\n'*}"; return 2; fi
  while IFS=$'\t' read -r n t; do
    [[ -n "$n" && "$n" != workshop-users ]] || continue
    count=$((count + 1)); names="${names:+${names}, }${n} (${t})"
    case "$t" in HTPasswd|LDAP|Keystone|BasicAuth) pw="$n" ;; esac
  done <<< "$out"
  rc=0; out="$(oc get secret kubeadmin -n kube-system -o name 2>&1)" || rc=$?
  if [[ "$rc" -eq 0 ]]; then ka="yes"
  elif ! grep -qiE 'not ?found' <<< "$out"; then printf 'unknown\tkubeadmin Secret not readable: %s\n' "${out%%$'\n'*}"; return 2
  fi
  if [[ "$count" -eq 1 && -z "$pw" && -z "$ka" ]]; then
    printf 'embedded\tone redirect sign-in, %s, and no kubeadmin\n' "$names"; return 0
  fi
  if [[ "$count" -eq 0 ]]; then why="no identity provider"
  elif [[ "$count" -gt 1 ]]; then why="${count} identity providers: ${names}"
  elif [[ -n "$pw" ]]; then why="${names} is a password form"
  else why="$names"; fi
  [[ -z "$ka" ]] || why="${why} + kubeadmin"
  printf 'mixed\t%s, so OpenShift shows its own sign-in page, which no frame shows\n' "$why"
}
