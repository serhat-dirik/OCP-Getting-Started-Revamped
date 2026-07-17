# Serverless Zero-to-Hero

## Slide: One idle service shouldn't cost you all night

- Parasol's claims-processor: busy at 9am, idle at 3am
- A normal Deployment holds its pods (CPU + memory) 24/7 — busy or not
- ...and still has to be sized for the morning spike
- Serverless: scale TO ZERO when idle, BURST on traffic
- Pay for requests, not for reserved idle capacity

Notes: Open on the economics, because that's the pitch. Parasol's claims-processor is hammered during business hours and quiet overnight. A normal Kubernetes Deployment is always on — you pick a replica count and those pods sit there holding their CPU and memory reservation against the cluster's quota, whether they're serving thousands of requests a second or none at all. For a steady, always-busy service that's exactly right; for a bursty or partly-idle one it means paying for capacity you aren't using most of the day, while still sizing the Deployment for the busiest minute. Serverless answers with request-driven compute: the platform runs your service only when there's work. No requests, zero pods, zero cost. A request arrives, a pod starts and serves it. Load climbs, pods are added; load falls, pods are removed, back to zero. You still ship a normal container with health probes — the platform just owns the scaling decision, driven by traffic, all the way down to nothing.
Visual: A 24-hour load curve (spiky daytime, flat-zero overnight) with two overlays: a flat "Deployment: reserved capacity" band across the whole day, vs a "Serverless: pods track the curve, zero at night" shaded region — the gap between them labelled "what you stop paying for."

## Slide: A Knative Service is not a Deployment

- You create ONE object: a Knative Service (ksvc), serving.knative.dev/v1
- Knative builds the rest: Deployment + autoscaler, Service, Route, Configuration, Revision
- The Route is AUTO-CREATED (edge, via Kourier) → ksvc.status.url
- NEVER `oc create route edge` for a ksvc (it fights the operator)
- A running pod carries your app + a queue-proxy sidecar

Notes: On OpenShift Serverless you don't assemble a Deployment, a Service, and a Route. You create one object — a Knative Service, a ksvc — and Knative materializes the rest: a Deployment fronted by the Pod Autoscaler (so pods scale on traffic, including to zero), a Kubernetes Service for in-cluster addressing, an edge-terminated OpenShift Route backed by the Kourier ingress, and a Configuration plus a Revision that snapshot this version. The single most important consequence for this workshop: Knative creates the Route for you. Other modules teach you to publish a browser-facing app with `oc create route edge` — for a ksvc that's wrong. The operator auto-creates the edge Route in a namespace you don't manage and hands you the URL on the service as status.url. Hand-rolling a Route for a ksvc fights the operator. Throughout the module the address is whatever `oc get ksvc -o jsonpath={.status.url}` returns. And when a pod is running it's 2/2 — your app container plus a queue-proxy sidecar Knative injects to meter concurrency and buffer during scale-up.
Visual: One "ksvc" card at the top fanning out to five boxes Knative creates (Deployment+KPA, Service, Route, Configuration, Revision), with the Route box flagged "auto-created (edge/Kourier) → status.url" and a red strike-through on a "oc create route edge" attempt.

## Slide: The revision model — rollout and rollback are cheap

- Every template change mints a new IMMUTABLE Revision; old ones stay
- Configuration = the latest desired version (editing the ksvc mints the next revision)
- Route = where traffic goes — by weight, over NAMED revisions, with tags
- Rollback isn't a redeploy: it's re-pointing a Route weight at a revision that already exists
- Same idea powers the traffic split later

Notes: Every time you change a ksvc's template — a new image, a new env var, a tuned concurrency setting — Knative stamps out a new, immutable Revision and leaves the old ones in place. Two objects sit above the revisions. The Configuration is the latest desired version; editing the ksvc updates it, which mints the next revision. The Route is where traffic goes; by default it sends 100% to the latest revision, but you can point it at named revisions with weights and tags. Because a revision is a frozen, addressable version, rolling back is not a redeploy — it's re-pointing the Route's weight at an older revision that's already there. In the lab you'll see exactly this: tune concurrency (which mints revision v2), then split traffic 80/20 across v1 and v2, then roll back to 100% stable in one line — the candidate revision stays put, ready to re-weight. Rollout and rollback as a Route weight.
Visual: Reuse the concept diagram serverless-zero-to-hero-...-01-request-driven-compute.svg — the Configuration minting revisions, the Route splitting weight over v1 (#stable) and v2 (#candidate), the KPA scaling each 0..N.

## Slide: The autoscaler — concurrency, scale-to-zero, and the honest cold start

- KPA scales on CONCURRENCY (in-flight requests); HPA scales on CPU
- KPA can scale to ZERO; HPA floors at one pod
- Knobs: target (soft) / containerConcurrency (hard); min-scale / max-scale
- Cold start is REAL: measured ~15s (JVM) from zero; ~0.1s warm
- Plan for it: min-scale for a warm floor, or a native build (tens of ms)

Notes: A normal Deployment scales with the Horizontal Pod Autoscaler, which reacts to CPU or memory. Knative's default Knative Pod Autoscaler scales on concurrency — how many requests are in flight at once — and, crucially, it can scale to zero. The dial is target concurrency: how many simultaneous requests should one pod handle before adding another. A soft target is the KPA's goal; a hard containerConcurrency is a ceiling the pod won't exceed. Scale bounds cap the range: min-scale defaults to 0 (that's where scale-to-zero comes from), max-scale is the ceiling so one bursting tenant can't exhaust the cluster. The catch is the cold start. When a request hits a scaled-to-zero service, the activator buffers it while a pod starts, then forwards it — that first request pays the full startup cost. On this cluster the JVM claims-processor's first request from zero took about 15 seconds; every warm request after, about a tenth of a second. That's not a bug, it's the honest cost of trading idle capacity for scale-to-zero — and you plan around it: set min-scale 1 for a latency-sensitive path (giving up scale-to-zero for a warm floor), or use a natively-compiled build that starts in tens of milliseconds. The lab has attendees measure the cold start themselves, so the tradeoff is a number they've seen, not a slogan.
Visual: A timeline of one request hitting a zero-pod service: activator buffers → pod schedules → JVM boots → response, annotated "~15s cold" — beside a second, warm request annotated "~0.1s"; a callout "min-scale: 1 removes the cold start (gives up scale-to-zero)."

## Slide: Shift traffic by revision — the third way

- Tag v1 `stable` at 80%, v2 `candidate` at 20% — one object change on the Route
- Each tag also gets its OWN sub-route (stable-… / candidate-…) to hit a revision directly
- Rollback = send 100% back to stable, in one line (candidate stays, ready to re-weight)
- Third traffic-shift tool: Argo Rollouts (GitOps at Scale), service mesh (Service Mesh), Knative revisions (here)
- Reach for Knative's when the workload is already a ksvc

Notes: Because revisions are addressable and the Route carries weights, shifting traffic between two versions is a one-object change: tag revision v1 stable at 80% and v2 candidate at 20%, and Knative also gives each tag its own sub-route so you can hit either version directly. This is the third traffic-shifting tool the workshop has shown, and they're worth holding apart. Argo Rollouts shifts by Deployment strategy with metric-gated steps — best for progressive delivery with automated analysis and rollback. The service mesh shifts by sidecar routing rules — best for identity, resilience, and L7 policy across many services. Knative shifts the ksvc's own Route over immutable revisions — best when the workload is already a ksvc, because the old revision is right there, so "roll back 20% to stable" is a weight change, not a deploy. None replaces the others; they operate at different layers. In the lab attendees split 80/20, hit each tagged sub-route directly (both 200), prove the main URL wakes both revision Deployments, then roll back to 100% stable in one line.
Visual: The ksvc Route fanning to a fat 80% arrow (v1 #stable) and a thin 20% arrow (v2 #candidate), each tag with its own sub-route chip; a small "rollback: stable=100 (one line)" callout; a footnote comparing GitOps at Scale Rollouts / Service Mesh mesh / here.

## Slide: A taste of eventing — source → broker → trigger

- Request-driven so far; eventing adds EVENT-driven delivery
- Source (PingSource) → Broker (in-memory) → Trigger → ksvc sink
- The event WAKES the service from zero to receive it
- Honest boundary: the delivery returns 404 — the app has no CloudEvents handler yet
- Wiring + scale-up are REAL; processing the event is Eventing

Notes: Everything so far has been request-driven: a client calls the service. Knative Eventing adds the other half — event-driven delivery, where something happens and the service is invoked without a caller waiting on it. Three primitives: a Source emits events — you'll use a PingSource that emits on a schedule; a Broker is an event hub that receives and fans out, and the default is in-memory, needing no external messaging system; a Trigger is a subscription that routes broker events to a sink — here the claims-processor ksvc, which scales up from zero to receive them. Now the honest part, and it's the whole framing: you wire source to broker to trigger to service and the delivery genuinely happens — the trigger POSTs each event to the ksvc, which wakes from zero. But you'll also see an honest HTTP 404, because the claims-processor has no CloudEvents handler yet — the event lands on a path the app doesn't serve. That is the correct teaching boundary: the wiring and the scale-up on an event are real; processing the event — parsing the CloudEvent, branching on its data, replying — is the deep story, and it belongs to the Eventing Deep-Dive and Serverless Workflows module that follows, which starts from exactly this end state. Don't read the 404 as a failure; read it as "the plumbing works, the business logic is the next module."
Visual: PingSource → Broker (in-memory) → Trigger → ksvc, with a lightning bolt on the ksvc "wakes from zero" and a callout on the delivery edge "HTTP 404 — no handler yet → Eventing"; the whole panel tinted as a "taste" with a forward-pointer to the eventing module.

## Slide: Serverless vs Deployment — the honest decision

- Lean serverless: bursty / idle sometimes / request- or event-driven / cold-start-tolerant
- Lean Deployment: steady & always-busy / latency-critical no-warm-floor / long-running or stateful
- Rollout: Route-weight canary+rollback (ksvc) vs rolling update / Argo Rollouts
- Functions (kn func): a ksvc from a code template — concept + instructor demo here (build path)
- Map to org: which services sit idle, and what do the always-on pods cost?

Notes: Close on the decision and the transfer, because the honest answer is "it depends" and here's the checklist. Lean serverless when a service is bursty or spiky, idle a meaningful fraction of the time, request- or event-driven, and tolerant of an occasional cold start (or cheap enough to keep one warm) — that's when scale-to-zero and pay-for-use earn their keep. Lean Deployment when a service is steadily busy (a plain Deployment with an HPA is simpler and has no cold start), when a latency-critical path can't tolerate a cold start and isn't worth a warm floor, or when the workload is long-running or stateful (serverless is for short, stateless request handling — batch and stateful work are other modules). On rollout, Knative gives you canary and rollback as a Route weight over revisions; a plain Deployment gives you rolling updates, or Argo Rollouts for metric-gated promotion. Functions via kn func are a ksvc from a code template — presented here as concept and instructor demo, because the cockpit has no local container build and the on-cluster path needs Pipelines. Then take the questions back to your org: which of your services sit idle a meaningful part of the day, and what do the always-on pods cost? When you say "cold start," is it a number or a fear? Can you canary and roll back without a redeploy? And where do your event-driven flows live today? The eventing depth and real workflows are the next module.
Visual: A two-column decision matrix (Lean serverless | Lean Deployment) across five rows (traffic shape, latency budget, invocation, rollout need, cost model), with a footnote pointer to Eventing (eventing depth + SonataFlow workflows) and Jobs, Batch & Queued Workloads (batch/Jobs) for "not this tool."
