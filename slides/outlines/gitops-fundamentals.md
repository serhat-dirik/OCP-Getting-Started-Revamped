# GitOps Fundamentals

## Slide: The cluster nobody can vouch for

- Claims config lives in Git — base + 3 overlays
- Yet dev and stage get changed by hand
- An `oc apply` here, a console scale there
- Now the cluster ≠ the repo that describes it
- Nobody can say what is actually running

Notes: Open with the pain that makes GitOps land. Parasol's claims service is already configured in Git — a plain Kustomize repo with one base and three environment overlays — yet the running dev and stage environments are still changed by hand. Someone runs oc apply, someone scales a Deployment in the console, someone tweaks a ConfigMap to chase a bug, and now the live cluster no longer matches the repository that is supposed to describe it, and nobody can say for certain what is running or how to get back to a known-good state. This module puts a controller inside the cluster in charge of that gap, so Git becomes the single, honest answer to "what is deployed, and why."
Visual: A "Git repo (base + overlays)" box and a "live cluster" box that have visibly diverged (red mismatch), with a question mark over the cluster.

## Slide: Push versus pull — two ways a change reaches the cluster

- Push: CI holds cluster creds, applies from outside
- Pull: a controller in the cluster reads Git
- Pull keeps Git true continuously, not just at deploy
- No outside system holds a key to prod
- Pull is what "GitOps" means

Notes: Contrast the model attendees already know with the one this module teaches. In the pipeline module a build ran oc apply from inside a PipelineRun — the thing that made the change lived outside the cluster and reached in, holding cluster credentials. That is push delivery. Pull inverts it: a controller runs inside the cluster, watches a Git repository, and pulls the desired state in — nothing outside needs cluster credentials because the cluster reconciles itself. Pull buys three things push cannot: Git stays the source of truth continuously (not just at deploy time), no CI job holds a standing key to production, and every environment converges to what its folder in Git says rather than to whatever the last person to touch it did. OpenShift GitOps — Argo CD — is the controller that implements it.
Visual: Concept diagram gitops-fundamentals-01-push-vs-pull — CI pushing into a namespace (blue) vs a controller in the cluster pulling from Git and reconciling (green).

## Slide: The reconcile loop and the Application

- Desired = a Git path at a revision
- Live = the objects in a namespace
- Controller diffs them, forever
- Reports sync status + health
- Application CR binds one source to one destination

Notes: The controller does one thing forever — compare desired against live and converge them. Desired state is the manifests at a path in a Git repo at a revision (your overlays/dev folder on main); live state is the actual objects in a destination namespace. Reconcile renders the desired manifests, diffs them against live, and reports two facts: sync status (Synced when they match, OutOfSync when they differ) and health (is the app actually up). The object that ties one source to one destination is the Application — a small custom resource that is really just "this Git path, into that namespace, reconciled this way." Attendees create it in the Argo CD web UI, signed in with their OpenShift identity — not with oc apply — because the instance is shared and Argo CD scopes each person to their own project.
Visual: Concept diagram gitops-fundamentals-02-reconcile-loop — Git (desired) → Application → reconcile diff → Synced/Healthy or OutOfSync → Sync back to live.

## Slide: Drift and self-heal — Git wins

- Drift: someone scales the live app by hand
- Argo flags it OutOfSync, shows the exact diff
- Manual sync: you press Sync, it snaps back
- Self-heal: watch-triggered, reverts in seconds
- You cannot out-edit Git

Notes: This is the beat that makes GitOps click. Drift is when the live cluster stops matching Git — someone scales the Deployment from 1 replica to 3 in the console. The moment Argo CD compares desired against live it goes OutOfSync and shows the exact diff: live replicas 3, desired 1. What happens next is a choice on the Application. With manual sync, Argo reports the drift and waits — nothing changes until you press Sync, which reapplies Git and the count snaps back to 1. Turn on self-heal and Argo stops waiting: it watches the resources it manages, so it catches drift the moment it happens and reverts it on its own in a few seconds — measured about four on our cluster — with no human. The periodic reconcile interval is only the ceiling. Either way, you cannot out-edit Git.
Visual: A three-step strip — (1) live scaled to 3, (2) Argo OutOfSync diff 3-vs-1, (3) reverted to 1 — with a small clock showing "~seconds" over the self-heal arrow.

## Slide: Kustomize and Helm — what GitOps reconciles

- GitOps reconciles whatever your repo renders
- Kustomize: base + overlays you own (this repo)
- Helm: a packaged chart with values
- Argo renders either; source points at either
- Same image everywhere — only config moves

Notes: GitOps does not replace how you describe an app — it reconciles whatever your Git repo renders to. The claims-config repo is plain Kustomize: one base that describes a claims environment once (ConfigMap, Secret, database, Deployment, Service, Route) and three overlays that change only what differs — replica count, APP_ENV, log level — while the image stays identical across all three. Point an Application at overlays/dev and Argo reconciles the dev variant; point another at overlays/stage and it reconciles stage, from the same base. Helm is the other common way to render manifests — a packaged chart with a values file — and Argo renders it just as happily; an Application's source can name either. Rule of thumb: Kustomize when you are layering patches over YAML you own, Helm when you are installing a packaged app whose author exposes a values contract.
Visual: One base card feeding three overlay cards (dev 1 / stage 2 / prod 3 replicas), all carrying the same image tag; a small "or Helm chart + values" alternative below the base.

## Slide: What you'll do

- Tour the fork; render the desired state
- Create an Application in the Argo CD UI; sync it
- Drift the live app; watch Git win (Sync, then self-heal)
- Edit Git → the change arrives in stage
- All in your own dev and stage namespaces

Notes: Set expectations for the hands-on, all in your own dev and stage namespaces. First you tour the claims-config fork and render an overlay with oc kustomize so you can see the desired state — seven objects — before a controller applies it. Then you create your first Argo CD Application in the web UI, signed in via OpenShift (an oc apply is refused by design — the instance is shared), and Sync it to deploy the claims app from Git, GitOps-managed. The signature beat: you scale the live app by hand and watch Argo flag it OutOfSync and put it back — first when you press Sync, then, with self-heal on, on its own in seconds. Finally you promote to stage the GitOps way: edit a replica count in Git, and the change arrives in the cluster because Git changed — reviewed as a commit, diffed before it lands, revertible by reverting it.
Visual: Numbered arc strip: tour repo → create + sync app → drift + revert → git-driven change to stage.

## Slide: Map to your org — and when not

- Is your true state a Git commit, or the cluster?
- Your last "someone changed something and forgot"?
- Promotion: a pull request, or a privileged deploy?
- Don't GitOps one-off, imperative work
- Never commit secrets; source them, reconcile the reference

Notes: Land the transfer and stay honest. Discussion prompts: whether the true state of your environments lives in a Git commit or in the cluster and people's memories; the last outage that started with an undocumented change to a running environment, and whether you would want self-heal enforcing Git there; and whether moving a change to production means merging a reviewed commit or a person with cluster credentials running apply. Then the credibility close on restraint: GitOps is for declarative state you want continuously reconciled, so don't put fast, ephemeral, imperative work in it (a one-off migration is a Job, not an Application); don't turn on self-heal where humans legitimately hold the wheel, like a break-glass or actively-debugged environment; and never commit a plaintext secret to make GitOps "complete" — source secrets from a manager and let GitOps reconcile the reference, not the value. Scale (many apps, ApplicationSets, progressive delivery) is the next GitOps module.
Visual: Two-column card "reach for GitOps / reach for a Job or the CLI", with a footnote pointer to the GitOps-at-Scale module and the External Secrets pattern.
