{{/* The module namespace — a dedicated per-user namespace this chart materializes INTO but does
     NOT own (workshop layer creates {user}-ai with quota/limits/RBAC, per-user-ai.yaml, like
     {user}-modernize / {user}-batch / {user}-mesh). Disjoint from every other module → no
     conflictsWith. */}}
{{- define "m23.namespace" -}}{{ .Values.user }}-ai{{- end -}}

{{/* The agent's public Route host, derived from the cluster ingress domain (attendee-safe — the
     same pattern the verify script + ws use). OpenShift auto-assigns exactly this host for a Route
     named parasol-agent in {user}-ai, so verify can curl POST /agent/ask without a cross-namespace
     route read. */}}
{{- define "m23.agentRouteHost" -}}parasol-agent-{{ .Values.user }}-ai.{{ .Values.clusterDomain }}{{- end -}}
