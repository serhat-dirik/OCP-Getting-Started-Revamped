{{/*
=============================================================================
ogsr-bootstrap helpers
=============================================================================
*/}}

{{/*
Owner + provenance labels stamped on every resource this chart renders, so
ogsr-uninstall.sh can enumerate (oc get … -l workshop.redhat.com/owner=ogsr)
and target the whole FSC footprint. Never emitted into a selector/matchLabels.
*/}}
{{- define "ogsr-bootstrap.ownerLabels" -}}
workshop.redhat.com/owner: {{ .Values.owner | quote }}
app.kubernetes.io/part-of: {{ .Values.owner | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
{{- end -}}

{{/*
Web host of the in-cluster Gitea (route `gitea` in the ogsr-gitea namespace →
default host gitea-<ns>.<domain>). Single source for the mirror + userinfo URLs.
*/}}
{{- define "ogsr-bootstrap.giteaHost" -}}
gitea-{{ .Values.namespaces.gitea }}.{{ .Values.deployer.domain }}
{{- end -}}

{{/*
Git URL of the in-cluster mirror the wave-2 children are sourced from
(the git-localize payoff). Repos are public in Gitea → no auth for Argo to clone.
*/}}
{{- define "ogsr-bootstrap.mirrorRepoURL" -}}
https://{{ include "ogsr-bootstrap.giteaHost" . }}/{{ .Values.gitea.org }}/{{ .Values.gitea.repo }}.git
{{- end -}}

{{/*
Disabled module SLUGS, space-joined, resolved from .Values.modulesDisabled (each entry is `mNN`
or a slug). mNN is resolved by 1-based position into .Values.moduleCatalog (generated from
/modules.yaml — Helm can't read that file). An unknown token or out-of-range number fails the
render loudly rather than silently ignoring a typo that would leave a module unexpectedly on.
*/}}
{{- define "ogsr-bootstrap.disabledSlugs" -}}
{{- $catalog := .Values.moduleCatalog | default (list) -}}
{{- $out := list -}}
{{- range $tok := (.Values.modulesDisabled | default (list)) -}}
{{- $t := $tok | toString | trim | lower -}}
{{- if $t -}}
{{- if regexMatch "^m[0-9]+$" $t -}}
{{- $idx := sub (atoi (trimPrefix "m" $t)) 1 -}}
{{- if and (ge $idx 0) (lt $idx (len $catalog)) -}}
{{- $out = append $out (index $catalog $idx).slug -}}
{{- else -}}
{{- fail (printf "modulesDisabled: module number %q is out of range (1..%d)" $t (len $catalog)) -}}
{{- end -}}
{{- else -}}
{{- $found := false -}}
{{- range $m := $catalog -}}{{- if eq $m.slug $t -}}{{- $found = true -}}{{- end -}}{{- end -}}
{{- if $found -}}{{- $out = append $out $t -}}{{- else -}}{{- fail (printf "modulesDisabled: unknown module %q (use mNN or a slug from modules.yaml)" $t) -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- join " " $out -}}
{{- end -}}

{{/*
Disabled module slugs as a comma-joined string, for the workshop-config Application's
modulesDisabledCSV Helm parameter (Argo helm.parameters can't carry a YAML list reliably, so the
showroom hiding travels as a scalar CSV the chart splits — see gitops/workshop-config).
*/}}
{{- define "ogsr-bootstrap.disabledSlugsCSV" -}}
{{- $d := include "ogsr-bootstrap.disabledSlugs" . | trim -}}
{{- if $d -}}{{- $d | replace " " "," -}}{{- end -}}
{{- end -}}

{{/*
Space-joined set of NON-baseline platform stacks to install: the UNION of `stacks` required by
every ENABLED module (moduleCatalog minus disabledSlugs), plus any expert additive override
(.Values.stacks.<name> == true). Deterministic order (first-seen in catalog order, then overrides).
core-devtools / batch / progressive-delivery are baseline and never appear here; ai-assist is
governed separately (see lightspeedEnabled).
*/}}
{{- define "ogsr-bootstrap.requiredStacks" -}}
{{- $catalog := .Values.moduleCatalog | default (list) -}}
{{- $disabled := splitList " " (include "ogsr-bootstrap.disabledSlugs" .) -}}
{{- $stacks := list -}}
{{- range $m := $catalog -}}
{{- if not (has $m.slug $disabled) -}}
{{- range $s := ($m.stacks | default (list)) -}}
{{- if not (has $s $stacks) -}}{{- $stacks = append $stacks $s -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $ov := .Values.stacks | default dict -}}
{{- range $name := (list "auth" "resilience" "mesh" "serverless" "mta" "observability" "appsec" "portal" "trust") -}}
{{- if index $ov $name -}}{{- if not (has $name $stacks) -}}{{- $stacks = append $stacks $name -}}{{- end -}}{{- end -}}
{{- end -}}
{{- if $ov.trustDemo -}}{{- if not (has "trust-demo" $stacks) -}}{{- $stacks = append $stacks "trust-demo" -}}{{- end -}}{{- end -}}
{{- join " " $stacks -}}
{{- end -}}

{{/*
"true"/"false" — is OpenShift Lightspeed (the ai-assist stack) installed? AUTO-SKIP contract:
on only when litemaas.enabled AND both litemaas.apiUrl and litemaas.apiKey are set (no LLM
endpoint/key ⇒ skipped, no deployer action needed). The stacks.lightspeed expert override forces
it on. NOT tied to module selection.

The `lightspeed: false` top-level key is the HARD OFF and wins over both — the twin of
bootstrap/install.sh's `LIGHTSPEED_REQ == "false"` branch, which is evaluated before anything else
for the same reason. Tested for an explicit boolean false (`kindIs "bool"`), never for
truthiness: unset is null, and null must mean "auto", not "off".
*/}}
{{- define "ogsr-bootstrap.lightspeedEnabled" -}}
{{- $lm := .Values.litemaas | default dict -}}
{{- $on := false -}}
{{- if and $lm.enabled (ne (trim (toString ($lm.apiKey | default ""))) "") (ne (trim (toString ($lm.apiUrl | default ""))) "") -}}{{- $on = true -}}{{- end -}}
{{- if (.Values.stacks | default dict).lightspeed -}}{{- $on = true -}}{{- end -}}
{{- if and (kindIs "bool" .Values.lightspeed) (not .Values.lightspeed) -}}{{- $on = false -}}{{- end -}}
{{- ternary "true" "false" $on -}}
{{- end -}}

{{/*
Comma-separated FULL stack list actually installed (baseline + required + ai-assist when
lightspeed is on), matching bootstrap/install.sh's STACKS string so enumerate_operators() in
ogsr-uninstall.sh derives the same operator set for a non-destructive uninstall.
*/}}
{{- define "ogsr-bootstrap.installedStacks" -}}
{{- $s := list "core-devtools" "batch" "progressive-delivery" -}}
{{- range $st := (splitList " " (include "ogsr-bootstrap.requiredStacks" .)) -}}
{{- if $st -}}{{- $s = append $s $st -}}{{- end -}}
{{- end -}}
{{- if eq (include "ogsr-bootstrap.lightspeedEnabled" .) "true" -}}{{- $s = append $s "ai-assist" -}}{{- end -}}
{{- join "," $s -}}
{{- end -}}

{{/*
Space-separated attendee usernames. Uses the explicit FSC roster
(multi_user.users[].username) when provided, else userPrefix1..num_users.
Consumed by the workshop-users Job to build the htpasswd file.
*/}}
{{- define "ogsr-bootstrap.userList" -}}
{{- $names := list -}}
{{- if .Values.multi_user.users -}}
{{- range .Values.multi_user.users }}{{ $names = append $names .username }}{{- end -}}
{{- else -}}
{{- range $i := until (int .Values.multi_user.num_users) }}{{ $names = append $names (printf "%s%d" $.Values.multi_user.userPrefix (add $i 1)) }}{{- end -}}
{{- end -}}
{{- join " " $names -}}
{{- end -}}
