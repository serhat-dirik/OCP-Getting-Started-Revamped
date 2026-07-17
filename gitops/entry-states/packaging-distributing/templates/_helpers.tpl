{{/* The module namespace — the per-user dev namespace this chart materializes INTO but does NOT own
     (the workshop layer creates {user}-dev with quota/limits/RBAC, per-user-namespaces.yaml, exactly
     like build-deliver). {user}-dev is SHARED with the other inner-loop modules → conflictsWith them (ws-meta). */}}
{{- define "packaging-distributing.namespace" -}}{{ .Values.user }}-dev{{- end -}}

{{/* The attendee's Gitea fork URL of the Helm target (route host derived from the cluster ingress
     domain, attendee-safe — the same pattern the verify script + ws use; attendees cannot read the
     gitea Route cross-namespace, rule 10). */}}
{{- define "packaging-distributing.notificationsRepoUrl" -}}https://gitea-{{ .Values.giteaNamespace }}.{{ .Values.clusterDomain }}/{{ .Values.user }}/{{ .Values.forkRepo }}{{- end -}}

{{/* The pullable image reference for the prebuilt notifications istag in {user}-dev — what the
     attendee points their Helm chart's image value at (`helm install --set image.repository=…`). */}}
{{- define "packaging-distributing.imageRef" -}}image-registry.openshift-image-registry.svc:5000/{{ .Values.user }}-dev/{{ .Values.imageName }}:{{ .Values.imageTag }}{{- end -}}
