# M03 — Dev Spaces & the Inner Loop

## Slide: Day one, without the laptop marathon

- New hire, first day on claims
- The old way: install JDK, Maven, DB
- Hours to days, and it rots
- What if it were a link?
- Productive today, not next week

Notes: Open with the pain everyone recognizes. Onboarding a developer usually means a checklist of local installs that takes hours to days and drifts out of sync with production. Set up the contrast the module pays off: a correct, running, database-connected environment from a single link. This is the "oh — that's it?" promise the lab delivers.
Visual: Split image — a laptop-setup checklist (JDK, Maven, DB, VPN, creds) versus a single "Open in Dev Spaces" link.

## Slide: Two loops, two clocks

- Inner loop: edit, run, observe — seconds
- Outer loop: commit, pipeline, deploy — minutes
- This module makes the inner loop fast
- The push at the end starts the outer loop
- The platform optimizes each differently

Notes: The core mental model. The inner loop is the seconds-scale edit-run-observe cycle you do dozens of times an hour; the outer loop is the minutes-to-hours build-test-deploy cycle about safety and repeatability. Dev Spaces is about making the inner loop fast without a laptop. The rest of the workshop is the outer loop, and it begins the moment they git push.
Visual: Reuse concept diagram m03-...-01-inner-outer-loop.svg — red inner loop (edit→build→run→observe) handing off via git push to the grey outer loop (pipeline→image→GitOps→prod).

## Slide: Why the IDE belongs in the cluster

- Onboarding: a link, not a checklist
- No more "works on my machine"
- Code and data stay under cluster RBAC
- The environment is reviewed like code
- One perimeter, not a laptop fleet

Notes: Three problems laptops create, each solved by moving the inner loop into the cluster. Onboarding collapses to a click. Toolchain drift disappears because everyone — and the pipeline — uses the same pinned image. Governance gets one perimeter: code and data never leave the cluster onto a laptop that can be lost. Land that these are business costs, not developer conveniences.
Visual: Three-icon row — a clock (onboarding time), two mismatched laptops with a red X (drift), a shield over a namespace box (governance).

## Slide: The devfile — your workspace as code

- One file in the repo defines the workspace
- Components: the containers (JDK 21 + Maven)
- Commands: named tasks, discoverable
- Endpoints: ports the gateway publishes
- Change the toolchain = a pull request

Notes: The devfile (devfile.yaml, schema 2.2.0) is the contract that makes a workspace reproducible for everyone. Introduce its three parts at consumer depth — components (containers), commands (named tasks), endpoints (published ports). The punchline: "upgrade everyone to JDK 21" is a one-line diff the pipeline and every developer inherit together, not a laptop-by-laptop chase. In the lab they edit this file to add a Valkey cache.
Visual: A devfile.yaml snippet with components/commands/endpoints annotated, arrow to a running workspace Pod (tools + cache containers) behind the che-gateway.

## Slide: The workspace talks to real services

- Workspace runs in your-name-devspaces
- Database runs in your-name-dev
- They meet by ordinary service DNS
- Dev mode hot-reloads against the real DB
- Debug port 5005 opens automatically

Notes: The workspace is a first-class citizen of the cluster network. Dev mode runs in the workspace project and reaches the real claims-db in the app project by cross-namespace DNS — exactly how one microservice finds another. Hot reload lands changes in ~2 seconds against real data, and a Java debug port opens automatically so you can step through a live request. This is what "fast inner loop, real services" means.
Visual: Reuse concept diagram m03-...-02-workspace-gateway-services.svg — browser → che-gateway (HTTPS) → tools container (dev mode :8080, debug :5005) → cross-ns DNS → claims-db.

## Slide: What you'll do

- Open the claims service from a link
- Run dev mode against the real database
- Change an endpoint; watch it hot-reload
- Add a Valkey cache to the devfile
- Push, debug, port-forward, and ship a container

Notes: Set expectations for the hands-on. Attendees open a one-click workspace, wire dev mode to the in-cluster database (a deliberate break-and-fix), change a live endpoint with hot reload, extend the devfile with a Valkey sidecar and restart from it, push to their fork, attach a debugger to a running request, and finally reach past the workspace — port-forward the internal database and ship their pushed change as a running Deployment (the bridge to the outer loop). Everything is in their own projects.
Visual: Numbered arc strip: link → dev mode → hot reload → devfile edit → push → debug → port-forward → ship.

## Slide: Map to your org — and when not

- Measure your real onboarding-to-first-PR time
- Count the laptop fleet, and its drift
- Not for air-gapped or local-hardware work
- Heavy native toolchains may still be local
- A workspace is for dev, not production

Notes: Land the transfer to their world and stay honest. Discussion prompts: how long from laptop-handover to first merged PR; what the laptop fleet costs in money and drift; where "works on my machine" still bites. Then the credibility close — in-cluster workspaces are a strong default for server-side work but wrong for air-gapped/offline, local-hardware-dependent, or very heavy native toolchains, and a workspace is a dev environment, not a place to run production.
Visual: Two-column "in-cluster workspace / keep it local" decision card.
