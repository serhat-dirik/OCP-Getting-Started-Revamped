{{- define "devspaces-inner-loop.cheEditorUri" -}}http://{{ .Values.cheDashboardService }}.{{ .Values.cheDashboardNamespace }}.svc:{{ .Values.cheDashboardPort }}/dashboard/api/editors/devfile?che-editor={{ .Values.cheEditorId }}{{- end -}}

{{/*
user-namespace.ownerLabels — SAME shape and SAME value as
gitops/workshop-config/templates/_helpers.tpl's workshop-config.ownerLabels, duplicated here (Helm
charts can't share templates across chart roots) so that bootstrap/ogsr-uninstall.sh and
`oc get <kind> -A -l workshop.redhat.com/owner=ogsr` find objects rendered by THIS chart exactly
the same way they find objects rendered by workshop-config. If that label value is ever changed,
change it in both places in the same commit.
*/}}
{{- define "user-namespace.ownerLabels" -}}
workshop.redhat.com/owner: ogsr
{{- end -}}

{{/*
user-namespace.assertInputs — fail LOUDLY (never render a half/empty object) when `user` or
`suffix` is missing or `suffix` isn't one of the 13 suffixes
gitops/workshop-config/templates/per-user-*.yaml render today (dev/stage/prod/cicd from
per-user-namespaces.yaml, the rest one suffix per per-user-<module>.yaml — keep this list in
lockstep with that catalog). Called with the root context ($) at the top of every resource
template. A silently-empty render here would be worse than an error: the caller (`ws prep`) would
believe the namespace exists.
*/}}
{{- define "user-namespace.assertInputs" -}}
{{- if not .Values.user -}}
{{- fail "user-namespace: --set user=<userN> is required (got empty)" -}}
{{- end -}}
{{- if not .Values.suffixes -}}
{{- fail "user-namespace: --set suffixes=<comma-separated-suffixes> is required (got empty), e.g. --set suffixes=dev,stage,prod. `suffixes` is a SCALAR STRING the chart splits itself — NOT a Helm list parameter: Argo CD's helm.parameters does not expand {a,b,c} list literals the way the helm CLI does, so a list-typed parameter silently renders wrong from Argo (see CLAUDE.md session notes)." -}}
{{- end -}}
{{- $valid := list "dev" "stage" "prod" "cicd" "ai" "batch" "mesh" "modernize" "partner" "gitops" "client" "site-a" "site-b" -}}
{{- range $raw := splitList "," .Values.suffixes -}}
{{- $s := trim $raw -}}
{{- if not (has $s $valid) -}}
{{- fail (printf "user-namespace: unknown suffix %q in suffixes=%q — must be one of: %s" $s $.Values.suffixes (join ", " $valid)) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
user-namespace.quotaSpec — per-suffix ResourceQuota `hard` + LimitRange default/defaultRequest
values, rendered as YAML text so callers do `include "user-namespace.quotaSpec" .Values.suffix |
fromYaml`. This is the faithful re-encoding of the numbers in
gitops/workshop-config/templates/per-user-limits.yaml, per-user-ai.yaml, per-user-batch.yaml,
per-user-mesh.yaml, per-user-modernize.yaml, per-user-partner.yaml,
per-user-gitops-namespace.yaml, and per-user-resilience.yaml — see those files' header comments
for WHY each number is what it is (the sizing rationale is not repeated here to avoid the two
copies drifting in prose while staying identical in value).
`pvc: ""` means "omit persistentvolumeclaims from hard" (gitops and partner namespaces run no
workloads needing PVC quota — matches source, which simply doesn't emit the field for those two).

THE VALUES ARE GATED, NOT TRUSTED. tools/lint/ns-policy-parity-guard.py renders BOTH charts and
compares the effective ResourceQuota.hard / LimitRange default+defaultRequest per namespace, so a
number changed on one side and not the other fails CI. That gate exists because this file was a
DORMANT REVERT for a day: 13ed4ef raised the dev/stage/prod/cicd CPU ceiling in workshop-config and
this copy kept the old 500m/6 (found 2026-08-14). Nothing caught it — the copy renders zero objects
today (see below), so no cluster, no `ws doctor` and no test could have. An earlier version of this
comment claimed the values were "asserted byte-identical by the equivalence script in the
platform-engineer's report": a one-off script in a report is not a gate, and that sentence is what
made the drift look impossible. If you change a number here, change it in workshop-config too — the
guard will tell you which one you forgot.

WHERE THIS CHART IS IN EFFECT: nowhere, yet. Every object rendered from it is gated behind
`manageNamespaces` (default false in all 26 entry-state charts), and gitops/workshop-config still
renders the live per-user namespaces — verified 2026-08-14, all 32 {user}-{dev,stage,prod,cicd}
LimitRanges/ResourceQuotas on-cluster carry tracking-id `workshop-config:/...`. That makes a stale
number here invisible until the manageNamespaces migration flips, which is exactly why it needs a
gate rather than a reviewer.
*/}}
{{- define "user-namespace.quotaSpec" -}}
{{- if or (eq . "dev") (eq . "stage") (eq . "prod") }}
reqCpu: "3"
reqMem: 6Gi
# limCpu 6 -> 8 and limDefaultCpu 500m -> 1500m together, 2026-08-13 (13ed4ef). THEY MOVE AS A PAIR
# and neither works alone — a step ceiling of D costs 3xD in a 3-step pod. Measured effect: the
# app-security-testing capstone went 1414s -> 821s. Do NOT "tidy" these back toward the other
# suffixes' 500m; every Maven/Quarkus/ZAP step declares no CPU limit of its own and inherits this
# default. Rationale in full: gitops/workshop-config/templates/per-user-limits.yaml.
limCpu: "8"
limMem: 12Gi
pvc: "10"
pods: "30"
limDefaultCpu: 1500m
limDefaultMem: 1Gi
limReqCpu: 100m
limReqMem: 256Mi
{{- else if eq . "cicd" }}
reqCpu: "3"
reqMem: 6Gi
# limCpu 6 -> 8 with limDefaultCpu below, 2026-08-13 (13ed4ef) — same paired change as dev/stage/
# prod; see that branch. -cicd is where the pipelines actually run, so this is the branch the
# capstone measurement was taken on.
limCpu: "8"
limMem: 12Gi
pvc: "10"
pods: "30"
# The -cicd namespace runs Tekton image builds (Maven + buildah on a Quarkus app), which need more
# than the 1Gi default or they OOMKill mid-build — see per-user-limits.yaml's header comment.
limDefaultCpu: 1500m
limDefaultMem: 2Gi
limReqCpu: 100m
limReqMem: 256Mi
{{- else if or (eq . "ai") (eq . "batch") (eq . "modernize") }}
reqCpu: "4"
reqMem: 8Gi
limCpu: "8"
limMem: 16Gi
pvc: "5"
pods: "50"
limDefaultCpu: "1"
limDefaultMem: 1Gi
limReqCpu: 100m
limReqMem: 256Mi
{{- else if eq . "mesh" }}
reqCpu: "4"
reqMem: 8Gi
limCpu: "16"
limMem: 16Gi
pvc: "3"
pods: "40"
limDefaultCpu: 500m
limDefaultMem: 512Mi
limReqCpu: 100m
limReqMem: 128Mi
{{- else if eq . "partner" }}
reqCpu: "2"
reqMem: 4Gi
limCpu: "4"
limMem: 8Gi
pvc: ""
pods: "20"
limDefaultCpu: 500m
limDefaultMem: 512Mi
limReqCpu: 50m
limReqMem: 128Mi
{{- else if eq . "gitops" }}
reqCpu: "1"
reqMem: 2Gi
limCpu: "2"
limMem: 4Gi
pvc: ""
pods: "10"
limDefaultCpu: 500m
limDefaultMem: 512Mi
limReqCpu: 50m
limReqMem: 128Mi
{{- else if eq . "client" }}
reqCpu: "2"
reqMem: 4Gi
limCpu: "6"
limMem: 8Gi
pvc: "2"
pods: "20"
limDefaultCpu: 500m
limDefaultMem: 512Mi
limReqCpu: 100m
limReqMem: 128Mi
{{- else if or (eq . "site-a") (eq . "site-b") }}
reqCpu: "4"
reqMem: 8Gi
limCpu: "12"
limMem: 12Gi
pvc: "2"
pods: "30"
limDefaultCpu: 500m
limDefaultMem: 512Mi
limReqCpu: 100m
limReqMem: 128Mi
{{- else }}
{{- fail (printf "user-namespace: quotaSpec has no entry for suffix %q (assertInputs should have caught this first)" .) }}
{{- end }}
{{- end -}}
