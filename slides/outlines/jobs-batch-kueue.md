# M06 — Jobs, Batch & Queued Workloads

## Slide: The overnight run that can take down the cluster

- Parasol runs API in milliseconds
- And batch overnight: statements, fraud, rollups
- Batch has quietly grown huge
- One team's month-end starves everyone
- Nothing arbitrates between jobs

Notes: Open with the stakes and the two speeds. Parasol answers customers in milliseconds through its API, but the real weight is the overnight batch tier — statements, fraud scoring, actuarial rollups over every open claim. That work has grown until a single team's month-end run can crowd every other job off the cluster, because plain Jobs have no arbitration: every job the scheduler can place, it runs. The module is about running batch well — Jobs and CronJobs for the work, and admission control so no team's batch starves the rest.
Visual: A calendar/clock "2 a.m." with one giant job box squeezing several small job boxes off the edge of a cluster frame.

## Slide: The async spectrum — request, event, batch

- Request-driven: caller waits, low latency
- Event-driven: reacts per message, seconds
- Batch: bounded work, runs then stops
- You care it finishes, not its latency
- The Job is the batch-tier object

Notes: Place batch on the spectrum so people pick the right tool. Request-driven work has a caller holding a socket — a Deployment behind a Service, measured in latency. Event-driven work reacts to a message or webhook within seconds. Batch is different in kind: a bounded body of work runs to completion and stops — "process all 40,000 claims" — and nobody waits on a connection; you care that it finishes, correctly, within a window. OpenShift's object for that end of the spectrum is the Job.
Visual: Reuse concept diagram m06-...-01-async-spectrum.svg — request → event → batch, batch highlighted.

## Slide: The Job controller — runs to completion, then stops

- completions + parallelism: how many, how parallel
- backoffLimit: retries, then gives up
- Indexed Job: shard by $JOB_COMPLETION_INDEX
- CronJob: schedule, no-overlap, suspend
- Pod template is immutable — batch lives in Git

Notes: The vocabulary that makes the rest legible. A Job runs Pods until a set number succeed, then stops — the opposite of a Deployment. `completions` and `parallelism` set how much and how parallel (6 completions, 3 at a time = two waves). `backoffLimit` retries a failure, with exponential backoff, then marks the Job failed. An Indexed Job hands each Pod a fixed index to shard a dataset with no coordinator. A CronJob wraps a Job on a schedule, with `concurrencyPolicy` to prevent overlap and `suspend` to pause. And a Job's Pod template is immutable — you delete and recreate, which is the platform telling you batch belongs in Git.
Visual: A Job box spawning two waves of three Pods, plus a small CronJob clock and an "Indexed 0..4" strip.

## Slide: Admission control with Kueue

- ClusterQueue holds the quota
- LocalQueue: your project's pointer in
- Label a Job: queue-name → it's managed
- Full queue: admit some, hold the rest
- Higher priority preempts — evict + requeue

Notes: The heart of the module. Plain Jobs have no arbitration; Red Hat build of Kueue adds an admission layer above the Job controller. A ClusterQueue holds the quota (each attendee gets their own, so nobody starves anyone else); a LocalQueue is the namespaced pointer into it; a Job opts in with a `queue-name` label and Kueue holds it suspended until there is room. When the queue is full, some jobs are admitted and the rest wait — and a higher-priority job can preempt a running lower-priority one, evicting it back into the queue. You watch exactly this: five jobs, two admitted, three pending; one urgent job preempts a running one.
Visual: Reuse concept diagram m06-...-02-kueue-admission.svg — Job → LocalQueue → ClusterQueue → admitted / pending / preempted.

## Slide: AI batch is just batch

- Inference/eval job reads, calls model, stops
- Same queue-name label, same Workload
- Admitted and preempted identically
- GPU quotas: the same machinery
- Adopt the control plane before the crunch

Notes: The payoff, and the line SAs remember. A batch-inference or model-evaluation job is an ordinary Job — it reads input, calls a model, writes output, stops. It carries the same `queue-name` label, becomes the same Workload, and is admitted, queued, and preempted by the same ClusterQueue as the statement run. That is why the industry is standardizing GPU scheduling on this exact machinery: a ClusterQueue can hold `nvidia.com/gpu` quota, and a high-priority eval job can preempt a low-priority training run. Everything learned on tiny CPU jobs is the control plane that governs AI batch at scale.
Visual: The admission diagram again, with an "AI inference job" box feeding the same LocalQueue as a "statement job" box — identical path.

## Slide: What you'll do

- Run a monthly-statement Job in waves
- Break it, read the backoff, fix it
- Shard the dataset with an Indexed Job
- Schedule with a CronJob, then suspend
- Watch Kueue admit, queue, and preempt — then AI batch

Notes: Set expectations for the hands-on, all in your own `{user}-batch` project. You run a monthly-statement Job over a seeded dataset and watch it complete in parallel waves; you break a Job on purpose and read its backoff, its `BackoffLimitExceeded`, and the immutability refusal; you shard the dataset with an Indexed Job; you schedule it with a CronJob and suspend it. Then the core: submit five jobs into a tiny Kueue quota and watch two admitted, three queued, then one high-priority job preempt a running one. Finish by running a fraud-scoring inference Job through the very same queue.
Visual: Numbered arc strip: run → break/fix → shard → schedule → queue/preempt → AI inference.

## Slide: Map to your org — and when not

- Who owns the batch quota?
- Which CronJobs can you name the owner of?
- Where's your first GPU-contention fight?
- Don't Kueue a three-job team
- Don't cron what should be event-driven

Notes: Land the transfer and stay honest. Discussion prompts: who in your org decides how much of the cluster the batch tier may use and how teams share it; whether you can name the owner and concurrency policy of one production CronJob; where your first GPU-contention fight will happen and whether you would rather design that queue now or during the crunch. Then the credibility close on restraint: admission control earns its keep only under real contention — a three-job team on a cluster with headroom just needs a ResourceQuota; a CronJob polling every minute for an event is a queue-shaped problem wearing a schedule; and match the object to the lifecycle (runs forever → Deployment, runs once → Job).
Visual: Two-column card "reach for Kueue / a plain ResourceQuota is enough", with a footnote pointer to the Pipelines and Serverless modules for the tool-choice guide.
