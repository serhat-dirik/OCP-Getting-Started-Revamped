{{/* The per-user ClusterQueue this module's LocalQueue points at. Defaults to cq-{user}
     (the workshop-layer naming in gitops/workshop-config/templates/kueue-queues.yaml). */}}
{{- define "m06.clusterQueue" -}}
{{- if .Values.clusterQueue }}{{ .Values.clusterQueue }}{{ else }}cq-{{ .Values.user }}{{ end }}
{{- end -}}

{{/* The module namespace — a module-extra namespace this chart owns (like {user}-mesh). */}}
{{- define "m06.namespace" -}}{{ .Values.user }}-batch{{- end -}}
