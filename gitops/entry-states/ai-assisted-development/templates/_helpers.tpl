{{/* The module namespace — the per-user dev namespace this chart materializes INTO but does NOT own
     (the workshop layer creates {user}-dev with quota/limits/RBAC, per-user-namespaces.yaml, like
     build-deliver/packaging-distributing). {user}-dev is SHARED with the other inner-loop modules → conflictsWith them (ws-meta). */}}
{{- define "ai-assisted-development.namespace" -}}{{ .Values.user }}-dev{{- end -}}

{{/* The in-cluster SSE endpoint the CLI agent dials. The Go kubernetes-mcp-server serves SSE at /sse
     and Streamable HTTP at /mcp when run with --port (verified against the upstream docs 2026-07-15) —
     NOT the Quarkus /mcp/sse path agentic-ai's claims-db used. Short DNS: the workspace + agent run in the
     SAME namespace as the server ({user}-dev). */}}
{{- define "ai-assisted-development.mcpSseUrl" -}}http://{{ .Values.mcpServiceName }}:{{ .Values.mcpPort }}/sse{{- end -}}

{{/* The seeded deployment's readinessProbe path. Entry (solve=false) = the WRONG path (the fault →
     Running 0/1); solve=true = the CORRECT path (the fixed end state → Running 1/1). This single field
     is the whole fault + the one-field patch that later exercises the attendee's scoped-write grant. */}}
{{- define "ai-assisted-development.probePath" -}}{{ if .Values.solve }}{{ .Values.goodProbePath }}{{ else }}{{ .Values.badProbePath }}{{ end }}{{- end -}}

{{/* The che-code editor contribution URI (design call #40, closed — see devworkspace.yaml
     `contributions` for the full decision). In-cluster svc DNS only, resolved against the Dev Spaces
     dashboard's OWN documented editor API — never an external registry, never a cluster-domain URL. */}}
{{- define "ai-assisted-development.cheEditorUri" -}}http://{{ .Values.cheDashboardService }}.{{ .Values.cheDashboardNamespace }}.svc:{{ .Values.cheDashboardPort }}/dashboard/api/editors/devfile?che-editor={{ .Values.cheEditorId }}{{- end -}}
