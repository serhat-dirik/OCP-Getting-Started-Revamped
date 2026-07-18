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

{{/*
workshop-config.antoraImage — the in-cluster registry path the cockpit `antora-build` initContainers
pull. Derived from .Values.showroom.namespace (where templates/showroom-antora-build.yaml builds the
antora-ext ImageStream) so the pull path can NEVER drift from the ImageStream's namespace. It drifted
once: the `ogsr-` rename moved the namespace to ogsr-showroom but left a hardcoded
`.../showroom/antora-ext` literal in values.yaml, so every cockpit ImagePullBackOff'd on a fresh
install (C2 lifecycle test, 2026-07-18). Both cockpit templates call this with the ROOT context ($):
`{{ include "workshop-config.antoraImage" $ | quote }}`. showroom-demos.yaml deliberately uses
showroom.namespace (this helper), NOT its own $ns, since the build is owned by the attendee-showroom
namespace even when the demos cockpit is split into a separate namespace.
*/}}
{{- define "workshop-config.antoraImage" -}}
image-registry.openshift-image-registry.svc:5000/{{ .Values.showroom.namespace }}/antora-ext:latest
{{- end -}}
