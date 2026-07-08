# M01 — Platform Orientation & First App

## Slide: The 2 a.m. pet problem

- A named server, patched and prayed over
- It wedges; a human logs in
- Restart by hand, hope it holds
- Every box is unique and mourned
- There has to be a better model

Notes: Open with the pain everyone recognizes. The old way to run the claims portal was a server somebody named and hand-nursed; when it broke at 2 a.m., a person fixed it. That server is a "pet." Set up the contrast the whole module pays off: what if the platform kept the app alive instead of you?
Visual: Split image — a single labeled "pet" server with a pager, versus a herd of identical unnamed boxes.

## Slide: Desired state — the one idea

- You declare what you want
- A control loop enforces it, forever
- Pods run; Deployments own them
- Services give a stable address
- You stop operating Pods by hand

Notes: This is the concept the entire workshop rests on. You do not run Pods directly — you declare desired state on a Deployment ("three replicas of this image"), and the reconcile loop continuously makes actual match desired. Introduce the three objects at consumer depth: Pod (disposable unit), Deployment (desired state), Service (stable front door).
Visual: Reuse concept diagram m01-...-01-desired-state.svg — You → Deployment → ReplicaSet → 3 Pods, Service load-balancing, reconcile loop watching.

## Slide: What OpenShift adds over Kubernetes

- Web console, Topology, developer catalog
- Routes: a real URL, built in
- Secure by default: non-root, random UID
- Build to run to operate, one platform
- Kubernetes is the engine; OpenShift the car

Notes: Kubernetes gives the object model and the reconcile loop. OpenShift adds what an organization needs on day one: the console and catalog, Routes for ingress without a load-balancer ticket, containers hardened automatically (non-root, random high UID, dropped capabilities), and an integrated build-run-operate workflow. Every lab step uses a Kubernetes primitive plus an OpenShift convenience.
Visual: The platform-accretion master diagram m01-...-02-platform-accretion-v1.svg with the M01 layer highlighted in red.

## Slide: Self-healing, live

- Three replicas, three worker nodes
- Kill one Pod on purpose
- ReplicaSet: SuccessfulCreate, in seconds
- Service never stopped serving
- Cattle, not pets

Notes: The signature moment. With three replicas spread across nodes, deleting a Pod is a routine event, not an incident: actual drops below desired, the ReplicaSet emits SuccessfulCreate, a replacement schedules, and the Service keeps routing to survivors the whole time. No human, no page, no downtime. This is desired state defending itself.
Visual: Screen-capture still or GIF m01-...-selfheal — Topology donut losing and regaining a segment.

## Slide: What you'll do

- Tour the unified console and terminal
- Deploy the claims portal from an image
- Scale to three; kill a Pod
- Publish it with a Route
- Ask Lightspeed why Pods restart

Notes: Set expectations for the hands-on. Attendees deploy Parasol's claims portal from a prebuilt image, scale it, watch self-healing, expose it at a URL, read logs and events, do the whole thing again in six oc commands, and finish by asking OpenShift Lightspeed a real operational question. Everything happens in their own project; nobody can affect anyone else.
Visual: Numbered arc strip: console → deploy → scale/heal → Route → logs → Lightspeed.

## Slide: Map to your org — and when not

- Which deploys are self-service vs ticket?
- What dies when a VM dies?
- Name three pets you still nurse
- Don't run a database as a naive Deployment
- A VM is sometimes still right

Notes: Land the transfer to their world and stay honest. Discussion prompts: what is self-service versus ticket-and-wait today; how long to recover a real service if its box vanished; where are your genuine pets. Then the credibility close — self-healing disposable workloads are the default, not always: stateful data, legacy appliances, and licensed VMs have their place, covered in later modules. Choosing is the skill.
Visual: Two-column "cattle by default / pet on purpose" decision card.
