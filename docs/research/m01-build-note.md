# M01 build note — Platform Orientation & First App

Date: 2026-07-08 · Author: PM (consolidating R1/R2/R3 research) · Spec: 02-MODULE-SPECS §M01

## Verified environment facts (build cluster, 2026-07-08)

- OCP **4.21.22** (`stable-4.21`); content targets 4.20+. Console URL comes from `{ocp_console_url}`.
- **Web Terminal** operator `fast` v1.16.1 — installed via portfolio (`pp-web-terminal`).
- **OpenShift Lightspeed** operator `stable` v1.1.1, GA. Wired to MaaS via OLSConfig (`type: rhoai_vllm`, url `…/v1`, model `qwen3-14b`, secret `credentials`/`apitoken` in `openshift-lightspeed`) — the `ai-assist` stack + bootstrap secret provide it. **Verify live before writing the Lightspeed exercise**; the module MUST keep the graceful-degradation path (a NOTE + instructor talk track) for clusters without it.
- User-workload monitoring enabled (`pp-monitoring-uwm`) — pod metrics visible in console for the observe step.
- Gitea per-user accounts exist (workshop layer seeding); M01 itself only needs the account to exist (used from M02 on) — mention, don't exercise.

## ⚠ Console-reality checks the builder MUST do live (do not write from memory)

1. **Perspectives**: recent console versions changed the Developer/Administrator perspective model (unified console; dev perspective availability/enablement varies by version and config). Open the 4.21 console as a workshop user and document what is actually there; write the tour accordingly. If the Developer perspective is disabled by default, either enable it cluster-wide via console config (portfolio patch — coordinate with PM) or teach the unified view. This decides the module's click paths.
2. **Deploy-from-image flow**: verify the exact "+Add → Container images" dialog fields on 4.21 (registry path autocomplete, ImageStream option, target port).
3. **Topology view**: verify sidebar actions used in the lab (scale, pod donut, logs/events tabs).
4. **Web terminal**: verify launch time and that `oc` context lands in the user's last project.
5. **Lightspeed**: verify the chat panel entry point + a real answer to "why is my pod restarting?" with the seeded broken pod (temperature of answers varies — screenshot one good run).

## The app: parasol-web

- Image: `image-registry.openshift-image-registry.svc:5000/parasol-images/parasol-web:1.0` (built in-cluster by app-developer; group `workshop-attendees` gets `system:image-puller` on `parasol-images`).
- Container listens on **8080**, non-root, UBI-based, has `/q/health/live|ready` endpoints (Quarkus) — the lab's probe/logs/self-healing steps rely on these.
- Console flow: deploy by image reference; Route via console; scale 1→3; delete a pod → watch reconciliation; logs/events in topology sidebar.
- CLI recap (6 commands): `oc new-app --image=…` (or `oc create deployment`), `oc get pods -w`, `oc scale`, `oc delete pod`, `oc expose`, `oc logs` — builder verifies each output on cluster and captures real output blocks.

## Entry state (already implemented — exemplar chart)

`gitops/entry-states/m01/`: marker ConfigMap in `{user}-dev`; `ws-meta.yaml` purges `{user}-dev` on reset. Namespaces/quota/RBAC come from the workshop layer. `ws start m01 --user userN` → Argo app `entry-m01-userN`.

## Content skeleton (per 04-STYLE-GUIDE §2) + demo arc

- concept: K8s mental model in 10 min (desired state, pods/deploy/svc) → what OpenShift adds (build→run→operate, security defaults, console) → self-healing "cattle" story. ≥1 diagram (master Parasol platform diagram with M01 layer highlighted — first accretion instance). Mine: old Getting Started deck's monolith→microservices→self-healing storyboards (narrative ONLY; all 2020 tech steps banned).
- lab: tour → deploy parasol-web → topology → scale/kill/watch → Route → logs/events → CLI recap (tabs: console|CLI dual-path per style guide) → Lightspeed moment.
- Story hook (≤3 sentences): you've joined Parasol's platform onboarding; first task: get the claims-portal frontend running and prove the platform keeps it alive.
- demo arc `[TIME 12m]`: console tour → deploy → kill pod → Lightspeed wow. Say/Show/Do blocks.
- wrapup: map-to-org prompts (who runs your clusters? what dies when a VM dies today?), when-not-to-use (don't hand-run pets on the platform), go-deeper links.
- instructor: timing measured during build; pre-flight = `ws verify m01 --entry-only` for a sample user + Lightspeed answer sanity; top-5 questions (K8s vs OpenShift, why random UIDs, route vs ingress, what's an operator, is Lightspeed sending my data where?).
- troubleshooting seeds: first-login OAuth delay; route collision (use `{user}-` prefix); image pull denied (puller RoleBinding missing); Lightspeed slow/unavailable (degradation path).

## Verify script (tools/verify/m01.sh)

Entry: ns exists + marker CM + quota present + gitea account answers (API 200). End: deployment parasol-web ready w/ 3 replicas allowed, route answers 200. Use `_lib.sh`.

## Media (DoD)

Screenshots: topology w/ 3 pods (annotated), Lightspeed answer, deploy dialog. Diagram: platform-accretion v1 (SVG + mermaid source). Recording: asciinema cast of the CLI recap; screen capture of kill-pod-self-heal (<90s). Narration script from demo blocks.
