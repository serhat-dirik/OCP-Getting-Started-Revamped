{{/*
hra.labels — the module + owner labels every object in this chart carries. The owner label is the
SAME value gitops/workshop-config uses, so bootstrap/ogsr-uninstall.sh and
`oc get <kind> -l workshop.redhat.com/owner=ogsr` find these objects too.
*/}}
{{- define "hra.labels" -}}
workshop.redhat.com/module: health-resources-autoscaling
workshop.redhat.com/owner: ogsr
{{- end -}}
