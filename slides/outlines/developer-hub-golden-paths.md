# Developer Hub & Golden Paths

## Slide: Ten tools before the first line of code

- New engineer, day one, needs a service
- Build, pipeline, GitOps, probes, metrics, tracing
- Each is another tool to learn
- Standards live in a wiki — and drift
- The platform is powerful; nobody finds the on-ramp

Notes: Open with the pain this module resolves. By now the workshop has assembled a real platform — trusted builds, pipelines, supply-chain security, GitOps, progressive delivery. Every one of those is a capability, and every one is another tool, repo layout, and convention a developer must learn before they are productive. The tenth engineer to create a service reverse-engineers how the last nine did it, or copies a repo that was already subtly wrong. Standards that live in a wiki drift: the probe gets forgotten, the base image goes stale. The problem is not the tools; it is the cognitive load and the missing on-ramp. This module is the on-ramp.
Visual: A lone developer facing a wall of nine tool logos/boxes (build, pipeline, registry, GitOps, probes, metrics, tracing, catalog, workspace) with a tangle of arrows; a small "week 1: still plumbing" clock.

## Slide: The catalog — the org's map, not a spreadsheet

- Components: the things you build and run
- APIs: the contracts they provide and consume
- Systems: groups of components that work together
- Groups: the teams that own them
- Sourced from files next to the code

Notes: The first thing a developer portal — Red Hat Developer Hub, Red Hat's build of Backstage — gives you is a software catalog: a live inventory modelled as typed entities. A Component is a service or website; an API is a contract it provides or consumes; a System groups components that work together; a Group is the team that owns them. Because the relationships are typed, the catalog is a map, not a spreadsheet: it renders who owns the claims service, which System it belongs to, which API it provides, who consumes that API. And each entity's source of truth is a small catalog-info.yaml in the service's own repo — described as code, reviewed in pull requests, as current as the last commit. When you onboard someone, you point them at the catalog, not a diagram three reorgs out of date.
Visual: Concept diagram developer-hub-golden-paths-01-catalog-model — System box containing Components + an API, a Group owning them, provides/consumes arrows.

## Slide: The golden path — a paved road, not a cage

- A Software Template: a form plus steps
- Fill a couple of fields, get a service
- Probes, metrics, tracing, trusted image — pre-wired
- Plain, standard code in your own repo
- The right thing is the easy thing

Notes: A catalog tells you what exists; a golden path is how you create something new, correctly, without learning the whole platform first. Concretely it is a Software Template: a form plus steps. The developer names a service, and the template scaffolds a complete, standards-compliant service — source with health, metrics, and tracing already wired; a trusted UBI base image; a build recipe; a catalog entry; a workspace. The phrase that matters is paved road, not cage: a cage forces one way and punishes deviation; a paved road makes the right thing the easy thing while leaving you free to drive off it with a reason. The scaffolded service is plain, editable code in your own repo — you own it the moment it is created. The template gave you a correct starting line and got out of the way.
Visual: Concept diagram developer-hub-golden-paths-02-golden-path-flow — form → template → three outputs (scaffold skeleton, publish to Git, register in catalog) → a new repo + a catalog entry.

## Slide: One button = modules 2 through 10

- Every earlier module's decision, encoded once
- Trusted base image, probes, GitOps-ready layout
- New engineer inherits them, does not re-derive
- Compliance is the default at creation, not an audit
- Improve the template once, every future service gains

Notes: This is why the golden path is the payoff of the whole delivery-and-trust block. Everything you did by hand across the earlier modules — choosing a trusted base image, wiring probes and metrics, describing the app for GitOps, laying out the repo — is a decision the platform team makes once and encodes in the template. The new engineer does not re-derive those decisions; they inherit them. And notice when compliance happens: without a golden path, a service is created some ad-hoc way and audited later — someone finds the missing probe and files a ticket. With one, the service starts already carrying probes, a trusted image, and an owner, so compliance is the default state at creation. Auditing shifts from find-and-fix-the-drift to confirm-the-road-was-used. And the leverage compounds: improve the template once and every service created after inherits it.
Visual: A single glowing "Create" button on the left; on the right, a stack of labelled layers (trusted image, probes, metrics, tracing, catalog entry, build recipe) assembling into one service card — with a small bracket over the accreted platform layers.

## Slide: What you'll do

- Tour the catalog: find claims, its owner, its API
- Scaffold a new service from the golden path
- Inspect the paved road — nothing hand-written
- Build and run it in your namespace
- Watch health and metrics answer, unconfigured

Notes: In the lab you are the new Parasol engineer. First you tour the software catalog and read what it knows about the claims service — owner, System, the API it provides — all from files next to the code. Then you run the New Parasol microservice template: a short form scaffolds a complete Quarkus Java 21 service into your own Git organization, publishes the repo, and registers it in the catalog, where it appears immediately as part of the parasol-insurance System. You inspect the paved road — probes, metrics, tracing, a trusted UBI9 image, a build recipe, a workspace, none of it hand-written — then build its image in-cluster and run it, watching the health and metrics endpoints answer observability you never set up. And you break it on purpose: run the template twice with the same name and read the honest failure.
Visual: A four-step horizontal strip: Catalog → Scaffold → Inspect → Run, each with a small icon; a "break: 409" callout under Scaffold.

## Slide: Map to your org — and when not

- How does a new service get created today?
- Who owns this, and what depends on it?
- Standards enforced by construction, or by audit?
- Do not stand up a portal you will not feed
- A paved road, not a cage; not every workflow

Notes: Land the transfer and stay honest. In your org: how does a new service actually get created, and who has to be in the room — is it scaffolded from a template the platform team owns, or copied from an existing repo and fixed up later? When someone asks who owns a service and what depends on it, is that a query against a live map or an archaeology project? And which of your standards are enforced by construction versus found missing in an audit? Then the credibility close on restraint. Do not stand up a portal you will not feed — a catalog nobody maintains rots into the stale wiki it replaced, now with more to run. Do not let golden paths sprawl into the copy-and-drift problem one level up. Do not turn the paved road into a cage teams route around. And do not platform-engineer every workflow — templatize the common path, leave the genuine one-offs alone. The portal is production software; it earns its cost when cognitive load is the real problem, not before.
Visual: Two-column "reach for it / don't" card; a small footnote strip pointing to the Build, Pipelines, Supply Chain, and GitOps modules whose decisions the golden path encodes.
