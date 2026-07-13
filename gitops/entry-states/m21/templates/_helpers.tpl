{{/* The resilient-stack namespace this chart's main workloads live in (workshop-layer owned). */}}
{{- define "m21.resilienceNs" -}}{{ .Values.user }}-resilience{{- end -}}

{{/* The simulated remote-site namespace (standalone claims Postgres for the RHSI Connector beat). */}}
{{- define "m21.siteBNs" -}}{{ .Values.user }}-site-b{{- end -}}
