# M15 media manifest — Networking for Dev & DevOps

Media pass shopping list. Filenames follow `04-STYLE-GUIDE §4` (`<slug>-NN-short-desc.ext`).
This module is **CLI-first** — the console is dual-path but not the content — so the mandatory
recording is a **terminal cast** of the demo arc; screenshots are optional enrichment for the
Console tabs. All lab mechanics and every expected-output block were captured on-cluster (OCP 4.21.22,
OVN-Kubernetes, 2026-07-13 as user1); the diagram SVG exports below are already rendered and committed
(2026-07-26, label fix + platform-accretion diagram 2026-07-28) — the mandatory terminal cast and the
optional screenshots remain the deferred media pass. Every
screenshot needs alt text (what it shows + what to notice). Embed points are marked in the `.adoc`
files with a commented `// media-pass:` line — replace with the `image::…` when the asset lands.

## Diagrams (SVG exports; Mermaid source is the standalone `.mmd` linked in the Source column)

| Filename | Source | Notes |
|----------|--------|-------|
| `networking-dev-devops-01-traffic-directions.svg` | concept.adoc Mermaid "two directions of traffic" — `examples/diagrams/networking-dev-devops/01-traffic-directions.mmd` | outside → web = **north-south (expose)**; web → api → db = **east-west (policy)**; the mental-model spine — reused on slide 2 |
| `networking-dev-devops-02-exposure-tree.svg` | concept.adoc Mermaid "exposure decision tree" — `examples/diagrams/networking-dev-devops/02-exposure-tree.mmd` | ClusterIP → NodePort → LoadBalancer (**\<pending\> on bare metal**) → **Route (workhorse)** → Gateway API (strategic); reused on slide 4 |
| `networking-dev-devops-03-platform-accretion.svg` | ✅ RENDERED 2026-07-28 — `examples/diagrams/networking-dev-devops/03-platform-accretion.mmd` | **master accretion diagram**, the M15 layer (the network control plane: exposure + NetworkPolicy + UDN around `{user}-dev` and `{user}-partner`) highlighted on the running Parasol platform |
| `networking-dev-devops-04-what-you-built.svg` | wrapup.adoc Mermaid recap — `examples/diagrams/networking-dev-devops/04-what-you-built.mmd` | app namespace (web→api→db allowed, demo-client **DENIED** to db) + partner namespace (partner-workload on `ovn-udn1`, **native isolation**); green = allowed, red = denied/isolated, blue = ingress |
| `networking-dev-devops-05-network-policy-layers.svg` | concept.adoc Mermaid "the three isolation layers" — `examples/diagrams/networking-dev-devops/05-network-policy-layers.mmd` | NetworkPolicy (per-pod rules you write) → UserDefinedNetwork (native isolation, no policy to write) → Service Mesh (mTLS identity + L7, a later module). Positions this module's two tools against what comes later, so attendees know what they have *not* yet solved |

Shared legend across all four: namespace box, Service/endpoints tag, NetworkPolicy shield, UDN
"own-network" badge, Route/Gateway ingress icon — same palette as M01–M14 (Red Hat-neutral, no
vendor-logo soup). Do **not** print product version numbers on the diagrams (Gateway API/UDN are
described as GA, not by number — matches the attribute policy).

## Recordings

### Terminal cast — flat network → controlled network → UDN reveal (`networking-dev-devops-demo.cast`, ~12 min, MANDATORY)
Asciinema cast of the demo-arc happy path, recorded in the Showroom terminal as `user1` (drive it
straight from the demo-flavor Say/Show/Do blocks in `lab.adoc`):

1. the flat network — `demo-client` opens a TCP connection straight to `claims-db:5432` (OPEN);
2. apply `default-deny` — `parasol-claims` falls to `0/1`, the DB health check logs **DOWN** (hold on this);
3. re-open only DNS + the db-from-api pair — `parasol-claims` returns to `1/1`;
4. the payoff — `parasol-claims` → db **OPEN**, `demo-client` → db **BLOCKED** (this is the signature moment — hold on the two-line side-by-side);
5. the UDN reveal — `{user}-partner` has **no NetworkPolicy**, yet `partner-workload` on `ovn-udn1` (10.20.0.0/16) **cannot** reach the front end.

Step 4 (same database, two pods, two answers) is the module's signature moment; embed near lab.adoc
exercise 4 and the demo arc. Step 5 is the closer. Keep the font large — the reachability probes are
the whole visual. The `timeout 5`/`timeout 6` waits are intentional (a blocked probe *is* the signal);
don't cut them short in the edit.

## Screenshots (optional — Console tabs get visual support; CLI is the source of truth)
> **Media-pass status, 2026-08-01.** The console rows in this module could not be shot: the OpenShift
> console sits behind OpenShift OAuth, the cached capture session in `shot-profile.session.json` had
> expired (a probe came back as a 25 KB PNG of the IdP chooser — conventions §4 exactly), and
> establishing a new one needs a human to type a password, which that lane is barred from doing.
> What the lane did instead: it **staged and proved every cluster state these shots need** on
> `user7` and wrote them into `tools/media/jobs-m14-m19-console.yaml` with the staging scripts
> (`tools/media/stage-m1*.sh`). One login window now runs the whole block. Per-row status below.


| # | Filename | View | Annotate | Embed point |
|---|----------|------|----------|-------------|
| 1 | `networking-dev-devops-01-services-clusterip.png` | 🟡 READY TO SHOOT 2026-08-01 (entry state alone; proved on user7 — exactly three ClusterIP Services, no external address). Console → Networking → Services (project `{user}-dev`), the three tiers all `ClusterIP` | Circle: the `Type = ClusterIP` column + empty external address | lab.adoc ex. 1 Console tab |
| 2 | `networking-dev-devops-02-create-edge-route.png` | ⛔ PARKED 2026-08-01 — needs a human: three PatternFly dropdowns plus a checkbox, no pre-fillable deep link. Console → Networking → Routes → Create Route form (Service `parasol-web`, Secure, Edge, Insecure=Allow) | Circle: TLS termination = Edge, Insecure traffic = Allow | lab.adoc ex. 2 Console tab |
| 3 | `networking-dev-devops-03-networkpolicy-yaml.png` | 🟡 READY TO SHOOT 2026-08-01, **RETARGETED**: the *Create* editor with a manifest pasted-but-not-created only exists while a human types, so the job shoots the created object's own YAML tab, which renders both circled lines. Console → Networking → NetworkPolicies → `default-deny-all` → YAML | Circle: empty `podSelector: {}` + `policyTypes: [Ingress, Egress]` | lab.adoc ex. 3 Console tab |
| 4 | `networking-dev-devops-04-pod-terminal-blocked.png` | ⛔ PARKED 2026-08-01 — the console Terminal is an xterm.js canvas: the harness can neither type into it nor assert on it (no innerText). Prefer the deny-then-allow GIF below. Console → Workloads → Pods → a `demo-client` pod → Terminal, the `</dev/tcp/claims-db/5432>` probe hanging/timing out | Circle: the command timing out (no `OPEN`) vs a `parasol-claims` pod terminal that prints `OPEN` | lab.adoc ex. 4 Console tab |

**Animated gif (PREFERRED for the multi-step default-deny→allow story):**
`networking-dev-devops-05-deny-then-allow.gif` (<30 s, silent) — split-screen or quick cuts:
apply `default-deny` (parasol-claims → `0/1`) → apply the DNS + db allows (parasol-claims → `1/1`) →
the two probes (API `OPEN`, demo-client `BLOCKED`). The "two answers" frame is the payoff; hold it.

`[CAPTURE-VERIFY]` labels to confirm while shooting (the unified console — no perspective
switch); these confirm the Console-tab click-paths written with `[CAPTURE-VERIFY]` in `lab.adoc`
(the CLI tabs are authoritative):

1. **Networking → Services** lists the three ClusterIP Services with type + cluster IP columns (ex. 1).
2. **Networking → Services → `parasol-claims` → Actions → Edit Service (YAML)** exposes `spec.selector` for the break-a-selector step (ex. 1).
3. **Networking → Routes → Create Route** offers *Secure Route* + *TLS termination = Edge* + *Insecure traffic = Allow*, and the created Route shows a clickable *Location* (ex. 2).
4. **Networking → NetworkPolicies → Create NetworkPolicy** offers a *YAML view* (paste-and-create) alongside the form builder (ex. 3, ex. 4).
5. **Workloads → Pods → _pod_ → Terminal** is available for the in-pod reachability probes (ex. 4, ex. 5).

## Narration script
Draft from the demo-flavor Say/Show/Do blocks in `lab.adoc` (`ifdef::demo[]`, the 12-min arc).
Shot list = the Show: lines; narration = the Say: lines. Record alongside the terminal cast in Phase 6.
The one line that must land in the narration: *"same database, same namespace, two different pods,
two different answers — the database now answers only the API."*
