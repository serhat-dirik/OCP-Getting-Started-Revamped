# Ways to Build & Deliver Apps

## Slide: Here is some source code

- The dev team hands you a Git repo
- No image, no Dockerfile anywhere
- It has to run on the platform
- You could hand-write a build
- Or let the platform do it

Notes: Open with the situation the module solves. Parasol's development team hands you the claims service as source code — a Quarkus repo in Git, no container image. In the first module you ran a prebuilt image; now you have to produce one. Set up the question the whole module answers: what is the right way to turn source into a running app, and why does OpenShift offer several?
Visual: A Git repo icon with an arrow to a question mark over an OpenShift cluster — "source in, running app out?"

## Slide: The build spectrum — four on-ramps

- Deploy from image: no build
- Import from Git: Source-to-Image
- Dockerfile / Containerfile: full control
- Pipeline: when build is a workflow
- Match the on-ramp to the app

Notes: There is no single right way, because apps arrive in different shapes. Four on-ramps, from least to most control: deploy a prebuilt image (no build); import from Git and let Source-to-Image build it (no Dockerfile); build from a Dockerfile/Containerfile when you need control of the base image; graduate to a pipeline when the build is really test-scan-sign-deploy. The skill is choosing, not memorizing one path.
Visual: Reuse concept diagram build-deliver-01-build-spectrum.svg — the decision tree from image? / source? / need control? / workflow?

## Slide: Source-to-Image — the paved road

- Your source plus a builder image
- Platform builds the image for you
- No Dockerfile to write or patch
- Works for Java, Node.js, Python
- The right default for most services

Notes: S2I is the fast default. You supply source and pick a language builder image (the workshop's Java 21 builder for the claims service); the platform runs the build inside it and pushes a runnable image. You write zero Dockerfiles for the common case. The same on-ramp handles the polyglot notifications service in Node.js — one workflow, many languages. Reach past S2I only when you have a reason.
Visual: source → [builder image] → image → Deployment → Route, labeled "S2I: you write no Dockerfile."

## Slide: Where your image comes from

- Every container starts from a base image
- UBI: trusted, maintained, redistributable
- registry.access: anonymous UBI pull
- registry.redhat.io: authenticated, credentialed
- Provenance is a security question

Notes: Where a base image comes from is the foundation of everything you ship and the first thing security asks. Red Hat's answer is the Universal Base Image — trusted, patched, freely redistributable — and the language builders are built on it. The two registries prove the point: registry.access hands out UBI anonymously; the fuller registry.redhat.io needs the cluster's pull secret. Starting from trusted content is how you answer "where did this come from?" before an auditor does. Also note: containers run as a random non-root UID, so images use a numeric USER and group-writable paths.
Visual: Two registry boxes — access.redhat.com (open padlock, "200 anonymous") vs registry.redhat.io (closed padlock, "401 needs credentials").

## Slide: The catalog is the front door

- One place: templates, samples, services
- Curated by the platform team
- Deploy a database without a ticket
- Bad defaults are curated out
- Someone chose what you see

Notes: Builder images, templates, and operator-backed services are surfaced in one place — the developer catalog, reached from +Add. It is where a developer answers "what can I deploy here?" without filing a ticket. It is curated: in the lab you deploy PostgreSQL from a Parasol template that exists because the stock templates ship an end-of-life engine on a deprecated workload type. Notice that someone chose the tiles in front of you — catalog governance is a later module.
Visual: A catalog grid with a highlighted "Parasol PostgreSQL (ephemeral)" tile and a greyed-out "deprecated" tile beside it.

## Slide: What you'll do

- Import claims from Git with S2I
- Build the same app from its Containerfile
- Import notifications — Node.js polyglot
- Deploy PostgreSQL from the catalog
- Wire it up; watch the app go live

Notes: Set expectations for the hands-on. Attendees build the claims service two ways (S2I and Dockerfile) and compare the BuildConfigs, import the notifications service in Node.js with the same S2I on-ramp, deploy a PostgreSQL database from the Parasol catalog, and wire the claims service to it — turning a crash-looping Pod into a running, database-backed API. Everything builds from their own Gitea fork, in their own project.
Visual: Numbered arc strip: S2I claims → Dockerfile compare → Node.js notifications → catalog DB → wire and run.

## Slide: Map to your org — and when not

- Count your Dockerfiles; how many needed?
- Where do your base images come from?
- Who curates your paved road?
- Dockerfile only when you need control
- Ephemeral DB is not production

Notes: Land the transfer and stay honest. Prompts: how many Dockerfiles do your teams maintain versus need; can you trace a production image to its base; is there a curated paved road or does every team reinvent it. The credibility close — S2I is the default, but the Dockerfile strategy earns its keep when you must pin a base image; a lone BuildConfig is not a pipeline; and the ephemeral database you deployed is deliberately not production. Choosing the right on-ramp is the skill.
Visual: Two-column decision card — "S2I by default / Dockerfile on purpose" with the trade-offs.
