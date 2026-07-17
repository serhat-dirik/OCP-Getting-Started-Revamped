# Eventing Deep-Dive & Serverless Workflows

## Slide: Stop calling services — emit a fact

- Parasol's claim → fraud-scoring + audit + notification + investigations
- Direct calls WELD the app to all four: their addresses, their health, their latency
- A slow fraud service stalls claim submission; a new listener = a producer change
- Eventing: the app emits ONE fact ("claim.submitted") and moves on
- Consumers SUBSCRIBE; the producer never learns who's listening

Notes: Open on the coupling problem, because that's the pitch. Parasol's claims-processor accepts a claim, and then several things must happen: fraud-scoring, an audit record, a customer notification, and for big claims a referral to investigations. If the claims app CALLS each of those directly, it's welded to all of them — it needs their addresses and APIs, it waits on every one, a slow or down fraud service stalls claim submission, and adding a fifth listener means changing and redeploying the claims app. Eventing breaks that weld. The producer states a fact — "com.parasol.claim.submitted, here's the claim" — into a broker, and returns immediately. It does not know, and does not care, who consumes it. Consumers subscribe: each declares, through a trigger, which events it wants. Fraud, audit, and notifications each get their own copy; a new analytics consumer is added by creating a trigger, with NO change to the claims app. That inversion — the producer emits, the platform routes, consumers subscribe — is the whole module.
Visual: Left panel "Direct calls": a claims box with four arrows fanning out to fraud/audit/notify/investigations, each arrow labeled with an address, the whole thing tangled and tinted red ("coupled: producer knows every consumer"). Right panel "Eventing": the claims box emits one arrow to a Broker hub; four consumers hang off the broker via labeled triggers, green ("decoupled: producer knows nothing"). A big equals-sign-turned-arrow between the panels.

## Slide: Four primitives — source, broker, trigger, sink

- Source emits events (here: a seeded PingSource ticker)
- Broker = the hub; producers POST CloudEvents to it, get HTTP 202
- Trigger = a subscription WITH A FILTER: "deliver matching events to this sink"
- Sink = anything addressable — here a ksvc consumer that scales 0→N on an event
- The CloudEvents envelope (type/source/id + your extension attributes) makes it routable

Notes: Knative Eventing is four moving parts, each a Kubernetes custom resource. A Source emits events — here a PingSource that emits a claim-shaped event on a schedule, the seeded producer. A Broker is the hub: it receives events and holds them for routing, it has an address, producers POST CloudEvents to it and get a 202 "accepted," and the default is in-memory — no external messaging system required. A Trigger is a subscription with a filter: "deliver broker events matching these attributes to this sink." Triggers are the routing layer. A Sink is anything addressable that receives events — here a Knative Service consumer that scales from zero on an event. And the thing that makes routing possible is the CloudEvents envelope: a small vendor-neutral wrapper with context attributes — type (what happened), source (who emitted it), id, specversion — plus your own extension attributes, like the claimpriority the seeded source stamps. Because the routable facts live in the envelope, a trigger never has to parse your data to decide where an event goes. Be honest about the source: it's a seeded ticker because parasol-claims doesn't emit CloudEvents yet — but everything downstream is real, and pointing the triggers at real claim events is one app change away.
Visual: The concept diagram eventing-deep-dive-...-01-eventing-model.svg — amber PingSource + a "you: POST" actor both feeding a blue Broker; three green triggers (catch-all, filter type, filter claimpriority) each to the light-blue consumer; a dashed edge to the dead-letter sink. Inset card: the CloudEvents envelope (type/source/id/specversion + Data), with `claimpriority: high` flagged as an "extension attribute → routable."

## Slide: Broker + Trigger vs Channel + Subscription

- Broker + Trigger = a HUB with per-trigger attribute FILTERING → fan-out to the right consumers
- Channel + Subscription = a linear PIPE, no filter, every subscriber gets everything
- Reach for Broker+Trigger for event DISTRIBUTION (the app-integration case)
- Reach for Channel+Subscription for an ORDERED processing pipeline
- A broker is built ON a channel — it's a choice of abstraction, not two systems

Notes: Knative gives you two ways to move events, and choosing is a semantics decision, not a style one. A Broker plus Triggers is a hub that many triggers attach to, each with its own attribute filter, so one event fans out to exactly the consumers whose filter matches. A Channel plus Subscriptions is a linear pipe with ordered subscribers and no per-subscriber filter — every subscriber gets every event. The rule of thumb: reach for Broker plus Trigger when you're distributing events to many interested consumers with filtering, which is almost always the app-integration case and is what this module builds. Reach for Channel plus Subscription when you have an ordered, linear processing pipeline and want explicit control of each hop. A broker is in fact implemented on a channel, so this is a question of the abstraction you program against, not two unrelated systems.
Visual: Two side-by-side diagrams. Left "Broker + Trigger": a hub with three triggers, each labeled with a different filter, fanning to three distinct consumers ("filtered fan-out"). Right "Channel + Subscription": a straight pipe with three inline subscribers in sequence ("ordered, no filter"). A footer decision line: "distributing to many, filtered → Broker · linear pipeline → Channel."

## Slide: Route by attribute — the filter is the routing

- A Trigger filter is an INCLUDE rule: matching delivered, non-matching DROPPED
- Filter on `type` (what happened) or a business extension attr (`claimpriority=high`)
- Triggers filter INDEPENDENTLY — one event can match several (fan-out) or none (dropped)
- Proven by match-count: submitted → 2×, rejected → 1× (both filters dropped it), high-value → 3×
- Change routing by editing a trigger — never by redeploying an app

Notes: Attribute filtering is an include rule. A trigger with filter type=com.parasol.claim.submitted delivers only matching events; everything else it drops. Multiple triggers filter independently on the same broker, so one event can match several triggers — fan-out — or none — dropped. In the lab attendees add a fraud-review trigger filtering on the CloudEvent type and an audit trigger filtering on the claimpriority extension attribute, both alongside the baseline catch-all, and prove filtering by match-count: because the consumer displays an event once per matching trigger, a plain claim.submitted shows up twice (catch-all plus the type filter), a claim.rejected shows up once (only the catch-all; both filters dropped it), and a high-priority claim.submitted shows up three times (all three matched). A non-matching event isn't an error — it got a 202 from the broker, it's just not that trigger's concern, and it doesn't even wake that trigger's consumer. The filter is each trigger's "what do I care about" rule, and you change routing by editing a trigger, not by touching application code.
Visual: One broker with three triggers (catch-all / filter:type / filter:claimpriority) to one consumer. Three event chips drop in — "submitted" (lights 2 triggers), "rejected" (lights 1), "submitted+high" (lights 3) — each annotated with its display count. A callout on the rejected chip: "202 from the broker, but DROPPED by both filters."

## Slide: Survive a failing consumer — retries + dead-letter sink

- Default: a failed delivery is retried a few times then DROPPED (silently)
- delivery: retry N with backoff (exp: 1s, 2s, 4s) — give a flaky consumer time to recover
- deadLetterSink (DLQ): exhausted events land in a separate sink, NOT dropped
- The dead event is STAMPED: knativeerrorcode=404, knativeerrordest=the failing address
- A DLQ is a diagnosable record — "here are the events we couldn't deliver, and why"

Notes: Routing works — but what happens when a consumer fails? By default a failed delivery is retried a few times and then dropped, silently. A trigger's delivery spec adds two things. Retries: on a failed delivery Knative retries N times with a backoff, exponential being the sane default, giving a briefly-unhealthy consumer time to recover. And a dead-letter sink: when the retries are exhausted, the event is NOT dropped — it's delivered to a separate sink you nominate, stamped with why it died. In the lab attendees give the fraud-review trigger retry:3 with exponential backoff and a dead-letter sink to claims-dlq, then deliberately break the consumer — point delivery at a path it 404s — and watch a claim retry for about eight seconds (one try plus three retries at one, two, four seconds) and then dead-letter. They open the dead event in the DLQ and read knativeerrorcode:404 and knativeerrordest, the exact destination that kept failing. That's the whole value over dropping: the dead-letter sink is a diagnosable record, not a black hole. In production you alert on dead-letter arrivals and drain the sink once the consumer is healthy.
Visual: A trigger→consumer edge with the consumer marked broken (red X). The event bounces: attempt 0, retry 1 (1s), retry 2 (2s), retry 3 (4s), each a small arrow, total "~8s." Then a fat arrow to the dead-letter sink showing the dead event card with `knativeerrorcode: 404` and `knativeerrordest: …/process` highlighted. Caption: "not dropped — dead-lettered, with why."

## Slide: Choose the broker backing — in-memory vs Kafka [ADD-ON]

- Default in-memory broker (MTChannelBasedBroker): free with Serverless, SYNCHRONOUS, NOT durable
- Synchronous = the producer's 202 waits for delivery; a cold consumer makes the first POST ~14s
- In-memory = lost on broker restart → fine for dev / best-effort internal events
- Kafka broker [ADD-ON] (Streams subscription): durable, replayable, ordered — events you can't lose
- Swapping is a broker-class change; triggers/filters/consumers UNCHANGED

Notes: The core of this module runs entirely on the in-memory broker Knative Eventing ships — no extra subscription, no middleware, the right default for most app-integration eventing. Two properties you see and should understand. It's synchronous: when you POST to the broker, the 202 comes back only after delivery completes, so a scaled-to-zero consumer must cold-start first and the very first POST takes ten-plus seconds — the same JVM cold start from Serverless, now on the delivery path; warm, it's sub-second. And it's not durable: in-memory means gone if the broker pod restarts, which is fine for dev, demos, and best-effort internal events. When you outgrow it, the answer is a Kafka-backed broker from Streams for Apache Kafka — a separate subscription, so the module never requires it — which adds durability, replay, and per-partition ordering. The honest guidance: default to in-memory; move to Kafka when the events are financially or legally consequential and losing one is unacceptable. And the swap is a broker-class change, not an app change: your triggers, filters, and consumers are unchanged — that's the point of the broker abstraction. "We have eventing" on an in-memory broker is fine until the first dropped payment event, and then it's a separate subscription and a real migration, not a config flag.
Visual: A two-column table (In-memory | Kafka [ADD-ON]) across rows durability (none | persistent), replay (no | yes), ordering (best-effort | per-partition), cost (free | Streams subscription), reach-for-it-when (dev/best-effort | can't-lose/replay/throughput). A callout arrow between them: "swap = broker class only; triggers + consumers unchanged." A small footnote: "[ADD-ON] = separate Streams subscription."

## Slide: Choreography vs orchestration — workflows with SonataFlow [ADD-ON]

- What you built is CHOREOGRAPHY: each consumer reacts on its own, no conductor
- Great for decoupled fan-out; HARD to reason about with branches, cross-step retries, timeouts
- ORCHESTRATION: one workflow conducts — branch on data, call services, timeout branch
- OpenShift Serverless Logic (SonataFlow) on Knative — GA; console + kn-workflow CLI
- Concept + [ADD-ON] here (a per-user workflow runtime + state DB is real footprint)

Notes: Triggers give you choreography: each consumer reacts to events on its own, with no central conductor. It's beautifully decoupled and hard to reason about once a business process has branches, retries across steps, and timeouts — "did the claim get approved, or is it stuck waiting on a step three services away?" Orchestration answers that with a conductor: one component owns the process, calls services in order, branches on data, and handles timeouts. On OpenShift that conductor is OpenShift Serverless Logic — a SonataFlow runtime implementing the CNCF Serverless Workflow spec, running on Knative. A Parasol claims-approval workflow would auto-approve claims below a threshold, route the rest to a review service, and take a timeout branch if review doesn't answer in time, as one declarative workflow with a queryable instance per claim. It's generally available since Serverless 1.33 with a console, a kn-workflow CLI, and a VS Code extension — real and production-ready. It's presented here as a concept and an add-on for one honest reason: a per-user SonataFlow platform, the workflow runtime plus its own state database, is significant footprint for every seat, and the graded core of this module is the eventing substrate. The decision is what travels with you: choreography for decoupled fan-out; orchestration when a process needs a conductor.
Visual: Left "Choreography": three services reacting to a broker independently, no center, labeled "decoupled, but who's tracking the process?" Right "Orchestration": a central SonataFlow workflow node with a flowchart inside (threshold check → auto-approve / → review → timeout branch) calling out to services, labeled "one conductor, queryable per-claim state." Footer: "[ADD-ON] concept — decision > deployment."

## Slide: Eventing decision guide — what each tool is FOR

- React to a fact, fan out to many, filter per consumer → Broker + Triggers (this module)
- Ordered linear pipeline → Channel + Subscriptions
- Events you can't lose → Kafka broker [ADD-ON]; multi-step process w/ branches → SonataFlow [ADD-ON]
- Wrong tools: CI/CD build → Pipelines (Pipelines Fundamentals); bulk work → Jobs+Kueue (Jobs, Batch & Queued Workloads); answer-now → direct call
- Map to your org: where does adding a consumer force a producer change? where's a DLQ + alert?

Notes: Close on the decision and the transfer. Reach for Broker plus Triggers — this module — when you react to a fact, fan out to many consumers, and filter per consumer; that's the app-integration case. Reach for Channel plus Subscriptions for an ordered, linear pipeline. For events you cannot afford to lose, that's a Kafka broker, an add-on on a Streams subscription. For a multi-step process with branches and timeouts, that's orchestration with SonataFlow, also an add-on. And know the wrong tools: a step-by-step CI/CD build is Pipelines from Pipelines Fundamentals, not eventing; bulk parallel work with admission control is Jobs plus Kueue from Jobs, Batch & Queued Workloads; and when a caller needs an answer NOW from one service, a direct synchronous call is simpler than emitting an event and correlating a reply. Then take the questions back to your org: where does adding a consumer force a change to the producer? Which synchronous calls fail the user because a downstream is slow? Where does routing live — in triggers or in if-statements? How would you know you were silently losing events — do you have a dead-letter sink and an alert on it? And which of your events actually need Kafka, and do you know it's a separate subscription? The honest boundary of the module: the source here was a seeded ticker because the app doesn't emit yet — making parasol-claims emit real claim events and repointing the triggers is one app change from closed.
Visual: A "what's it FOR" matrix: rows = need (react+fan-out+filter / ordered pipeline / can't-lose / multi-step process / CI-CD build / bulk work / answer-now), columns = Reach for | Not. Right rail "Map to your org" with the five prompts as check-boxes. Bottom banner pointer: "Pipelines Fundamentals Pipelines · Jobs, Batch & Queued Workloads Jobs+Kueue · Serverless Serverless (the source→broker→trigger taste this module deepened)."
