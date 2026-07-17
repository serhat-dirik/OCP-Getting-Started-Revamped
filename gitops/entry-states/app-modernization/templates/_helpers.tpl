{{/* The module namespace — a dedicated per-user namespace this chart materializes INTO but does
     NOT own (workshop layer creates {user}-modernize with quota/limits/RBAC, per-user-modernize.yaml,
     like {user}-batch / {user}-mesh). Disjoint from every other module → no conflictsWith. */}}
{{- define "app-modernization.namespace" -}}{{ .Values.user }}-modernize{{- end -}}

{{/* The attendee's Gitea fork URL of the legacy migration target (route host derived from the
     cluster ingress domain, attendee-safe — same pattern the verify script + ws use). */}}
{{- define "app-modernization.legacyRepoUrl" -}}https://gitea-{{ .Values.giteaNamespace }}.{{ .Values.clusterDomain }}/{{ .Values.user }}/{{ .Values.forkRepo }}{{- end -}}
