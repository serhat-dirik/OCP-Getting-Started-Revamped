{{/*
canary.stack — a Deployment emitted from a NAMED TEMPLATE, called twice below with different names
and different pull policies. This is the exact shape of config-multienv's `claims.stack`, which
renders its stage and prod claims Deployments and is therefore INVISIBLE to
`grep 'image:' templates/*.yaml`. That blind spot swallowed this defect class twice (the pull-policy
sweep of 2026-07-29 and the Route-TLS sweep of 2026-07-27), and it is the reason the guard renders.

Arguments: dict with `name`, `policy` (empty string = leave imagePullPolicy unset) and `root`.
*/}}
{{- define "canary.stack" -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .name }}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: {{ .name }}
  template:
    metadata:
      labels:
        app: {{ .name }}
    spec:
      containers:
        - name: claims
          image: {{ .root.Values.workshopImage }}
          {{- if .policy }}
          imagePullPolicy: {{ .policy }}
          {{- end }}
{{- end -}}
