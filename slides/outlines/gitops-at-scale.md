# GitOps at Scale & Progressive Delivery

## Slide: Thirty-six Applications nobody wants to write

- Claims is GitOps-managed — one Application per env
- A dozen services × three envs = 36 Applications
- Every one a near-copy that drifts
- And prod takes new builds all-at-once
- Scale and safety both break here

Notes: Open with the two pains this module fixes. Parasol's claims service is GitOps-managed in dev and stage, but as two hand-made Argo CD Applications. That is fine for one service; count it at real scale — a dozen services, three environments each — and it is thirty-six near-identical Applications a human has to author and keep consistent, and they drift. The second pain is delivery: pushing a new build straight to all of production at 100% bets the whole environment on it working. This module generates the fleet from one object and makes a production deploy safe to automate.
Visual: Left: a wall of near-identical "Application" cards (36) tinted red/drift. Right: one "ApplicationSet" object. A "ship 100% at once?" grenade over a prod box.

## Slide: One ApplicationSet generates the fleet

- Describe the Application once, as a template
- A generator produces the parameters
- One Application per environment, stamped out
- Generators: list, git (folders), cluster, matrix
- Take a position: folders, not branches

Notes: An ApplicationSet removes the toil. You describe the Application once as a template and hand it a generator — a source of truth for "what set of things should exist." A list generator enumerates environments inline; a git generator discovers them from folders; a cluster generator makes one per registered cluster; matrix/merge combine them. Parameters in, Applications out. Take a position on layout: folders, not branches — one main branch with overlays/dev, overlays/stage, overlays/prod side by side, so "what's different about prod" is the difference between folders, not a diff between drifting branches. And environments can differ in kind: dev/stage are plain Deployments, prod is a Rollout — one ApplicationSet still covers all three.
Visual: Concept diagram gitops-at-scale-01-appset — generator (dev/stage/prod) → one template → three generated Applications, prod tinted as a Rollout.

## Slide: Order matters — sync waves and hooks

- Some objects must be ready before others
- Migration: after the DB, before the app
- Sync waves order the apply (0, 1, 2…)
- A Sync hook slots in a one-shot Job
- DB (0) → migration (1) → app (2)

Notes: Applying a folder all at once is usually fine — Kubernetes retries. It is not fine when order matters: a schema migration must run after the database accepts connections and before the app boots against it. Argo CD gives you two tools. Sync waves: an integer annotation groups resources; Argo applies all of wave 0, waits for health, then wave 1, then wave 2. Resource hooks: a Sync hook runs as part of the sync rather than as steady state — the idiomatic way to slot in a one-shot Job. Production uses exactly this: database at wave 0, the migration Job as a Sync hook at wave 1, the app Rollout at wave 2 — so the app is never created against a schema that isn't ready, unattended, every time.
Visual: Concept diagram gitops-at-scale-02-sync-waves — three waves left to right, the middle one (migration Job) styled as a hook.

## Slide: Progressive delivery — earn the traffic

- Don't bet all of prod on one deploy
- Route a small slice to the new version
- Canary: 25% → pause → 50% → analysis → 100%
- Analysis probes real health, gates promotion
- Pod-ratio here; request-% needs a traffic router

Notes: GitOps gets the new manifests into prod; it does not tell you whether the new version is healthy under real conditions. Rolling to all pods at once bets the environment on the answer being yes. Progressive delivery refuses the bet: route a small slice to the new version, watch it, widen only as it proves itself, and revert automatically if it fails. Argo Rollouts is the controller — a drop-in for a Deployment whose strategy describes the shift. The canary steps: 25% to the canary, a pause to bake, 50%, then an automated analysis step probes the canary's real readiness, and only on success does it take 100%. Be honest about the mechanism: traffic splits by pod ratio (1 of 4 pods at 25%), which needs no extra infrastructure; exact request percentages or header routing need a traffic router — a Route plugin or a mesh.
Visual: Concept diagram gitops-at-scale-03-canary-analysis — the canary flow with the analysis diamond forking to pass (100%) and fail (rollback).

## Slide: The bad release that rolls itself back

- Ship a build whose analysis will fail
- Canary reaches 50%, analysis reports Failed
- Rollout aborts — automatically
- Stable version never left production (200 throughout)
- Read the AnalysisRun like an incident

Notes: This is the beat that makes the toil worth it. In the lab you force an analysis failure — a deterministic stand-in for a canary whose real metrics spiked — and ship. The canary reaches the analysis step, the analysis reports Failed, and the Rollout aborts and rolls back to the stable version on its own: no human noticed, decided, and acted under pressure. And production never went down — the stable pods served every request through the entire failed rollout; the route answered 200 the whole time. Then you read the failed AnalysisRun the way you'd read an incident review, except the rollback already happened. That is the whole promise: a production deploy that is safe to automate because a bad one reverts itself before anyone sees it.
Visual: A three-panel strip — canary at 50% (1 red, 2 blue pods) → analysis "FAILED" stamp → prod back to all-blue with a green "200" and a small "auto" clock over the rollback arrow.

## Slide: Canary or blue-green — pick the shape

- Canary: gradual slice, analysis-gated, small extra capacity
- Blue-green: two full copies, instant cutover, manual gate
- Canary limits blast radius, measures mid-rollout
- Blue-green: clean switch after a preview pre-flight
- Mesh / serverless shift traffic other ways (other modules)

Notes: Canary is one progressive-delivery strategy; blue-green is the other, and the same controller serves both. Canary shifts gradually and gates on analysis mid-rollout, costing a small extra slice. Blue-green runs two full versions side by side — blue live behind an active service, green new behind a preview service — and cuts over all at once when you promote, with a manual gate and double capacity for the window. Reach for canary to limit blast radius when you can measure health during the rollout; reach for blue-green for a clean instant switch after a full pre-flight on a preview URL. And Rollouts is only the deployment-controller way to shift traffic — a service mesh shifts by routing rules, serverless by revision tags; both are their own modules. Rule of thumb: Rollouts when delivery is driven by the deployment and gated by metrics.
Visual: Two-column compare card (canary vs blue-green) with the decision-guide rows; a footnote strip pointing to Mesh and Serverless modules.

## Slide: Map to your org — and when not

- Onboarding a service = one line, not N files
- Release risk: from "hope" to "measured"
- Migration ordering: structural, not tribal
- Don't canary changes analysis can't judge
- Blue-green costs double capacity; pod-ratio ≠ exact %

Notes: Land the transfer and stay honest. In your org: how many deployment definitions are quietly drifting because each environment is a hand-maintained copy rather than generated from one source? When a bad release last reached prod, how did you find out, and how much of recovery was a human noticing? Is your "run the migration in the right place" rule structural or a runbook step someone can skip? Then the credibility close on restraint: don't canary a change whose failure is slow or downstream — a short readiness analysis will pass a subtle data bug; gate those on tests and manual promotion. Don't reach for pod-ratio when you need exact or header-based traffic — that needs a traffic router. Don't auto-promote before your analysis has earned trust. And blue-green's clean cutover costs a full second copy — pick the strategy your capacity affords.
Visual: Two-column "reach for it / don't" card, with a small pointer to the Networking, Service Mesh, and Multi-Cluster modules.
