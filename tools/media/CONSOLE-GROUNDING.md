# Console click-path grounding — 2026-07-28

Observed in an authenticated OpenShift web console, **OCP 4.22.5**, signed in as **user1**
(an attendee identity, not cluster-admin). Recorded so `[CAPTURE-VERIFY]` markers can be
resolved without re-opening a browser, and so a later contributor can tell what was actually
seen from what was assumed.

Everything below is something I looked at. Where I did not check a claim, it says so — those
markers stay open on purpose.

## Deployment detail page (`/k8s/ns/<ns>/deployments/<name>`)

Tabs, in order: **Details · Metrics · YAML · ReplicaSets · Pods · Environment · Events · Security**

`Actions` menu, complete and in order:

    Edit Pod count
    Add HorizontalPodAutoscaler
    Add PodDisruptionBudget
    Pause rollouts
    Restart rollout
    Add storage
    Edit update strategy
    Edit resource limits
    Edit Health Checks
    Make Serverless
    Edit labels
    Edit annotations
    Edit Deployment
    Delete Deployment

**The health-checks item is state-dependent** and this bites the content. The console shows
**Add Health Checks** when the workload has no probes and **Edit Health Checks** once any probe
exists. `config-multienv` is correct to say "Add" in exercise 2 (its entry state has no probes —
all three are behind `{{- if .Values.solve }}`), but wrong to say "Add" again in exercise 4,
because exercise 2 just added a readiness probe. Any lab that touches probes twice must expect
the label to change under the reader.

### Environment tab
Section **Single values (env)** with Name/Value rows, an **Add more** control and
**Add from ConfigMap or Secret**; then a second section **All values from existing ConfigMaps or
Secrets (envFrom)**. Secrets appear as name references only — no values are rendered.

## Secrets list (`/k8s/ns/<ns>/secrets`)

Button is labelled just **Create**, and opens a dropdown:

    Key/value secret · Image pull secret · Source secret · Webhook secret · From YAML

## ConfigMaps list (`/k8s/ns/<ns>/configmaps`)

Button is labelled **Create ConfigMap** — a plain button, **not** a dropdown. Note the asymmetry
with Secrets; content that describes both in one breath will be wrong about one of them.
Whether it offers a form view as well as YAML: **not checked**.

## ImageStream detail (`/k8s/ns/<ns>/imagestreams/<name>`)

Tabs: **Details · YAML · History**. The Details page carries a **Tags** section showing digests —
observed `sha256:92f1b2c9…` alongside the Tekton Chains signature tag `sha256-92f1b2c9….sig`.
The `Actions` menu contents were **not** captured.

## Monitoring / alerting — the important one

The **cluster-scoped** page `/monitoring/alertrules` shows an attendee **nothing**: `0 - 0 of 0`,
with or without `?alert-source=user`, with or without `&ns=<ns>`. It has no Project selector.

Measured from inside the authenticated page:

| endpoint | result |
|---|---|
| `/api/prometheus/api/v1/rules` (non-tenancy) | `403 Forbidden (user=user1, verb=get, resource=prometheuses, subresource=api)` |
| `/api/prometheus-tenancy/api/v1/rules` (no namespace) | `400 Bad Request` |
| `/api/prometheus-tenancy/api/v1/rules?namespace=user1-dev` | **`200`** — returns the `parasol-claims.rules` group |

So the data is readable by the attendee; the cluster-scoped page simply is not the route to it.

**The working attendee route is the project-scoped page:**

    /dev-monitoring/ns/<ns>/alertrules?alert-source=user
    /dev-monitoring/ns/<ns>/alerts

It renders a `Project:` selector and tabs **Events · Alerting rules · Alerts · Dashboards ·
Metrics · Silences**. Two traps worth writing into any lab that uses it:

1. It **defaults to a `Source: Platform` filter chip**, which yields 0 rows for an attendee. The
   reader must switch Source to **User**, or the page looks broken.
2. At the healthy baseline the **State column reads `-`**, not the word "Inactive". The ruler's
   own state IS `inactive` (confirmed against thanos-ruler's `/api/v1/rules`), but that word is
   not what the column shows. Describe what the reader sees.

The rule's own detail page works and is reachable from that list. It shows Name, Severity, Source,
`For`, Expression, Description, Summary and Labels. Note UWM **injects the namespace selector**
into the expression: the fixture writes
`sum(rate(http_server_requests_seconds_count{status=~"5.."}[5m])) > 0.1`
and the console renders
`sum(rate(http_server_requests_seconds_count{namespace="user1-dev",status=~"5.."}[5m])) > 0.1`.

## Console plugins

`oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}'` lists
`pipelines-console-plugin` and `gitops-plugin` among the enabled set, and the `ConsolePlugin`
objects are days old — so a PipelineRun page that renders only **Details** and **YAML** tabs, with
no task graph, is a plugin that failed to load *in that browser session*, not a cluster that lacks
the plugin. Waiting on a page heading cannot distinguish those two; wait on something the plugin
itself renders (a task name, or the TaskRuns tab).

## A capture caveat

The browser used here renders dates in the machine's locale — observed `26 Tem 2026` (Turkish).
`tools/media/capture.py` pins `locale="en-US"` for exactly this reason. Any screenshot taken
outside that harness must have its locale checked before it is committed.

## Navigation terminology — the unified console renamed things

Grounded in the same session. These matter because several modules still use the pre-unified names,
and an attendee following them finds nothing.

The masthead **+** button (accessible name "Quick create") opens exactly three items:

    Import YAML · Import from Git · Container images

There is no `+Add` control anywhere. The left nav has an **Ecosystem** group containing exactly:

    Software Catalog · Installed Operators · Helm

There is no "Developer Catalog" entry, no perspective switcher, and no Administrator/Developer
perspectives — the console has been unified since 4.19.

So the mapping is:

| pre-unified wording | what is actually there |
|---|---|
| `+Add → Import YAML` | masthead **+** → **Import YAML** |
| `+Add → Container images` | masthead **+** → **Container images** |
| `+Add → Developer Catalog` | **Ecosystem → Software Catalog** |
| "Developer perspective", "perspective switcher" | nothing — there is one console |

## Other list-page shapes worth knowing before writing a click-path

Two list pages that look symmetrical are not. Secrets has a plain **Create** button that opens a
dropdown; ConfigMaps has a single **Create ConfigMap** button with no dropdown. Any sentence that
describes both in one breath will be wrong about one of them.
