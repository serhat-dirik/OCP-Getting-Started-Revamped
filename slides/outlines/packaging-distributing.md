# Packaging & Distributing Your App (Helm & OLM)

## Slide: "It runs" is not "it ships"

- Everything you deployed this week arrived packaged
- Pipelines, GitOps, the entry states — none was hand-applied YAML
- Your app is next: make it installable, upgradable, rollback-able
- Your product's UX is its install and upgrade, not just runtime
- The choice is a folder of YAML vs a versioned artifact

Notes: Open on the reframe. Everything the attendee used this week — the Pipelines operator that ran their builds, the GitOps operator that reconciled their apps, the Helm-shaped entry states that materialized each module — arrived as packaged software, not hand-applied YAML. This module is the other side of that: turning their application into something a colleague or a customer can install, upgrade, and roll back without reading their mind. The business framing to land: your product's user experience is its install and upgrade, not just its runtime. When Parasol's platform team hands the notifications service to a dozen internal teams, the question isn't "does it run" — it's "how does each team install it, and what happens when you ship version two." A folder of YAML means every team edits it differently and an upgrade is a diff nobody reviews; a versioned chart means one command to install, one to upgrade, one to roll back. Packaging is where operability gets encoded once so every consumer inherits it.
Visual: A split — left: a messy folder of YAML files with a shrug ("which version is in prod?"); right: a single versioned chart artifact with install/upgrade/rollback buttons. Arrow labeled "package it once."

## Slide: The packaging spectrum — ordered by day-2 cost

- Raw manifests → Template → Kustomize → Helm → Operator
- The axis: how much day-2 the package takes off the human
- Down the spectrum: more operability encoded IN the package
- …at the cost of more to author and maintain
- Most apps are happiest in the middle — a Helm chart

Notes: There's no single right way to package an app — there's a spectrum, and the axis that orders it is how much day-2 responsibility the package takes off the human. Raw manifests (oc apply): no templating, no versioned artifact, you own everything. An OpenShift Template (oc process): parameters and a one-shot instantiate, but it doesn't upgrade an existing instance. Kustomize: base plus overlays, declarative and Git-friendly — the shape GitOps loves — but no hooks, no rollback command, no reconcile. Helm: Go-templated manifests driven by values, packaged as a versioned OCI chart, with upgrade/rollback/hooks/tests — real release management, but client-side (Helm acts when you run it, then stops). Operator: a custom resource plus a controller that runs forever, continuously reconciling — the most operability per install, and the highest authoring cost. The move down is a trade: more day-2 behaviour lives in the package, off the human, at the cost of authoring and lifetime complexity. Most applications want the middle — a Helm chart is plenty. This module drives Helm hands-on and reads the operator end.
Visual: Reuse concept diagram packaging-distributing-...-01-spectrum.svg — five stops left to right (manifests → Template → Kustomize → Helm → Operator) on a "day-2 encoded in the package →" axis, Helm highlighted green as the focus, Operator amber as "high cost."

## Slide: A Helm chart = values + templates + a lifecycle

- Chart.yaml (identity), values.yaml (inputs), templates/ (manifests)
- {{ .Values.x }} in a template pulls from values.yaml
- Shape it: your image, port 8080, /health probes, SITE env
- OpenShift move: swap the stock Ingress for an edge Route
- helm template renders it — see exactly what will apply

Notes: Walk the chart anatomy the attendee builds. helm create scaffolds a working chart; four pieces carry the idea. Chart.yaml is identity — name, the chart's own version, and appVersion (the app it ships). values.yaml holds the inputs: every field a consumer might change — image, replicas, ports, probes — with a default, overridable at install with --set or -f. templates/ are Go-templated Kubernetes manifests where {{ .Values.image.repository }} pulls from values. templates/tests/ is a helm test that proves a release works. In the lab they shape the nginx skeleton into the notifications service: the seeded image, service port 8080, liveness/readiness probes on /health, the SITE env the app echoes, and — the OpenShift-specific move — replacing the stock Ingress with an edge Route (insecureEdgeTerminationPolicy Allow) so the landing page loads cleanly in a browser. helm lint catches structural mistakes; helm template renders the chart locally without installing, so what you see is exactly what helm install will apply.
Visual: A chart tree (Chart.yaml, values.yaml, templates/deployment.yaml, route.yaml, tests/) with an arrow from a values.yaml field into a {{ }} placeholder in a template, rendering to a real Deployment+Route.

## Slide: The release lifecycle — install, break, roll back

- helm install → a versioned release (revision 1) + a URL
- helm upgrade --set → revision 2; helm history is an audit
- Break it: a bad probe path + --wait → UPGRADE FAILED
- Old pods keep serving — no outage — the safety net works
- helm rollback → one command back to the last good revision

Notes: This is the module's money beat — make it physical. helm install applies the rendered manifests, records a release as revision 1, runs the post-install hook, and the app is browsable at its Route. A packaged app has a lifecycle: change an input and helm upgrade — scale to two replicas, revision 2 — and helm history makes which config is live a fact, not a memory. Then the deliberate break: ship a bad config the way a real mistake arrives, a probe pointing at /healthz which the app doesn't serve, with --wait so Helm holds the release open until the new pods are healthy. They never are — the probe 404s — so helm upgrade fails loudly with "context deadline exceeded" instead of silently. The key observation: the new pod never becomes ready, so the rolling update stalls and the old pods keep serving {"status":"UP"} — no outage. helm history shows revision 3 failed. Then helm rollback returns to the last good revision in one command (a new revision 4 that copies revision 2, so the failure stays on the record). The bad change was caught by probes, never took traffic, and the undo was one command — that is what "packaged" buys you.
Visual: A revision timeline: 1 install (green) → 2 upgrade (green) → 3 FAILED (red, with a "old pods still serving" callout) → 4 rollback (green). A small "app stayed UP the whole time" banner under revision 3.

## Slide: A chart is a distributable OCI artifact

- helm package → a versioned chart-version.tgz
- Modern Helm speaks OCI — charts live in any OCI registry
- Push to the cluster's internal registry (service-CA + token)
- Integrated registry = <namespace>/<name> (no charts/ subpath)
- helm pull → matching sha256 digest = verified round-trip

Notes: A chart you can install from a directory is useful; a chart you can distribute is a product. helm package bundles the chart into a versioned .tgz. Modern Helm speaks OCI — the same artifact format as container images — so a chart can live in any OCI registry, including the cluster's internal registry. The registry is an in-cluster Service on :5000 with a certificate signed by the cluster's service CA, so you log in with your OpenShift token and trust that CA (--ca-file). One OpenShift-specific reality to teach: the integrated registry maps every OCI repository to an ImageStream — exactly <namespace>/<name> — so a deeper charts/ path is rejected with a 401; you push to oci://<registry>/<your-namespace> and the chart lands as a version tag alongside the app image, distinguished by tag and artifact type. (On a general-purpose registry like Quay or Harbor, the charts/ prefix works.) Then prove the round-trip: helm pull returns the same sha256 digest you pushed, so the artifact in the registry is exactly the chart you packaged — and anyone with pull access can helm install straight from oci://, no chart directory needed.
Visual: A push/pull round-trip loop — local .tgz → helm push → registry <namespace>/parasol-notifications:0.1.0 → helm pull → same sha256 digest highlighted on both ends. A small "charts/ subpath = 401" strike-through note.

## Slide: OLM anatomy — what happens when a customer clicks Install

- Every operator you used this week installed this way
- CatalogSource → PackageManifest (channels) → Subscription
- → InstallPlan (approve) → CSV (owned CRDs + controller + RBAC)
- → operator Pod reconciles your custom resources
- You dissect it live: Pipelines' Subscription, channels, CSV, CRDs

Notes: Cross to the operator end of the spectrum — and ground it in something real. When you installed the Pipelines operator, or any operator, from OperatorHub, a specific chain ran. This is classic OLM, and on this cluster it installed every operator the attendee used all week. A CatalogSource is a catalog index image listing installable operators. A PackageManifest is one operator's entry, exposing its channels — named upgrade streams like latest or a version-pinned line. You create a Subscription naming the package, a channel, and the catalog — "I want this operator, on this stream." OLM resolves it into an InstallPlan, approved automatically or held for a manual click (the gate an admin uses for upgrades). The InstallPlan installs a ClusterServiceVersion, the heart of the bundle: it declares the custom resource definitions the operator owns, the controller Deployment to run, and the RBAC it needs. That Deployment is the operator Pod, which reconciles the custom resources you create. In the lab they read this backwards from the live Pipelines operator — its Subscription (channel latest, source redhat-operators), its channel list, its CSV (14 owned CRDs, a controller, AllNamespaces), the Tekton CRDs it added, and the CatalogSource and InstallPlan behind it. That is what happened when someone clicked Install.
Visual: Reuse concept diagram packaging-distributing-...-02-olm-anatomy.svg — the top-down chain CatalogSource → PackageManifest → Subscription → InstallPlan → CSV → operator Pod, with a side note "OLM v1: ClusterCatalog + ClusterExtension (the direction)."

## Slide: When NOT to write an operator — and choose with a straight face

- OLM v1 is the direction: ClusterCatalog + ClusterExtension (GA, idle here)
- Place your app on the spectrum: most apps want Helm
- Operator earns its cost only when reconcile IS the value
- If helm upgrade covers day-2, you don't need a reconcile loop
- "The notifications service wants Helm" — saying so is the senior move

Notes: Close on the thesis. First the direction of travel: OLM v1 is generally available and running on this cluster — four ClusterCatalogs serving — reshaped into two cluster-scoped objects, a ClusterCatalog (the catalog) and a ClusterExtension (your installed operator, with a ServiceAccount and RBAC you supply). But zero ClusterExtensions are installed and the current console doesn't surface it: classic OLM drives OperatorHub today and is what they dissected; OLM v1 is a five-minute "here's where it's going." Then the decision, made honestly. Having shipped a Helm chart and dissected an operator, the attendee places their own app on the spectrum. The honest rule — the one most teams get wrong: if your day-2 is "occasionally helm upgrade with new values," a chart already does that, and an operator would be a reconcile loop with nothing to reconcile plus a controller to build, certify, and keep alive for the product's life. Write the operator when the reconcile itself is the value — continuous drift repair, stateful upgrade, failover, many instances from one spec. The notifications service they packaged wants Helm, and saying so out loud is the senior move. That judgement — not the ability to write an operator — is the takeaway.
Visual: A decision table (manifests / Kustomize / Helm / Operator) with "reach for it when…" column; Helm row highlighted "most apps"; Operator row flagged "only when reconcile is the value." Footer: "you ship install and upgrade, not just runtime."
