{{/*
copy-drift-canary.ownerLabels — mirrors the shape of workshop-config.ownerLabels so the self-test
exercises an `include`d label helper, the thing a text-stripping comparator cannot expand.
*/}}
{{- define "copy-drift-canary.ownerLabels" -}}
workshop.redhat.com/owner: {{ .Values.owner }}
{{- end -}}
