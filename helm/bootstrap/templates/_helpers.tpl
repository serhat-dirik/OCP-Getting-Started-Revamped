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
Web host of the in-cluster Gitea (route `gitea` in the gitea namespace →
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
Comma-separated stack list, matching bootstrap/install.sh's STACKS string so
enumerate_operators() in ogsr-uninstall.sh derives the same operator set.
core-devtools + batch are the always-on baseline.
*/}}
{{- define "ogsr-bootstrap.installedStacks" -}}
{{- $s := list "core-devtools" "batch" -}}
{{- if .Values.stacks.lightspeed }}{{ $s = append $s "ai-assist" }}{{- end -}}
{{- if .Values.stacks.auth }}{{ $s = append $s "auth" }}{{- end -}}
{{- if .Values.stacks.resilience }}{{ $s = append $s "resilience" }}{{- end -}}
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
