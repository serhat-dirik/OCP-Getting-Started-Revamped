# Config, Secrets & Multi-Environment

## Slide: It worked in staging

- Change passed every check in staging
- Broke in production — again
- The code was fine
- Configuration lived in three places
- And drifted between environments

Notes: Open with the pain every team knows. A change sails through staging and breaks in production, and the culprit is not the code — it is configuration scattered across the image, environment variables, and a file someone edited by hand, drifting between environments no one can fully account for. Set up the promise the module delivers: make configuration a first-class, externalized part of the platform so this class of surprise disappears.
Visual: Split panel — a green "staging: passed" check next to a red "production: 500" alert, with a tangle of config sources (image, env, file) between them.

## Slide: Same image, different config

- Build the image once — never rebuild
- Environment supplies the settings
- Four places: env, ConfigMap, Secret, file
- Promote = apply config, not rebuild
- Ship exactly what you tested

Notes: The core mental model of the whole module. An immutable image carries behavior; the environment supplies settings. Introduce the four config sources in increasing order of handling — inline environment variables, a ConfigMap for non-secret config, a Secret for credentials, and a mounted file for larger config or rotation. The payoff line: promotion becomes applying different configuration to the same bytes, so you ship exactly what you tested.
Visual: Reuse concept diagram config-multienv-...-01-config-sources.svg — one immutable image fed by env / ConfigMap / Secret / mounted file.

## Slide: ConfigMap vs Secret — and an honest word

- ConfigMap: non-secret config, versioned separately
- Secret: credentials, separate access control
- base64 is encoding, NOT encryption
- A Secret buys RBAC + one rotation point
- Real vaults come later (External Secrets)

Notes: Draw the line between the two. A ConfigMap holds non-secret config you can review and change without touching the Deployment. A Secret holds credentials — but be honest: its data is base64-encoded, not encrypted, readable by anyone with the right RBAC. What a Secret actually buys is separate access control (deploy without reading credentials) and a single rotation point. Encryption of the source of truth is what a real secrets manager adds — flagged here, previewed at the end.
Visual: Two cards side by side — ConfigMap (host, port, log level) and Secret (base64 blob with a "decodes in one command" callout).

## Slide: Probes — how the platform knows you're healthy

- Startup: has it finished booting?
- Readiness: can it take traffic now?
- Liveness: is it wedged? restart it
- Readiness failure = removed from endpoints
- No ready pods = Route holds traffic (503)

Notes: Three probes, three different platform reactions. Startup holds the other two off so a slow boot is not mistaken for a failure. Readiness controls whether the pod is in the Service endpoints — fail it and traffic is held, not sent to a broken pod. Liveness restarts a wedged container. The one to internalize is readiness: in the lab they break it and watch the endpoints drain and the Route return 503 — the platform protecting users from a half-broken pod.
Visual: Reuse concept diagram config-multienv-...-02-readiness-gate.svg — a Route routing to a passing pod and NOT to a failing one (503).

## Slide: Requests, limits, and the quota

- Request = reserved; limit = ceiling
- LimitRange fills in sensible defaults
- ResourceQuota caps the namespace total
- Ask for too much → scheduling refused
- Right-size requests; don't fight the room

Notes: Every container declares a request (what the scheduler reserves) and a limit (the ceiling). Two guardrails are already in place: a LimitRange supplies default requests/limits, and a ResourceQuota caps the namespace total. In the lab attendees set explicit values, then deliberately ask for more CPU than the whole namespace allows and read the exact refusal. The instinct to teach: when you hit a quota, right-size your requests — a reservation you do not use starves everyone else's headroom.
Visual: A namespace box with a quota meter (requests.cpu 3 cores), a normal pod fitting and an oversized pod bouncing off with an "exceeded quota" tag.

## Slide: Promotion — one base, three overlays

- One Kustomize base, three overlays
- dev / stage / prod change only config
- Same image digest in every environment
- Replicas + settings differ, bytes don't
- "Tested what we shipped," provably

Notes: Bring it together. With an immutable image and externalized config, promotion is a Kustomize base plus overlays that change only what differs per environment — replica count, APP_ENV, log level. The same image DIGEST lands in all three namespaces, which the lab proves at runtime. That identical digest is what "we tested what we shipped" actually means — not the same tag, the same bytes.
Visual: Reuse concept diagram config-multienv-...-03-promotion-overlays.svg — one base fanning into dev/stage/prod overlays, all carrying the same image digest.

## Slide: What you'll do

- Break the app with a bad setting; read it
- Move config to a ConfigMap, creds to a Secret
- Add probes; watch readiness hold traffic
- Set requests/limits; bust the quota
- Promote the same image to stage and prod

Notes: Set expectations for the hands-on. Attendees break the app with a bad datasource URL and read the CrashLoop, externalize config into a ConfigMap and credentials into a Secret (and try a mounted file), add all three probes and watch a broken readiness gate drain traffic, set resources and deliberately bust the namespace quota, and finally promote the same image to stage and prod with per-environment config. Three deliberate breaks, each a read-then-fix.
Visual: Numbered arc strip: break → ConfigMap → Secret → probes → quota → promote.

## Slide: Map to your org — and when not

- Where does your config actually live?
- Who can read production secrets right now?
- Env-var sprawl is its own mess
- A Secret is not a vault
- Three overlays for two settings = overkill

Notes: Land the transfer and stay honest. Discussion prompts: where configuration really lives for one of your services; who can read the production database password today; how much of your stage-to-prod difference is diffable config versus drift. Then the credibility close — externalization is a strong default but every tool over-applies: dozens of env vars need a file or config service, a Secret is not encryption, and a two-setting app does not need a base and three overlays. Reach for the machinery when the environments and change rate justify it.
Visual: Two-column "externalize / keep it simple" decision card, with a small "base64 ≠ encryption" caution stamp.
