# M03 build note — Dev Spaces & the Inner Loop

Date: 2026-07-09 · Author: research-analyst R4 · Spec: 02-MODULE-SPECS §M03
Evidence: live cluster `ocp-ws-revamped` (OCP 4.21.22), queried 2026-07-09, unless a doc URL is given.

## Verified environment facts (build cluster, 2026-07-09)

- **Dev Spaces installed & Active.** CheCluster `devspaces/openshift-devspaces`, `status.cheVersion=3.29.0`, phase Active. Route `devspaces.apps.cluster-example.sandbox.example.com` (edge). **⚠ versions.yaml delta:** file had CSV `devspacesoperator.v3.28.2`/3.28.2; **live CSV = `devspacesoperator.v3.29.0` (replaces 3.28.2, Succeeded)** — auto-upgraded via `stable` channel after the 2026-07-08 verify. Content targets **3.29** (`{devspaces_version}`). versions.yaml devspaces block updated 2026-07-09.
- **Workspace governance (CheCluster `.spec.devEnvironments`):** `maxNumberOfRunningWorkspacesPerUser=2` (matches spec), storage `pvcStrategy=per-user`, `startTimeoutSeconds=300`, `secondsOfInactivityBeforeIdling=1800` (30-min idle). Default editor = **che-code** (VS Code in browser); default namespace template **`<username>-devspaces`**.
- **Authoritative images (CSV `.spec.relatedImages`):** UDI = `registry.redhat.io/devspaces/udi-rhel9@sha256:84c9b0e6ab68…` (tag `:3.29`); editor che-code = `registry.redhat.io/devspaces/code-rhel9@sha256:c9761d88…`. UDI ships Java 17/21 + Maven → **no custom image needed** for the Quarkus workspace.
- **devfile schema = 2.2.0** (confirmed on `parasol-insurance/devfile.yaml`; DWO engine supports 2.1/2.2). Minimal Quarkus devfile: one `container` component on the UDI, a `quarkus:dev` `exec` command, an endpoint on 8080. NOTE: OldContent `parasol-insurance/devfile.yaml` is a **stub** inheriting an RHDH `parent:` at `{{ gitlab_host }}/rhdh/devfiles/…` — do NOT port that parent; author a self-contained devfile.
- **Cross-namespace connectivity (spec d):** workspace runs in `<user>-devspaces`; claims app+DB in `<user>-dev`. No user-namespace default-deny NetworkPolicy exists (all default-deny NPs sit in `openshift-*` control-plane ns). ⇒ dev-mode Quarkus reaches the DB at **`postgresql.<user>-dev.svc.cluster.local:5432`** today. Service CIDR 172.231.0.0/16; DNS verified from a probe pod. (M13 adds netpol → forward-ref an allow rule.)
- **Java debug (spec e):** Quarkus dev mode listens on **5005**, no suspend, by default — docs: quarkus.io/guides/maven-tooling. The che-code Java extension attaches to `localhost:5005` inside the workspace container (internal; no endpoint needed).
- **Virt/KubeVirt NOT installed (spec f):** `hyperconverged` CRD absent (only OperatorHub packagemanifests). Infra platform reports `BareMetal` but nodes are VMs (10.10.10.x) with no virtualization stack. ⇒ **Android device-VM showcase = recorded-video/instructor demo by default.**
- **Image Puller NOT deployed (spec g):** `kubernetesimagepuller` CRD absent; CheCluster `imagePuller.enable` unset → no prewarm; cold start pulls UDI+editor per node.
- Current cohort = 5 users (user1-5); event target 30.

## Spec deltas & build decisions

1. **Dev Spaces 3.29 delta** — see facts; update slides/attributes; docs.redhat.com doc-set currently indexes only up to **3.26** (WebSearch 2026-07-09) — cite nearest-published doc-set until 3.29 docs land.
2. **Namespace split.** Default `<username>-devspaces` ≠ app ns `<username>-dev`. **Decision:** keep the default and use cross-namespace DNS `postgresql.{user}-dev.svc:5432` for dev-mode (least surprise, preserves isolation). Alternative (`defaultNamespace.template=<username>-dev` to co-locate) simplifies connectivity but mixes quota/RBAC — not recommended.
3. **Private-fork git credentials.** Starting from a **private** per-user Gitea fork needs per-user git creds in `<user>-devspaces` (secret labelled `controller.devfile.io/git-credential=true`, or dashboard User Preferences → Git). Entry state seeds it, OR make source repos public (creds only for push). Same repo-visibility call as M02.
4. **Prewarm for ×30.** No Image Puller + per-user PVC storage ⇒ 30 cold starts hammer image pull + PVC provisioning. **Decision:** set CheCluster `spec.imagePuller.enable=true` in the portfolio devspaces stack, pre-pulling `udi-rhel9:3.29` + `code-rhel9` (adapt the android repo's `quickstart-cache.sh` idea).

## Console-reality checks the builder MUST do live ([CAPTURE-VERIFY])

1. **Factory start from Gitea:** open `{devspaces_url}/#{gitea_url}/{user}/parasol-claims` → verify provision, editor load, project cloned. Capture the `#<git-url>` factory URL + the topology "Open in Dev Spaces" deep-link (the one-click moment).
2. **Dev-mode hot reload** vs in-cluster DB: run `./mvnw quarkus:dev` → edit a claims endpoint → live reload → hit it; confirm it talks to `postgresql.{user}-dev.svc`.
3. **Devfile authoring:** add a command + sidecar component (e.g. Redis), restart workspace from the devfile; verify the new container + endpoint appear (Endpoints panel).
4. **Debug:** breakpoint on a claims endpoint; attach che-code debugger to 5005; step. Screenshot the browser-IDE debug session.
5. **Governance:** max-2 workspaces enforced; idle→stop after 1800s; per-user PVC.

## Content skeleton hints + demo arc

- concept: inner vs outer loop; why IDE-in-cluster (onboarding, "works on my machine", governance); **devfile as the workspace contract in Git** (schemaVersion 2.2.0; container/commands/endpoints/events). ≥1 diagram: workspace ↔ che-gateway(HTTPS) ↔ in-cluster services; platform-accretion v3.
- lab: open `parasol-claims` from a Gitea link → tour workspace → dev-mode change w/ hot reload hitting `{user}-dev` PostgreSQL → add devfile command + component (Redis sidecar); restart from devfile → commit; push (sets up M06) → debug breakpoint → **[SHOWCASE]** Android in Dev Spaces (recorded demo — KubeVirt absent) → [take-home] Podman Desktop / OpenShift Local.
- Story hook (≤3): a new Parasol dev must be productive on day one without a laptop-setup marathon; you open the claims service in a browser IDE that already talks to the cluster.
- demo arc `[TIME 8m]`: topology → one-click IDE → dev-mode live change; Android showcase video as closer. Say/Show/Do.
- wrapup: when-not-to-use (air-gapped dev, heavy native toolchains); map-to-org (how long is laptop onboarding today?); go-deeper (M06 PaC, M10 golden paths).
- troubleshooting seeds: slow first start (enable Image Puller); blank web-preview behind the HTTPS gateway (bind 0.0.0.0, avoid localhost websockets — see mining); private-clone auth (git-credential secret); max-2 reached; debugger won't attach (wrong launch config / 5005).

## Mining — serhat-dirik/devspaces-android-sample-app (D18, credit required; no LICENSE file in repo)

Port **patterns, not the Android tech** into the devfile-authoring lesson + recorded showcase:
- **Multi-target devfile** (`devfile.yaml` vs `devfile-quay.yaml` = registry.redhat.io vs quay variants of the workspace image).
- **Burstable sizing with a teaching comment** (memoryRequest 4Gi/limit 14Gi, cpuRequest 1/limit 6) — reuse the requests-vs-limits packing explanation (ties M04/M14).
- **Declarative tasks** with `group{kind,isDefault}` (run/build/test) + "Run Task…" pattern (no Run button); **`events.postStart`** (pub-get).
- **endpoints** (public/https via che-gateway) + the **bind-0.0.0.0 / dwds-over-HTTPS gotcha** (a strong Dev Spaces watchout the raw devfile comments explain).
- **Manual device lifecycle + RBAC lesson:** lifecycle runs as the workspace SA which has **no VM rights** (dev gets `edit`, SA gets nothing); workspace delete GCs the device via ownerRef — a governance teaching point.
- **Preflight `check-prereqs.sh`** + **`quickstart-cache.sh`** prewarm — adapt for the §prewarm decision. Credit `serhat-dirik/devspaces-android` + `-sample-app` in wrapup + CREDITS + instructor.adoc.

## Verify script sketch (tools/verify/m03.sh)

- Entry: CheCluster Active; `{user}-dev` has claims app + PostgreSQL (M02 end state); Gitea repo reachable; git-credential secret present if forks are private.
- End: a running DevWorkspace for `{user}` (≤2); workspace pod resolves/reaches `postgresql.{user}-dev.svc:5432`; devfile in repo carries the added command/component; showcase = manual/instructor (not asserted). Use `_lib.sh`.

## Media (DoD)

- Silent screen capture (<90s): topology → one-click IDE → dev-mode live change. Screenshots: workspace w/ Endpoints panel, debug session on 5005, devfile edit→restart. **Recorded narrated video: Android-in-Dev-Spaces showcase** (the closer). Diagram: inner-loop + workspace/gateway/services (SVG + mermaid).
