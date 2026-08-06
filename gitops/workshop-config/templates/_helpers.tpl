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

{{/*
workshop-config.moduleEnabled — is module <slug> part of THIS delivery?

Call: include "workshop-config.moduleEnabled" (dict "root" $ "slug" "observability-health-scale")
Returns the string "true" when the module is enabled and the EMPTY string when it is not, so the
result is directly usable as a template condition:

    if include "workshop-config.moduleEnabled" (dict "root" $ "slug" "...")

(Empty, not the string "false": a Go template treats any non-empty string as true, so a helper that
returned "false" would render a disabled module's resources and read as if it were guarding them.)

WHY THIS EXISTS — SEV1-E, and it is a total-outage class, not a cosmetic one. `modules_disabled` in
vars.yaml is a supported, documented delivery option (bootstrap/vars.example.yaml: "To run a SHORTER
workshop, list the modules you are NOT teaching"), and it does two things — hides the module from the
cockpit, AND skips any platform-portfolio stack that no ENABLED module still needs
(bootstrap/install.sh stack_toggle + the STACKS list). A skipped stack means its NAMESPACE is never
created. Any template here that renders a namespaced resource into such a namespace then produces a
manifest Argo CD cannot apply, and because an Argo Application is all-or-nothing at sync, ONE
un-appliable object fails the ENTIRE workshop-config app: no cockpits, no attendee namespaces, no
Gitea seeding. A documented input produced a broken install.

Measured before the fix (`helm template gitops/workshop-config --set userCount=2
--set modulesDisabledCSV=observability-health-scale`): the tempo-jaegerui-viewer Role and RoleBinding
still rendered into ogsr-observability-workshop, a namespace only the `observability` stack creates
and which that very input tells the installer not to install.

WHY THE MODULE, NOT THE STACK, IS THE PREDICATE. Namespace existence is really decided by stack
selection, but the chart is not given the stack list — the ONE module-shaped input it receives is
modulesDisabledCSV (bootstrap/install.sh and helm/bootstrap/templates/applications.yaml both pass it;
a CSV scalar and not a list because Argo helm.parameters cannot carry a list reliably). Deriving the
answer from that single input is what keeps this honest: the alternative is a second per-template
boolean the installer has to remember to pass, and that is exactly how the sibling half of SEV1-E
happened — sonarqube-user-seed.yaml HAD a `.Values.sonarqube.enabled` guard, and nothing ever set it.

THE ONE INPUT THIS CANNOT SEE, stated plainly so nobody is surprised by it: vars.yaml also accepts an
expert per-stack override (`observability: true`, `appsec: true`, …) that installs a stack no enabled
module requires. In that case the namespace DOES exist while this helper still reports the module
disabled, so the resource is skipped. That direction only ever UNDER-renders — a grant nobody in this
delivery uses is missing — and can never fail a sync. The dangerous direction (namespace absent,
resource rendered) is the one this closes.

The slug is validated against .Values.moduleSlugs — the generated catalog (tools/gen-module-slugs.sh,
regenerated from /modules.yaml) — and a slug that is not in it FAILS THE RENDER. A typo'd slug would
otherwise never match a disabled entry, so the guard would silently pass for every input and look
like it was working: a guard that cannot fire is worse than no guard.
*/}}
{{- define "workshop-config.moduleEnabled" -}}
{{- $slug := .slug -}}
{{- $root := .root -}}
{{- if not (has $slug $root.Values.moduleSlugs) -}}
{{- fail (printf "workshop-config.moduleEnabled: %q is not a module slug in .Values.moduleSlugs — fix the caller, or regenerate the list with tools/gen-module-slugs.sh after editing modules.yaml" $slug) -}}
{{- end -}}
{{- $disabled := list -}}
{{- range $s := splitList "," (default "" $root.Values.modulesDisabledCSV) -}}
{{- if trim $s -}}{{- $disabled = append $disabled (trim $s) -}}{{- end -}}
{{- end -}}
{{- if not (has $slug $disabled) -}}true{{- end -}}
{{- end -}}
