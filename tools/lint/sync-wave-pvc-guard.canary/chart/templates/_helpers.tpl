{{/*
canary.pvcPair — emits a PersistentVolumeClaim AND the Deployment that mounts it, together, from a
NAMED TEMPLATE. This is the shape gitops/workshop-config/templates/showroom-shared.yaml has: one
construct emits both sides, so `grep sync-wave templates/*.yaml` sees annotations it cannot attribute
to either object and `grep claimName` sees a single interpolated string. Neither can pair them, and
the pairing is the whole question. That is why this guard renders.

Arguments: dict with
  name       — object name, shared by the PVC and its Deployment
  namespace  — both objects go here; claim resolution is namespace-local
  pvcWave    — sync-wave for the PVC   ("" = emit NO annotation, i.e. Argo's implicit wave 0)
  appWave    — sync-wave for the workload ("" = emit NO annotation)
  class      — storageClassName        ("" = omit, i.e. take the cluster default)
*/}}
{{- define "canary.pvcPair" -}}
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ .name }}
  namespace: {{ .namespace }}
  {{- if .pvcWave }}
  annotations:
    argocd.argoproj.io/sync-wave: {{ .pvcWave | quote }}
  {{- end }}
spec:
  accessModes: ["ReadWriteOnce"]
  {{- if .class }}
  storageClassName: {{ .class }}
  {{- end }}
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .name }}-app
  namespace: {{ .namespace }}
  {{- if .appWave }}
  annotations:
    argocd.argoproj.io/sync-wave: {{ .appWave | quote }}
  {{- end }}
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
        - name: app
          image: registry.access.redhat.com/ubi9/ubi-minimal:latest
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: {{ .name }}
{{- end -}}
