# The canary portfolio

A miniature app-of-apps, shaped exactly like `platform-portfolio/`, that
`crd-unknown-field-guard.py --self-test` drives through the **real** `portfolio_jobs()`,
`render_job()` and `judge_job()` — never through a re-implementation of the wiring rule, because a
re-implementation can pass while the thing that ships is broken.

It proves four things the Helm canary next door cannot:

| overlay | proves |
|---|---|
| `argocd-bootstrap/operator` | an overlay in `PORTFOLIO_ALWAYS` is rendered with no Application pointing at it — the one imperative step `install.sh` applies with `oc apply -k`. Its `Subscription` carries `spec.channell`. |
| `stacks/canary-stack` | the stack overlay itself is rendered and its child `Application` objects are checked like any other CR (the clean control: they must produce no finding). |
| `components/wired` | a component reached ONLY by following `spec.source.path` on a rendered Application is pulled into the render set. Its `LocalQueue` carries `spec.clusterQueuee`. Break the wiring discovery and this is the finding that disappears. |
| `components/unwired` | the cost of the wiring rule, stated out loud. `apps/unwired.yaml` is **commented out** of the stack's `kustomization.yaml`, exactly as `stacks/observability/apps/loki-logging.yaml` is in the real tree, so nothing renders this overlay. Its `ClusterQueue` carries `spec.namespaceSelectorr` and the self-test asserts that defect is **still there** and **still not reported** — a control somebody quietly deletes stops controlling anything. |

Every planted field is judged against the same checked-in CRD snapshots the real run uses.
`expectations.yaml` declares all of it; the self-test asserts set equality, so a finding nobody
declared fails just as loudly as a declared one that stopped firing.

The **ownership split** — what a missing snapshot costs, and for whom — lives in the Helm canary next
door (`../chart/templates/ownership.yaml`), not here: it is a property of a single custom resource,
so it needs no portfolio around it. What this directory contributes to it is the real tree's
counterpart, `platform-portfolio/components/loki-logging`, whose `LokiStack` and
`ClusterLogForwarder` cannot be snapshotted on any cluster this project has. The self-test asserts
they are **named** in the unwired note with the verdict each would get.
