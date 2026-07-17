# M07 — Pipelines Fundamentals & Task Libraries

## Slide: The build that lives in someone's shell history

- Parasol ships claims by hand today
- Every engineer builds it slightly differently
- No shared record of how, no gate
- "How do we ship this?" → a stale wiki page
- A pipeline makes it reviewed and repeatable

Notes: Open with the pain everyone recognizes. Parasol's claims service builds and deploys with commands people type by hand — which is fine for one person learning, and a liability for a team. There's no shared, current answer to "how is this service built and tested?"; it lives in shell history and a wiki page that went stale months ago, and nothing gates a broken change on its way out. The module turns that manual sequence into a pipeline — a versioned, repeatable build-test-deploy that any Git push can run — and starts the company task library that keeps every team's pipeline consistent.
Visual: A messy "shell history + stale wiki" box on the left, an arrow to a clean "pipeline in Git" box on the right.

## Slide: Anatomy — Task, Pipeline, PipelineRun

- Task: one reusable unit of work
- Pipeline: an ordered graph of Tasks (the recipe)
- PipelineRun: one execution (recipe meets reality)
- Reusable via params, workspaces, results
- Params in, files shared, facts out

Notes: Give people the vocabulary before anything else. A Task is a single reusable unit — clone, test, build, deploy. A Pipeline is an ordered graph of Tasks; it runs nothing itself, it's the recipe. A PipelineRun is one execution — you hand it parameter values and a workspace and it creates the Pods. What makes a Task reusable instead of a copy-pasted script is three typed connection points: parameters (typed inputs like the Git URL and image tag), workspaces (shared storage, usually a PVC, so one Task hands files to the next), and results (small typed outputs — a computed size, a verdict — that let later steps and humans act on a fact). The claims pipeline is exactly this: five Tasks, one workspace, four params, two results.
Visual: Reuse concept diagram m07-...-01 (top half) — Task → Pipeline → PipelineRun with params-in / workspace / results-out labels.

## Slide: Three reuse layers, wired by the cluster resolver

- Catalog Tasks: shipped, ~40, you never maintain
- Org library: your platform team curates
- App pipeline: the one thing that's yours
- resolver: cluster — reference, don't copy
- ClusterTask is gone (1.17); resolver replaced it

Notes: The best Task is one you didn't write. OpenShift Pipelines organizes reuse into three layers and your app pipeline pulls from all three: shipped catalog Tasks in the openshift-pipelines namespace (git-clone, buildah, openshift-client — you reference, never maintain); a curated organization library your platform team standardizes on, published once into a shared namespace so every team uses the same blessed version; and your app's own pipeline, which composes the other two. The wiring is the cluster resolver — instead of copying a Task's YAML you write a reference ("the Task named X in namespace Y") and Tekton resolves it at run time. Note for the field: the old ClusterTask kind was removed in Pipelines 1.17; the cluster resolver is its supported, better replacement.
Visual: Reuse concept diagram m07-...-01 (full) — three colored layers, each Task dotted to a resolver: cluster arrow into the app pipeline.

## Slide: Why curate a library — the Java 17 vs 21 gap

- OpenShift ships a maven Task — use it, right?
- It's pinned to Java 17, no image parameter
- This app is Java 21 → "release 21 not supported"
- Fix once: curate maven-jdk21 into the library
- Every pipeline references it — that's the leverage

Notes: This is the slide that answers the skeptic — "if OpenShift ships forty Tasks, why maintain our own?" The claims pipeline needs to run Maven, and OpenShift ships a maven Task, so the obvious move is to use it. Except the shipped Task pins its build step to a Java 17 runner image and exposes no parameter to change it — and this app is Java 21, so it fails immediately with "release version 21 not supported." You can't pass a parameter because there's no parameter to pass. The choice is to fork and maintain a patched copy in every Java 21 pipeline, or curate one correct Task once — maven-jdk21 — that every team references by resolver. That single concrete gap is the entire argument for an organization library, and it's the platform team's leverage: fix a Task once, everyone inherits the fix.
Visual: Two Task cards side by side — shipped "maven / openjdk-17 / no image param" (red X on a Java 21 app) vs curated "maven-jdk21 / openjdk-21" (green check).

## Slide: Pipelines-as-Code — the pipeline lives with the code

- .tekton/ file lives in the app's own repo
- A Git push fires the pipeline — no button
- Webhook → PaC controller → PipelineRun
- Versioned, diffed, rolled back like code
- Every push built the same way

Notes: A pipeline someone has to remember to run will drift from the code it builds. Pipelines-as-Code closes that gap: the PipelineRun definition lives in a .tekton/ directory inside the application's own Git repository, and a push fires it. Two pieces make it work, and attendees set up both in the lab — a webhook on the repo that POSTs to the PaC controller on every push, and a Repository custom resource that PaC matches to the incoming webhook by URL. The payoff is that the build is versioned with the app: the .tekton file is reviewed, diffed, and rolled back like any other code, and every push — yours or a teammate's — is built the same way, with no one remembering to press a button. This is the on-ramp everything later attaches to.
Visual: Reuse concept diagram m07-...-02 — push → Gitea webhook → PaC controller → new PipelineRun.

## Slide: Pipelines produce data, not just images

- A Task can publish results (typed facts)
- image-size-report: 391 MB, within 500 MB budget
- Results surface at the run level
- Later steps can branch on them; humans audit
- Next module: sign, attest, scan — same idea

Notes: A pipeline's obvious output is an image, but a Task can also publish results — small, typed facts about what it did. Parasol's curated image-size-report Task inspects the freshly built image, computes its pull size, and checks it against a budget, then publishes three results; the pipeline surfaces two at the run level, so a describe shows image-size-mb 391 and image-within-budget true for the claims image. That's a small idea with large consequences: once a pipeline emits data, later steps can branch on it — fail a build whose image blew its budget, block a deploy on a failed scan — and humans can audit it. The next module builds entirely on this: signing, attestation, and vulnerability gates are all "a Task produced a fact, and a later step enforced it."
Visual: A PipelineRun "Results" panel card: image-size-mb = 391, image-within-budget = true, with a small arrow to "a later step can gate on this."

## Slide: What you'll do

- Run the build-test-deploy pipeline; read its anatomy
- Explore the task library; find the Java 17/21 gap
- Break a test — watch the pipeline refuse the build
- Wire Pipelines-as-Code; push to green
- Read the image-size result the pipeline published

Notes: Set expectations for the hands-on, all in your own {user}-cicd project. You run the seeded build-test-deploy pipeline and read how it's wired — params, workspaces, results, and five Tasks all pulled in by cluster resolver — then explore the two curated Tasks and see, concretely, why the shipped maven Task can't build this app. Then the memorable beat: you flip a one-line toggle in your fork that breaks a business-rule test, run the pipeline, and watch it go red at the test with the build skipped — a failing test stops a bad build. You revert to green, then wire Pipelines-as-Code so a Git push builds, tests, and deploys on its own. Expect the first run to take a while (Maven downloads its world twice); use the wait to explore the library.
Visual: Numbered arc strip: run → explore library → break/fix → push-to-build → read results.

## Slide: Map to your org — and when not

- Where does "how we build this" actually live?
- What's your library's first Task (your Java 17/21 gap)?
- Which test do you wish had gated a past incident?
- Don't pipeline a one-off; don't build one monolith
- Don't treat a CI-namespace deploy as production

Notes: Land the transfer and stay honest. Discussion prompts: where the real build of one of your services lives today — a reviewed pipeline, or a wiki and shell history; what the equivalent of the Java 17/21 gap is on your platform (a required scanner, a company base image, a standard deploy step every team solves differently) — that's your library's first Task; and the one test you wish had gated a past incident, and whether it was actually in the pipeline as a gate. Then the credibility close on restraint: a pipeline earns its keep through repetition, so don't build one for a throwaway; split a pipeline the moment it's hard to read rather than growing a monolith; reuse before you author; and never treat the module's CI-namespace deploy as promotion to production — building a trustworthy image is CI's job, and reconciling it into environments is GitOps' job (next up).
Visual: Two-column card "reach for a pipeline / a terminal is enough", with a footnote pointer to the Supply Chain and GitOps modules.
