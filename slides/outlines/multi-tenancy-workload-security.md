# Multi-Tenancy & Workload Security

## Slide: A safe sandbox for a team

- Parasol stands up a payments team
- Three environments: dev, stage, prod
- Teammates + a CI robot need access
- A workload that demands root
- Speed for the team, safety for the cluster

Notes: Open on the concrete situation. Parasol is giving a new payments team its own space — dev, stage, prod — that must be theirs to move fast in and nobody else's to break. The platform team's job is to hand them exactly that: the right people with the right access, workloads that can't quietly run as root, and quota so one team's mistake can't starve the shared cluster. The whole module is how OpenShift makes that sandbox: RBAC for who-can-do-what, ResourceQuota and LimitRange for how-much, and the security defaults that keep a container honest — none of it a separate purchase.
Visual: A "payments team" box (three env sub-boxes + two teammate icons + one workload) sitting inside a larger shared-cluster frame, with a dotted "guardrails" ring between them.

## Slide: Identity becomes authority

- authN: who are you (identity provider)
- authZ: what may you do (RBAC)
- Chain: IdP → user → group → binding → role
- Bind to the GROUP, not the person
- Onboarding = one membership change

Notes: Every request answers two questions in order — authentication (who are you, settled by an identity provider wired into OpenShift's OAuth) and authorization (what may you do, settled by RBAC). The chain from login to permission has four links, and the design lever is the third: bind access to a group, not to individuals, so a new engineer inherits the team's access with one membership change and off-boarding is one removal. This isn't theory — attendees are governed exactly this way in the workshop, and they'll inspect their own group binding later in the lab.
Visual: Reuse concept diagram multi-tenancy-workload-security-...-01-identity-flow.svg — IdP → User → Group (highlighted) → RoleBinding → Role → verbs.

## Slide: The RBAC object model

- Role / ClusterRole: verbs on resources
- RoleBinding: ties role to subjects
- Built-ins: view, edit, admin
- "admin" can't apply quota or grant SCC
- Escalation rule: can't grant what you lack

Notes: RBAC is four object types. A Role (namespaced) or ClusterRole (cluster-wide) lists permissions — verbs on resources — and grants nothing until a RoleBinding ties it to subjects (users, groups, service accounts). Three built-ins cover most needs: view (read, but not Secrets), edit (change workloads and read Secrets), admin (edit plus manage the namespace's RBAC). The honest surprise: admin is scoped — it cannot apply a ResourceQuota or grant an SCC, because RBAC's escalation-prevention rule forbids granting a permission you don't hold. That scoping is exactly what makes a sandbox safe to hand out.
Visual: Three concentric role rings (view ⊂ edit ⊂ admin) with a hard wall labelled "quota + SCC = platform-owned" outside admin.

## Slide: Non-root by default

- restricted-v2 SCC: every workload's default
- UID from the namespace's assigned range
- runAsUser: 0 → rejected at admission
- Fix the image (drop root) — almost always
- OR a scoped SCC grant to one ServiceAccount

Notes: The security beat. On OpenShift you cannot run a container as root just by asking. Pod Security Admission labels namespaces, but the SCC is the real enforcer, and the default — restricted-v2 — drops all capabilities, forbids privilege escalation, and pins the UID to a range assigned to the namespace that never includes 0. A Deployment demanding runAsUser:0 is rejected at admission with a message naming the range. Two honest fixes: fix the image (stop demanding root — almost always right and permanent), or, when a workload genuinely needs a fixed UID, a narrowly scoped SCC grant to one ServiceAccount — never a blanket anyuid.
Visual: Reuse concept diagram multi-tenancy-workload-security-...-02-scc-admission.svg — Pod runAsUser:0 → restricted-v2 gate → rejected / fixed / scoped-grant.

## Slide: Guardrails — quota, limits, workload identity

- ResourceQuota: the namespace's budget
- LimitRange: default requests/limits per Pod
- Requests reserve; limits cap at runtime
- Workloads authenticate as ServiceAccounts
- Bound tokens: short-lived, scoped, revocable

Notes: Two more guardrails, both platform-owned. ResourceQuota is a hard ceiling on a namespace — total CPU/memory requests and limits, object counts; the interplay that trips people is requests (what the scheduler reserves, counted by the quota) versus limits (the runtime cap). LimitRange fills the gap by stamping defaults on any Pod that omits them, so a quota-enforced namespace stays usable. And workloads authenticate as ServiceAccounts — RBAC governs them like users — proving identity not with a permanent token Secret (those are off now) but with a bound token: short-lived, audience-scoped, revoked when the Pod dies. The same least-privilege identity an AI agent uses later.
Visual: A namespace box with a fuel-gauge (quota), a price-tag stamp (LimitRange) on a Pod, and a ServiceAccount badge issuing a short-lived token chip.

## Slide: Tenancy models — how far to split

- Namespace-per-team: cheap, dense, RBAC-isolated
- Virtual clusters / Hosted Control Planes
- Cluster-per-team: total isolation, total cost
- Self-provisioning + project templates: platform levers
- Isolation is a cost multiplier — buy what you must

Notes: Multi-tenancy is a spectrum of blast-radius choices. Namespace-per-team is the default — many teams share a cluster, isolated by RBAC, quota, and NetworkPolicy; cheapest and densest, and what the workshop runs on. Hosted Control Planes give each tenant its own API server on shared worker capacity — stronger isolation without a cluster each. Cluster-per-team is total isolation and total cost, reserved for hard regulatory boundaries. Two cluster-wide levers set how self-service the shared model is — self-provisioning (can users make their own projects?) and the project request template (are new namespaces born with a default-deny NetworkPolicy and a quota?) — both the platform team's to own.
Visual: A horizontal spectrum bar: namespace-per-team → vClusters/HCP → cluster-per-team, with cost and isolation arrows pointing opposite directions.

## Slide: What you'll do

- Scale a root workload — watch it be rejected
- Grant a teammate edit-in-dev, view-in-prod
- Author a deployer Role: deploys, no secrets
- Exceed the quota, read the refusal, fix it
- Inspect how the platform provisioned YOU

Notes: Set expectations for the hands-on, all in the attendee's own payments-team sandbox. You open by scaling a root-demanding Deployment and watching restricted-v2 reject it live, then fix it in one line so it runs non-root. You grant payments-ci edit in dev and view in prod, and audit with who-can. You author a custom deployer Role so payments-ops can ship Deployments but is blind to Secrets — least privilege you wrote. You read the team's quota, blow past it, and fix it, and watch a LimitRange inject defaults. You finish by turning the lens around: inspecting the group binding, platform-observer role, and scoped admin the platform used to provision you.
Visual: Numbered arc strip: reject-root → fix → grant/audit → custom-role → quota exceed/fix → the reveal.

## Slide: Map to your org — and when not

- Is team access a group, or per-person grants?
- Can you answer "who reads prod secrets?"
- Fix the image, or accrete anyuid grants?
- Don't write a Role a built-in already fits
- Don't buy cluster-per-team for density's sake

Notes: Land the transfer and stay honest. Discussion prompts: is your team access expressed as group bindings or a pile of per-person grants nobody prunes; could you produce a filtered "who can read prod Secrets" list for an auditor on demand; and when legacy images that assume root hit your cluster, is the default answer "fix the image" or a sprawl of anyuid grants you can never take back. Then the credibility close on restraint: don't write a custom Role when view/edit/admin fit; don't reach for cluster-per-team when namespace-per-team isolates you fine; don't grant an SCC exception where fixing the image is cheaper; and don't make quota a straitjacket. Governance over-applied is its own failure mode.
Visual: Two-column card "reach for it / a built-in (or namespace) is enough", footnote pointer to the Networking module for the NetworkPolicy half of tenancy.
