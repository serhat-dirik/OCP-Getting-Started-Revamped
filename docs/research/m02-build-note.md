# M02 build note — Ways to Build & Deliver Apps

Date: 2026-07-09 · Author: research-analyst R4 · Spec: 02-MODULE-SPECS §M02
Evidence: live cluster `ocp-ws-revamped` (OCP 4.21.22), queried 2026-07-09, unless a doc URL is given.

## Verified environment facts (build cluster, 2026-07-09)

- Cluster capabilities include **Build**, **ImageRegistry** (Managed, PVC `pvc-image-registry`), **openshift-samples** (Managed, x86_64) — so S2I/BuildConfig + ImageStreams work out of the box (`oc get clusterversion version -o jsonpath=…enabledCapabilities`).
- **S2I builder ImageStreams in `openshift` ns** (`oc get is -n openshift`, tags via `.spec.tags`):
  - `java` — `latest` → `openjdk-17-ubi8` (`registry.redhat.io/ubi8/openjdk-17`); other tags 8, 11, openjdk-8/11-ubi8, openjdk-8/11-el7. No ubi9 / JDK21 java tag in the STOCK stream. **SUPERSEDED (Serhat directive 2026-07-09): the Java paved road is JDK 21 — the workshop ships its own `java-21` builder ImageStream in `openshift` ns** (source `registry.access.redhat.com/ubi9/openjdk-21`, installed by workshop-config, catalog-annotated). All S2I flows use `java-21`; the stock stream's age becomes an instructor governance talking point (ties M15).
  - `java-runtime` — openjdk-11/17-ubi8 (runtime-only image for chained builds).
  - `nodejs` — `latest` → `22-ubi9`; tags 20-/22- across ubi8/9/10 (+minimal).
  - `python` — `latest` → `3.12-ubi8`; tags 3.9/3.11/3.12 on ubi8/9, 3.12-minimal-ubi10.
  - → polyglot moment: notifications in **Node 22 (ubi9)** or **Python 3.12 (ubi8)** — both current.
- **Developer-catalog Templates**: 50 in `openshift` ns (samples operator). PostgreSQL = `postgresql-ephemeral`, `postgresql-persistent` (+ combos `nodejs-postgresql-*`, `django-psql-*`, `rails-pgsql-*`). No Postgres **operator** installed (cloudnative-pg / crunchy available in OperatorHub only).
- **UBI / trusted-content reachability from an in-cluster pod** (probe Job, ubi9/ubi-minimal, `default` ns): `registry.access.redhat.com` → HTTP 200, tls_verify=0 (anonymous UBI pulls OK); `registry.redhat.io` → HTTP 401, tls_verify=0 (reachable, **auth-gated** — global pull secret, present by default). Both certs trusted.
- **Gitea** route `gitea-gitea.apps.cluster-qvkd5.dynamic2.redhatworkshops.io`, edge TLS. Apps wildcard cert = **Let's Encrypt** (`issuer O=Let's Encrypt CN=YR1`, secret `cert-manager-ingress-cert`). Same probe: `curl https://gitea…/` → HTTP 200, tls_verify=0. **⇒ S2I git-clone over HTTPS to Gitea needs NO CA injection / no `-k`.**
- **Pipelines-as-Code available** (M06 territory, spec (c)): Pipelines 1.22.4, TektonConfig `pipelinesAsCode.enable=true`, controller route `pipelines-as-code-controller-openshift-pipelines.apps…` — note only, exercised in M06.
- Per-user namespaces seeded (`user1..user5` today; event target 30): `{user}-dev/-stage/-prod/-cicd`, group `workshop-attendees`. **`user1-dev` is empty** (clean M02 canvas). Quota `workshop-quota`: pods 30, requests 3cpu/6Gi, limits 6cpu/12Gi, 5 PVC; LimitRange `workshop-limits` injects container defaults (**also applies to build pods**).

## ⚠ Spec deltas & build decisions (resolve before content)

1. **PostgreSQL-from-catalog conflict (blocking).** Stock `postgresql-ephemeral`/`-persistent` render a **DeploymentConfig** (banned, §5) and default **`POSTGRESQL_VERSION=10-el8`** (PG 10, EOL). Evidence: `oc get template postgresql-ephemeral -n openshift -o jsonpath='{range .objects[*]}{.kind}{" "}{end}'` → `Secret Service DeploymentConfig`. **Decision:** ship a custom Parasol "PostgreSQL (ephemeral)" catalog Template that renders a **Deployment** on imagestream tag `postgresql:15-el9` (newest trusted tag; stock `latest`→15-el8). Keeps the "deploy from catalog" UX, avoids DC, supported PG. **Cross-module:** M05 opens on an **ephemeral** DB (data-loss lesson) → M02 must deploy **ephemeral**, not persistent.
2. **Source repos not seeded.** Gitea holds only `parasol/ocp-getting-started` (public). Spec entry state assumes `parasol-claims` + `parasol-notifications` sources → **absent**. Build dependency on app-developer / workshop-layer. Recommend source repos **public** (simplest S2I clone); per-user fork privacy only matters for push (M06).
3. **DeploymentConfig capability is enabled** on this cluster (why stock templates render) — must not leak into content; every Parasol workload = Deployment.

## Console-reality checks the builder MUST do live ([CAPTURE-VERIFY])

Unified console — see m01-build-note §console for the perspective/enablement question (already flagged).
1. **+Add → Import from Git**: paste `{gitea_url}/{user}/parasol-claims` → builder selection must be **Java 21 (UBI 9)** (the workshop `java-21` stream; auto-detect may propose the stock older stream — document explicitly selecting java-21); capture the "Git type / builder image / target port 8080" dialog. For a **private** fork, verify the "Source Secret" (basic-auth {user} creds) field — entry-state should pre-seed that secret.
2. **Dockerfile strategy**: Import from Git on a repo with a Containerfile → verify it offers the **Dockerfile** strategy; compare BuildConfig `.spec.strategy` Source vs Docker.
3. **+Add → Container images** (deploy-from-image) and **+Add → Developer Catalog** (Templates / Samples / operator-backed) click-paths.
4. **Build inspection**: BuildConfig → build → logs → ImageStream tag pushed to the internal registry (`image-registry.openshift-image-registry.svc:5000/{user}-dev/…`); capture a real S2I build-log tail.
5. **Catalog hygiene**: catalog also surfaces **banned** samples (`sso75/sso76-*` = RH-SSO, `*-3scale`, Jenkins, fuse7). Steer to Parasol tiles; never reference these (ties M15 governance).

## Content skeleton hints + demo arc

- concept: build spectrum (deploy-image / import-from-Git S2I / Dockerfile / pipeline) decision table; image provenance → UBI & Red Hat trusted content (registry.access anonymous vs registry.redhat.io authenticated — real, shown); runtimes included with the subscription (Quarkus, JWS/Tomcat, UBI language images); **non-root random-UID** rule → numeric USER + group-writable paths (deep-dive M12); catalog as the platform's front door (M15/M10). ≥1 diagram: platform-accretion v2 (build layer).
- lab: import-from-Git S2I the Quarkus **claims** service from Gitea → inspect BuildConfig/build logs/ImageStream → same app via **Dockerfile** strategy, compare objects → **polyglot** import `parasol-notifications` (Node 22 / Python 3.12) → browse catalog → deploy **PostgreSQL (ephemeral, custom Parasol template)** → wire env vars (preview M04). Console|CLI dual-path tabs (§3).
- Story hook (≤3): Parasol's claims service must reach the cluster four different ways; you pick the right on-ramp for each and learn why the platform ships the paved road.
- demo arc `[TIME 5m]` (+ catalog tour + trusted-content talk track): import-from-git → running claims app; Say/Show/Do.
- wrapup: when-not-to-use each build path; map-to-org (who owns your base images? where do they come from today?); go-deeper (M06, M07, M15).
- troubleshooting seeds: build fails cloning a private Gitea repo (missing source secret); build OOM/throttled under LimitRange defaults (raise build resources); `registry.redhat.io` 401 (global pull secret); wrong builder tag picked (use the workshop `java-21` stream — JDK 21 baseline per Serhat directive; the app's pom targets release 21 and fails on older JVMs).

## Verify script sketch (tools/verify/m02.sh)

- Entry: `{user}-dev` exists + no app workloads + `workshop-quota` present; Gitea `{user}/parasol-claims` and `/parasol-notifications` reachable (API 200).
- End: BuildConfig `parasol-claims` Complete; ImageStream tag present; Deployment ready + Route 200; notifications app running; PostgreSQL (ephemeral) Deployment ready + Service answers 5432; **assert zero DeploymentConfig objects** in ns. Use `_lib.sh`.

## Media (DoD)

- Terminal cast: S2I import → build logs → running app (CLI path). Screenshots: +Add Import-from-Git dialog (annotated, builder auto-detected), BuildConfig→build→ImageStream, catalog Databases view (Parasol PostgreSQL tile). Diagram: build-spectrum + platform-accretion v2 (SVG + mermaid). Silent capture (<90s): import-from-git to topology.
