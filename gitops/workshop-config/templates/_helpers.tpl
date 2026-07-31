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

{{/*
workshop-config.entryDestinationsShared — the SHARED (not per-user) namespaces every entry-state
Application must be allowed to write into, emitted as AppProject destination entries.

Defined once here because TWO AppProjects need the identical list — the per-attendee `entries-{user}`
projects (appproject-entries-per-user.yaml) and the admin/fallback `workshop-entries`
(appproject-workshop-entries.yaml). When the enumerated list drifted from what the charts actually
render, entry states failed at SYNC time with "namespace X is not permitted in project Y", which is
exactly the outage 8490ddf caused. One list, two consumers, no drift.

The list is DERIVED, not remembered. Regenerate it after touching any entry chart, with the one-liner
in gitops/entry-states/README.md ("re-derive the shared AppProject destinations"): render every chart
under gitops/entry-states at solve=false AND solve=true with user=user1, collect every
metadata.namespace, drop the user1- ones, sort -u. Anything new must be added here or the entry state
fails at sync with "namespace X is not permitted in project Y".
(A literal shell one-liner cannot live in this comment: a Go template comment ends at the first
asterisk-slash, and a glob path contains one.)

Why each one is on it (kind list from that same render, 2026-08-01):
  ogsr-gitea           ConfigMap, Job, Role, RoleBinding, ServiceAccount — per-user repo seeding
  ogsr-system          Role, RoleBinding                                 — MaaS model/key handoff
  ogsr-student-gitops  Role, RoleBinding                                 — gitops-at-scale entry +
                                                                           gitops-fundamentals solve
  openshift-lightspeed Role, RoleBinding                                 — MaaS source secret reads
  openshift-pipelines  Role, RoleBinding                                 — trusted-supply-chain
  sonarqube            Role, RoleBinding                                 — app-security-testing
  stackrox             Role, RoleBinding                                 — RHACS reads
*/}}
{{- define "workshop-config.entryDestinationsShared" -}}
{{- range $ns := list "ogsr-gitea" "ogsr-student-gitops" "ogsr-system" "openshift-lightspeed" "openshift-pipelines" "sonarqube" "stackrox" }}
- namespace: {{ $ns | quote }}
  server: https://kubernetes.default.svc
{{- end }}
{{- end -}}
