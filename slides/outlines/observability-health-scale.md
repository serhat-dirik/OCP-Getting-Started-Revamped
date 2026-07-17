# Observability, Health & Scale

## Slide: 02:00 — the claims API is failing, and you can't tell why

- A dashboard is red: *something* is wrong
- But not *which* request, *which* dependency, *how many* users
- Every guessing minute is a minute the outage runs
- Observability = "something's wrong" → "here's the failing request" in seconds
- Health & scale = ride out the load and maintenance that cause half the pages

Notes: Open on the 2 a.m. page. The claims service is throwing errors and the on-call can see that it's unhealthy but not why. The expensive part of an incident is almost never the fix — it's finding where. This module turns the claims service from something you run blind into something you can see and steer, using only capabilities the platform already ships. Two halves: observability (see the fault fast) and health/scale (survive the load spikes and node maintenance that cause a lot of the pages in the first place).
Visual: A dark red "claims API" tile with a question mark; a clock at 02:00; three faint signal icons (metric line, log line, trace waterfall) waiting to be switched on.

## Slide: Three signals in five minutes

- **Metrics** — how much / how fast / how bad? Cheap, always-on, *alertable*
- **Logs** — what exactly happened? Rich detail, one event, noisy at scale
- **Traces** — where did the time go? One request across services
- You need all three: none answers the others' questions well
- The discipline: metrics to notice, traces to locate, logs to confirm

Notes: The foundation. Metrics are numbers over time — request rate, error rate, latency, CPU — always on and what you alert on, but a metric won't tell you which claim failed. Logs are individual events with full detail, but at scale they're a firehose. Traces follow one request across every service and DB call and show where the time went. The operating discipline is metrics to notice and alert, traces to locate the fault, logs to confirm the detail. Parasol's claims service is deliberately quiet at runtime — a healthy request logs nothing — which is exactly why you don't operate it by tailing logs.
Visual: Concept diagram observability-health-scale-01-three-signals — request fanning into metrics/logs/traces, each labeled with the question it answers.

## Slide: Observe your app; the platform observes itself

- You don't install a monitoring stack — OpenShift already runs one
- User-workload monitoring (Prometheus) is watching the platform now
- To add *your* app: a **ServiceMonitor** — "scrape this Service's /q/metrics"
- That's the whole integration
- The claims app already speaks it: /q/metrics + a custom `claims_created_total`

Notes: The surprise that lands: there's no monitoring to install. User-workload monitoring is already running. To get your app in, you point it at your app with a ServiceMonitor — a small object that says "scrape this Service every 30 seconds." The claims service already exposes Prometheus metrics at /q/metrics — the framework's HTTP timers plus a business metric the team added by hand, claims_created_total. Your job isn't to build the plumbing; it's to consume it: read, alert, act. Same story for traces — the app emits OpenTelemetry to a shared collector that forwards to Tempo, so "add tracing" is a platform decision, not a per-app rewrite.
Visual: Concept diagram observability-health-scale-02-servicemonitor-bridge — app /q/metrics → ServiceMonitor → user-workload monitoring → console + your alert.

## Slide: Alert on symptoms — then make it fire

- A dashboard only helps when someone's looking; an alert watches for you
- Author a **PrometheusRule** in your namespace — scoped to you, invisible to others
- Alert on the **5xx rate** (a symptom users feel), not on internal causes
- Prove it: take the database away, watch Inactive → Pending → Firing (~3 min)
- Recover: DB back **and** restart the app (the connection pool is poisoned)

Notes: An alert is a metric-watcher that fires when a line is crossed. You author it as a PrometheusRule in your own namespace; user-workload monitoring scopes it to you. Alert on symptoms — the 5xx rate your users feel — not on every internal metric, or you train people to ignore the pager. Then earn it: scale the database to zero and the API 500s. On the build run the alert went Pending at ~77s and Firing at ~195s — the 2-minute `for:` window stops a blip from paging anyone. The recovery is the lesson: bringing the database back isn't enough because the app holds dead connections — you restart the app to drop the poisoned pool.
Visual: A traffic-light alert going green→amber→red, with the DB tile scaled to 0; a callout "fix = DB back + app restart".

## Slide: Trace — where did the time go

- Metrics say the 5xx rate is up; they can't say *which* request or *where*
- A trace follows one request: method, route, status, total time
- **Observe → Traces** (Cluster Observability Operator + Tempo): `{ service.name = "parasol-claims" }`
- Rank by duration to find the outlier endpoint; read code for the *why*
- The `trace_id` **exemplar** links a metric spike straight to one trace

Notes: When metrics say the error rate is up, a trace tells you which request and where its time went. The claims service emits an OpenTelemetry trace per request; the Cluster Observability Operator's distributed-tracing plugin surfaces them in Observe → Traces. Rank by duration to find the outlier — the history endpoint's N+1 (one DB query per event) is the shape you're hunting. Honest scoping: the image emits the HTTP span today; per-query DB spans are a build-time flag tracked as an enhancement, so the trace tells you which endpoint, and the code tells you why. The modern glue: each metric carries a trace_id exemplar, so a latency spike links straight to the one request that caused it.
Visual: Concept-style trace waterfall for /history (single HTTP span today), with a callout "+ DB spans = enhancement" and an exemplar arrow from a metric spike to a trace.

## Slide: Scaling is a decision, not a reflex

- **HPA** — add replicas on CPU/memory (the workhorse; this module)
- **Serverless** — scale to zero when idle (cross-ref: Serverless module)
- **KEDA** — scale on queue depth / events (Jobs + eventing modules)
- **VPA** — right-size one pod's requests (concept only; never pair with HPA on the same resource)
- Live: burst load → CPU 221% → HPA scales 2→4 in ~24s

Notes: "It's slow — add replicas" is only sometimes right. Four tools: HPA adds replicas when CPU/memory climbs with traffic (the workhorse, and what you build — it needs a CPU request to compute utilization against). Serverless scales to zero for spiky/idle services. KEDA scales on external signals like queue depth for event-driven work. VPA right-sizes one pod rather than adding pods — useful, but never point a VPA and an HPA at the same resource, they fight. The live moment: drive a burst, CPU hits 221%, the HPA scales to the ceiling of 4 in about 24 seconds, then holds for a 5-minute window before shrinking so it doesn't flap.
Visual: Concept diagram observability-health-scale-03-scaling-decision-tree — four branches from "what is the pressure?"; HPA highlighted.

## Slide: Survive the drain with a PodDisruptionBudget

- Node maintenance moves your pods every patch cycle
- A **PDB** is the contract: "evict my pods, but never leave me fewer than one"
- `ALLOWED DISRUPTIONS` = current healthy − minAvailable
- The drain paces itself: evict one, wait for a healthy replacement, then the next
- The eviction API refuses the last one: *"Cannot evict pod ... would violate the disruption budget"*

Notes: Autoscaling handles load; the other half of staying up is voluntary disruption — the node drains that happen every patch cycle. A PodDisruptionBudget is your app's contract with the platform: you may take my pods for maintenance, but never leave me below one healthy. On a drain, the platform evicts one pod, waits for its replacement to be healthy, then takes the next — never the last. The mechanism is the eviction API literally refusing: "Cannot evict pod as it would violate the pod's disruption budget." That turns a routine node drain from an outage risk into a routine operation. Watch out for the deadlock: minAvailable at or above your replica count means zero allowed disruptions and a drain that blocks forever.
Visual: A node draining, two claims pods; one evicted + rescheduling, the second held with a "budget: wait" lock icon.

## Slide: What you built — and it was already yours

- Metrics + a custom business metric in user-workload monitoring
- An alert you authored and made fire, then recovered
- A trace that shows a request's path; a metric that points at its trace
- An HPA that grows the service under load; a PDB that survives maintenance
- None of it was a separate product to buy — it ships with the platform

Notes: Close by connecting it back. You instrumented nothing and consumed everything: golden signals and a business metric, an alert you made fire, a trace, an HPA, a PDB — the observability, health and scale layer over the platform you'd built through the earlier modules. And the punchline for the room's leadership: user-workload monitoring, the Cluster Observability Operator, Tempo and OpenTelemetry all ship with OpenShift. Teams that treat "add monitoring" as a procurement project are usually re-buying what their subscription already includes.
Visual: Concept diagram observability-health-scale-05-what-you-built — the claims service with metrics/alert/trace/HPA/PDB layered on, all green.
