#!/usr/bin/env bash
# Stage registry-images-catalog-governance ({user}-dev) for the media pass.
#
# Runs the lab's own exercise 2 (promote by digest) and exercise 5 (namespaced Template) so the
# three namespaced shots in jobs-m14-m19-console.yaml have something to photograph. It does NOT
# run `ws start` — the jobs file does that once, in its own first row, because `ws start` PURGES
# {user}-dev and every later row in the module depends on the state this script then adds.
#
# Idempotent: `oc tag` and `oc apply` both re-run cleanly, so a retry with --only does not have to
# re-materialise the entry state.
#
# Verified end to end on the capture cluster as user7, 2026-08-01.
set -euo pipefail
USER_ID="${1:?usage: stage-m18-registry.sh <userN>}"
NS="${USER_ID}-dev"

# Exercise 2 — promote 1.0 to prod BY DIGEST. `oc tag` resolves 1.0 to its sha256 and points prod
# at the same immutable content; both tags must then report the identical digest, which is the
# whole subject of shot 02.
oc tag "${NS}/parasol-claims:1.0" "${NS}/parasol-claims:prod"

# Exercise 5 — the namespaced catalog entry. Kept byte-identical to the lab's heredoc; if the lab's
# manifest changes, re-extract it here rather than letting the two drift.
oc apply -n "$NS" -f - <<'EOF'
apiVersion: template.openshift.io/v1
kind: Template
metadata:
  name: parasol-claims-quickstart
  annotations:
    openshift.io/display-name: "Parasol Claims Quickstart"
    openshift.io/provider-display-name: "Parasol Insurance"
    description: A one-click Parasol claims service (Deployment + Service) for this project's catalog.
    tags: "parasol,claims,quickstart"
    iconClass: "icon-openshift"
message: The Parasol claims quickstart "${APP_NAME}" is deploying in this project.
parameters:
  - name: APP_NAME
    displayName: Application name
    value: claims-quickstart
    required: true
objects:
  - apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: ${APP_NAME}
      labels:
        app: ${APP_NAME}
        app.kubernetes.io/part-of: parasol
    spec:
      replicas: 1
      selector:
        matchLabels:
          app: ${APP_NAME}
      template:
        metadata:
          labels:
            app: ${APP_NAME}
        spec:
          containers:
            - name: claims
              image: image-registry.openshift-image-registry.svc:5000/ogsr-parasol-images/parasol-claims:1.0
              ports:
                - containerPort: 8080
              resources:
                requests: {cpu: 50m, memory: 128Mi}
                limits: {cpu: 200m, memory: 256Mi}
              securityContext:
                runAsNonRoot: true
                allowPrivilegeEscalation: false
                capabilities: {drop: [ALL]}
                seccompProfile: {type: RuntimeDefault}
  - apiVersion: v1
    kind: Service
    metadata:
      name: ${APP_NAME}
      labels:
        app: ${APP_NAME}
    spec:
      selector:
        app: ${APP_NAME}
      ports:
        - {name: http, port: 8080, targetPort: 8080}
EOF

# Prove the two states rather than assuming them: an empty digest or a missing Template means the
# shot would photograph the wrong thing, and that must fail here, not in the browser.
d10=$(oc get istag "parasol-claims:1.0"  -n "$NS" -o jsonpath='{.image.metadata.name}')
dpr=$(oc get istag "parasol-claims:prod" -n "$NS" -o jsonpath='{.image.metadata.name}')
[[ -n "$d10" && "$d10" == "$dpr" ]] || { echo "digests differ or empty: 1.0=$d10 prod=$dpr" >&2; exit 1; }
oc get template parasol-claims-quickstart -n "$NS" >/dev/null

echo "staged $NS: parasol-claims 1.0+prod both at ${d10}, template parasol-claims-quickstart present"
