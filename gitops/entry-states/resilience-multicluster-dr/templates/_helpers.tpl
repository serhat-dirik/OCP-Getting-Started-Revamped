{{/* The external-CLIENT namespace: the curl-loop client + the mesh ingress gateway (the stable endpoint). */}}
{{- define "resilience-multicluster-dr.clientNs" -}}{{ .Values.user }}-client{{- end -}}

{{/* SITE A — the PRIMARY resilient claims service (co-located with the gateway's locality). */}}
{{- define "resilience-multicluster-dr.siteANs" -}}{{ .Values.user }}-site-a{{- end -}}

{{/* SITE B — the SECONDARY / failover resilient claims service. */}}
{{- define "resilience-multicluster-dr.siteBNs" -}}{{ .Values.user }}-site-b{{- end -}}
