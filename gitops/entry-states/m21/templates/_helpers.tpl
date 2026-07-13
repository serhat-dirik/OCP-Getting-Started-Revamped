{{/* The external-CLIENT namespace: the curl-loop client + the mesh ingress gateway (the stable endpoint). */}}
{{- define "m21.clientNs" -}}{{ .Values.user }}-client{{- end -}}

{{/* SITE A — the PRIMARY resilient claims service (co-located with the gateway's locality). */}}
{{- define "m21.siteANs" -}}{{ .Values.user }}-site-a{{- end -}}

{{/* SITE B — the SECONDARY / failover resilient claims service. */}}
{{- define "m21.siteBNs" -}}{{ .Values.user }}-site-b{{- end -}}
