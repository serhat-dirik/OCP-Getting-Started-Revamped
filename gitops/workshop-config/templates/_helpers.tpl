{{/*
workshop-config.ownerLabels — the non-invasive delivery owner stamp (Wave 1).

Every workshop-created resource carries workshop.redhat.com/owner: ogsr so that an admin can
enumerate the FULL footprint on a shared cluster — including objects that live in namespaces the
workshop does NOT own (the java-21 ImageStream in `openshift`, cluster-scoped RBAC, Kueue cluster
objects, AppProjects) — with a single selector:

    oc get <kind> -A -l workshop.redhat.com/owner=ogsr

and so that bootstrap/ogsr-uninstall.sh removes exactly our resources and nothing the org owns.
Included from each template's metadata.labels; change the value here once and it moves everywhere.
*/}}
{{- define "workshop-config.ownerLabels" -}}
workshop.redhat.com/owner: ogsr
{{- end -}}
