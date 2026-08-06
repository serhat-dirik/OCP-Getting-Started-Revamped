{{/*
claims.stack — render a full promoted claims environment (ConfigMap + Secret + ephemeral
PostgreSQL + the claims app with probes/resources + Service + Route) into one namespace.
Used ONLY by solve-endstate.yaml to materialize the {user}-stage / {user}-prod end state
that a completed promotion produces — the SAME shape as the kustomize base in
gitops/promotion/claims-config-template/base, kept in lockstep by hand (ADR-0001: compose,
don't chain — duplication between the lab artifact and the solve state is intentional).

Args (dict): ns, replicas, appEnv, logLevel
*/}}
{{- define "claims.stack" -}}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: claims-config
  namespace: {{ .ns }}
  labels:
    app.kubernetes.io/part-of: parasol-claims
    workshop.redhat.com/module: config-multienv
    workshop.redhat.com/owner: ogsr
data:
  POSTGRESQL_HOST: claims-db
  POSTGRESQL_PORT: "5432"
  POSTGRESQL_DATABASE: parasol
  APP_ENV: {{ .appEnv | quote }}
  QUARKUS_LOG_LEVEL: {{ .logLevel | quote }}
---
apiVersion: v1
kind: Secret
metadata:
  name: claims-creds
  namespace: {{ .ns }}
  labels:
    app.kubernetes.io/part-of: parasol-claims
    workshop.redhat.com/module: config-multienv
    workshop.redhat.com/owner: ogsr
type: Opaque
stringData:
  POSTGRESQL_USER: parasol
  POSTGRESQL_PASSWORD: parasol
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: claims-db
  namespace: {{ .ns }}
  labels:
    app: claims-db
    workshop.redhat.com/module: config-multienv
    workshop.redhat.com/owner: ogsr
spec:
  replicas: 1
  selector:
    matchLabels:
      app: claims-db
  template:
    metadata:
      labels:
        app: claims-db
    spec:
      containers:
        - name: postgresql
          image: image-registry.openshift-image-registry.svc:5000/openshift/postgresql:15-el9
          ports:
            - containerPort: 5432
          envFrom:
            - configMapRef:
                name: claims-config
            - secretRef:
                name: claims-creds
          readinessProbe:
            exec:
              command: ["/bin/sh", "-c", "pg_isready -h 127.0.0.1 -p 5432"]
            initialDelaySeconds: 5
            periodSeconds: 10
          volumeMounts:
            - name: data
              mountPath: /var/lib/pgsql/data
      volumes:
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: claims-db
  namespace: {{ .ns }}
  labels:
    app: claims-db
    workshop.redhat.com/module: config-multienv
    workshop.redhat.com/owner: ogsr
spec:
  selector:
    app: claims-db
  ports:
    - name: postgresql
      port: 5432
      targetPort: 5432
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: parasol-claims
  namespace: {{ .ns }}
  labels:
    app: parasol-claims
    workshop.redhat.com/module: config-multienv
    workshop.redhat.com/owner: ogsr
spec:
  replicas: {{ .replicas }}
  selector:
    matchLabels:
      app: parasol-claims
  template:
    metadata:
      labels:
        app: parasol-claims
    spec:
      containers:
        - name: parasol-claims
          image: image-registry.openshift-image-registry.svc:5000/ogsr-parasol-images/parasol-claims:1.0
          # Mutable workshop tag - rebuilt in place, so a node-cached IfNotPresent layer served the OLD image (measured 2026-07-29).
          imagePullPolicy: Always
          ports:
            - containerPort: 8080
          envFrom:
            - configMapRef:
                name: claims-config
            - secretRef:
                name: claims-creds
          startupProbe:
            httpGet:
              path: /q/health/started
              port: 8080
            periodSeconds: 3
            failureThreshold: 30
          readinessProbe:
            httpGet:
              path: /q/health/ready
              port: 8080
            periodSeconds: 10
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /q/health/live
              port: 8080
            periodSeconds: 10
            failureThreshold: 3
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: parasol-claims
  namespace: {{ .ns }}
  labels:
    app: parasol-claims
    workshop.redhat.com/module: config-multienv
    workshop.redhat.com/owner: ogsr
spec:
  selector:
    app: parasol-claims
  ports:
    - name: http
      port: 8080
      targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: parasol-claims
  namespace: {{ .ns }}
  labels:
    app: parasol-claims
    workshop.redhat.com/module: config-multienv
    workshop.redhat.com/owner: ogsr
spec:
  to:
    kind: Service
    name: parasol-claims
  port:
    targetPort: http
  # Browser-facing Routes MUST be edge-terminated. A plain HTTP Route answers curl but the
  # console renders its link as https and browsers HSTS-upgrade it, so an attendee clicking
  # through gets "Application is not available" while the terminal says the app is fine.
  # `Allow` (not `Redirect`) keeps plain-http curl working, which several labs rely on.
  # This helper renders the Route for EVERY environment namespace (dev/stage/prod), which is
  # why it was missed when the standalone entry-state templates were fixed on 2026-07-27 —
  # the stage Route stayed plain and was caught live on-cluster (http 200 / https 503).
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Allow
{{- end -}}
