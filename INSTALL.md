# Installing the Workshop

Install, run and remove the workshop on an OpenShift cluster. Every command runs from a clone of this
repo. `tools/ws/adm` is the operator CLI; attendees only get `ws` inside their cockpit.

1. [Before you order](#1-before-you-order)
2. [Install](#2-install)
3. [During a delivery](#3-during-a-delivery)
4. [After a delivery](#4-after-a-delivery)
5. [Troubleshooting](#5-troubleshooting)
6. [What the install never changes](#6-what-the-install-never-changes)

---

## 1. Before you order

### Requirements

| Need | Value |
|---|---|
| OpenShift | 4.20 or newer (verified on 4.22) |
| Access | `cluster-admin` |
| Storage | A default StorageClass. Some labs need RWX. |
| Nodes | `linux/amd64`. See [Node count](#node-count). |
| Network | Outbound access to the Red Hat and Quay registries |
| AI modules (optional) | An OpenAI-compatible chat-completions endpoint and key: Red Hat MaaS, vLLM, or a public provider. No GPU on your cluster. Without it, the AI modules are unavailable. |
| Not supported | OpenShift Local, single-node clusters |

- **Red Hat SAs:** order [Field Sourced Content - OpenShift Base](https://catalog.demo.redhat.com/catalog/babylon-catalog-prod?item=babylon-catalog-prod/published.ocp-field-asset.prod)
  from the Red Hat Demo Platform (internal). Set the worker count yourself — it does not default to 3.
- The same catalog item can deploy the workshop for you through the `helm/bootstrap/` chart instead
  of `bootstrap/install.sh`.
- Install and smoke-test **the day before**. Never install in front of the room.

### Sizing

```
CPU    = 32  + attendees × 2.5    + 20%
Memory = 56 Gi + attendees × 1.5 Gi + 20%
```

- 32 CPU / 56 Gi is the platform before any attendee does anything (measured requests).
- **CPU decides the worker count, not memory.** Each Dev Spaces workspace requests 2.5 CPU on one node.
- Prefer fewer, larger workers. Below 16 vCPU per worker, capacity is stranded.
- Size on requests, never on a `top` reading — a cluster that looks idle can still refuse a pod.
- RHACS alone is 26 Gi. To order lean, disable the modules that use it (`modules_disabled`).

Workers needed **by capacity** (allocatable ≈ vCPU − 2):

| Worker size | 12 attendees | 20 | 25 | 30 |
|---|---|---|---|---|
| 16 vCPU / 64 GiB | 6 | 8 | 9 | 10 |
| 24 vCPU / 96 GiB | 4 | 5 | 6 | 6 |
| **32 vCPU / 64 GiB** | **3** | **4** | **4** | **5** |
| 48 vCPU / 192 GiB | 2 | 3 | 3 | 3 |

Then apply the node count below. **Five 32 vCPU / 64 GiB workers run any workshop up to 30 people.**

### Node count

Two floors, both on top of capacity:

1. **At least 3 dedicated workers** (worker role, not also control plane).
   Below 3, the installer labels the batch node but does not taint it.
2. **At least 5 schedulable `worker`-role nodes.** Control planes that also carry the worker role
   count. Check:

   ```bash
   oc get nodes -l node-role.kubernetes.io/worker   # 5 or more rows = OK
   ```

| Cluster shape | Order |
|---|---|
| RHDP OpenShift Base (3 control planes, also workers) | 3 workers, or more for capacity |
| Control planes tainted (production-shaped) | 5 workers, or more for capacity |

Both floors exist for one module, `deployment-targets-scheduling`:

- **Fewer than 5 worker-role nodes:** disable it — `modules_disabled: [deployment-targets-scheduling]`.
- **Fewer than 3 dedicated workers:** the install succeeds. The module's `nodeSelector` half runs; its
  taint/toleration half cannot be shown, and `adm verify` reports it not-applicable.
- **Never hand-taint a node to get the beat back.** On two workers that starved RHACS for hours.
- **Compact 3-node cluster** (every node is control plane + worker): it gets the taint. Supported, but tight.
- **The `helm/bootstrap/` chart taints unconditionally.** On fewer than 3 workers, use
  `bootstrap/install.sh`, or remove the taint from `oc get nodes -l workshop.redhat.com/pool=batch`.

---

## 2. Install

1. **Clone the repo.**

   ```bash
   git clone https://github.com/serhat-dirik/OCP-Getting-Started-Revamped.git
   cd OCP-Getting-Started-Revamped
   ```

2. **Check your tools:** `oc`, `git`, `yq` (mikefarah v4), `htpasswd` (`httpd-tools`, or
   `brew install httpd`), `openssl`. The installer stops with a clear message if one is missing.

3. **Log in as cluster-admin.** Use a kubeconfig file of its own, so other terminals and tools keep
   pointing where they were:

   ```bash
   export KUBECONFIG=~/.kube/workshop.config
   oc login --web https://api.<cluster-domain>:6443
   ```

4. **Run the preflight.** Read-only; it changes nothing.

   ```bash
   tools/ws/adm preflight
   ```

   It must end with `✅ ready to install`. On a customer cluster, **show them this output first.**

   | Row | Meaning |
   |---|---|
   | `ADOPT` | They already have it. The workshop reuses theirs; uninstall leaves it. |
   | `CREATE` | The workshop adds it; uninstall removes it. |
   | `⚠ Argo CD controller memory` | Their Argo CD runs at 2Gi; the workshop needs 6Gi. The install asks before raising it (restarts their controller; uninstall restores it). |
   | `⚠ prior install detected` | The installer ran here before. Re-running is safe. For a new cohort, use `ogsr-reset.sh` ([§4](#4-after-a-delivery)). |

   The preflight does not cover each operator. To preview those too (also read-only):

   ```bash
   platform-portfolio/argocd-bootstrap/install.sh \
     --stacks "$(ls platform-portfolio/stacks | tr '\n' ',' | sed 's/,$//')" --adoption-plan
   ```

   No output means nothing to adopt. Otherwise, one line per operator:

   | Verdict | What the install does |
   |---|---|
   | `skip` | Uses theirs, never installs ours. Uninstall preserves it. Example: cert-manager on every RHDP cluster. |
   | `warn` | Installs ours alongside theirs in the same namespace. Nothing of theirs is deleted. |
   | `refuse` | Stops before changing anything: that namespace already has someone else's OperatorGroup. Drop the stack, or have the owner remove theirs. |

   Also good to know: OpenShift GitOps and Lightspeed are reused if present. A Keycloak (RHBK)
   elsewhere on the cluster is not touched — the workshop runs its own in `sso-workshop`.

5. **Configure.** All input is in one gitignored file; the installer takes no flags.

   ```bash
   cp bootstrap/vars.example.yaml bootstrap/vars.yaml
   ```

   | Key | Set it to |
   |---|---|
   | `users` | Attendee count (`user1`…`userN`). Change later with `adm scale-users N`. |
   | `cluster_domain` | `""` to auto-detect |
   | `workshop_user_password` | Shared attendee password. Memorable on purpose; not a secret. |
   | `maas.endpoint` / `.model` / `.api_key` | The AI endpoint, model and key |
   | `lightspeed` | `true` installs OpenShift Lightspeed on your model. Skipped automatically without a MaaS key, or when the cluster already has Lightspeed. |
   | `modules_disabled` | Modules to leave out, e.g. `[m13, m22]`. Hidden from the cockpit, and their components are not installed. |
   | `modules_enabled` | The opposite, e.g. `[m1, m2, m3, m4, m5]`. Empty means the whole catalog. Use one key or the other, not both. |
   | `repo_url` / `repo_revision` | Where the content is mirrored from |

6. **Install.** About 15–20 minutes. Idempotent: re-run it freely.

   ```bash
   ./bootstrap/install.sh
   ```

   - Unattended run (no terminal to answer the Argo CD memory question):
     `OGSR_ADOPTED_ARGOCD_MEMORY=apply ./bootstrap/install.sh`
   - `⚠ <component>: …` means ours was installed alongside theirs. Note the namespace; you will
     check it before uninstalling.
   - A refusal stops the run with nothing changed.
   - The final banner is not proof. Do step 7.

7. **Verify.**

   ```bash
   tools/ws/adm doctor        # login, Argo CD, Gitea, operators
   tools/ws/adm status        # every platform app and every attendee
   ```

   Healthy looks like:
   `Summary: 5 user(s) · shared cockpit showroom-shared ✅ 1/1 · 0 entry app(s) (0 healthy, 0 need attention) · platform all-Synced ✅`

   The attendee-facing URLs (`<apps>` is the cluster's `apps.` domain):

   | | URL |
   |---|---|
   | Showroom (attendees) | `https://ogsr-showroom.<apps>` |
   | Etherpad (shared notes) | `https://ogsr-pad.<apps>/p/workshop` |

   Then spot-check one module:

   ```bash
   tools/ws/adm start m01 --user user1
   tools/ws/ws verify m01 --user user1
   tools/ws/ws reset  m01 --user user1
   ```

   `verify` checks the state you are in: before the lab it expects the lab undone, after the lab it
   expects it done. Run it at the wrong point and the result means nothing.

---

## 3. During a delivery

Attendees self-serve with `ws prep`, `ws verify` and `ws reset`. Your commands:

| Task | Command |
|---|---|
| Set up a module for someone stuck | `tools/ws/adm start <module> --user userN` |
| Show the finished state (instructor only) | `tools/ws/adm solve <module> --user userN` |
| Put someone back to the start | `tools/ws/ws reset <module> --user userN` |
| Change the shared password | `tools/ws/adm passwd [NEWPASS]` |
| Grow or shrink the cohort | `tools/ws/adm scale-users N` |
| Push content changes to the cockpits | `tools/ws/adm git-refresh --restart-terminals --all` |
| See what the AI modules run on | `tools/ws/adm maas show` |
| Change the AI model or key | `tools/ws/adm maas set` |
| Find pods on an old image | `tools/ws/adm rebuild-images --check` |
| Rebuild an app image everywhere | `tools/ws/adm rebuild-images --image <name> --all` |

**Push content changes**

- `adm git-refresh --restart-terminals --all` syncs the mirror, waits until it matches origin, then
  restarts the cockpits. Cockpits read content only at pod start, so this order matters.
- A scope is required: `--all` or `--user U`. Without one it restarts nothing.
- Run it between modules, never mid-exercise.

**Change the AI model or rotate the key** — no reinstall.

```bash
tools/ws/adm maas set --model qwen3-14b           # same key, other model
tools/ws/adm maas set --key-file ~/new-maas.key   # new key, same model
pbpaste | tools/ws/adm maas set --key-stdin       # key never touches disk or shell history
tools/ws/adm maas show                            # every attendee should read "working"
```

- Nothing changes until the key, endpoint and model pass a live test together; a 401/403 is refused.
- There is no `--key <value>` flag on purpose: `ps` would show it to every user on the machine.
- Attendees' AI modules pick up the change without losing their lab work.

**Rebuild an app image**

```bash
tools/ws/adm rebuild-images --check                        # read-only; exits 1 if anything is behind
tools/ws/adm rebuild-images --image parasol-claims --all   # build, then roll only stale pods
tools/ws/adm rebuild-images --no-build --user user3        # roll one attendee
```

- Knative Services cannot be rolled. Use `ws reset <module> --user userN` instead.

**Long deliveries:** each module an attendee starts stays on the cluster until reset. If the cluster
gets crowded, reset finished modules.

---

## 4. After a delivery

| Command | Removes | Use when |
|---|---|---|
| `tools/ws/ws reset <module> --user U` | One module, one attendee | Someone wants a redo |
| `./bootstrap/ogsr-reset.sh` | All lab work. Platform, accounts, Gitea, Keycloak and cockpits stay. | **Next cohort, same cluster — the normal path** |
| `./bootstrap/ogsr-wipe-users.sh` | `user2`…`userN` completely (`--keep 2` keeps two) | Cutting down to one sample attendee |
| `./bootstrap/ogsr-uninstall.sh` | Everything the workshop created | Giving the cluster back |

- All three scripts take `--dry-run` (show the plan) and `--yes` (no prompt).
- They need the full repo checkout, not just `bootstrap/`.
- `ogsr-reset.sh --restart-terminals` also cycles the cockpits for the new group.

**What `ogsr-wipe-users.sh` leaves behind**

- SonarQube accounts. If the next cohort uses a new password, delete the old accounts in SonarQube first.
- Developer Hub catalog entries for deleted repos. Cosmetic.

### Remove the workshop

1. Preview. **Never skip this on a customer cluster.**

   ```bash
   ./bootstrap/ogsr-uninstall.sh --dry-run    # WIPE / PRESERVE plan
   ```

2. For each `⚠` component the install reported, see what is really in that namespace:

   ```bash
   oc get subscriptions.operators.coreos.com,csv -n <namespace>
   ```

3. Uninstall:

   ```bash
   ./bootstrap/ogsr-uninstall.sh
   ```

   Adopted operators — their namespaces, Subscriptions, CSVs and OperatorGroups — are preserved.
   The script saves its state to `${TMPDIR:-/tmp}/ogsr-uninstall-state.txt`. Keep it.

4. Check what is left. Read-only; **it never deletes anything.**

   ```bash
   ./bootstrap/ogsr-check-clean.sh                      # same machine
   ./bootstrap/ogsr-check-clean.sh --state-file <path>  # from anywhere else
   ```

   It prints an `oc` command for each leftover it can attribute. The cluster admin decides what to run.

   | Exit | Meaning |
   |---|---|
   | `0` | Nothing unexpected. Kept-on-purpose items are listed by name. |
   | `1` | Leftovers listed above |
   | `2` | Could not run: no `oc`, not logged in, or a broken residue ledger |

   - `SHARED` CRDs are never offered for deletion: another operator owns them too, or they still have
     the cluster owner's instances. Example: `keycloaks.k8s.keycloak.org`. Deleting a CRD deletes every
     instance in every namespace.
   - Without the state file, the checker guesses by name and says so. Verify what it prints.

---

## 5. Troubleshooting

Before escalating, collect:

```bash
tools/ws/adm doctor [--user userN]
tools/ws/adm status
tools/ws/adm diag --user userN [<module>]    # read-only bundle for one attendee
oc get applications -n openshift-gitops
```

### Attendee gets Unauthorized

`oc whoami` → `error: You must be logged in to the server (Unauthorized)`

- **Cause:** their browser sign-in expired (24h by default). The cluster is fine.
- **Fix:** reload the cockpit page, sign in, reopen the terminal.
- Session lifetime: `oc get oauth cluster -o jsonpath='{.spec.tokenConfig.accessTokenMaxAgeSeconds}'`
  (empty = 24h). `adm session-refresh` does not apply to the shared cockpit.

### ws prep is refused: own AppProject only

`ValidatingAdmissionPolicy 'ogsr-attendee-entry-app-guard' denied request`

- **Cause:** the cockpit runs an old `ws`. The cluster got the new policy; the cockpit has not re-cloned.
- **Fix:** `tools/ws/adm git-refresh --restart-terminals --all`
- Check a cockpit (`3` = current, `0` = old):
  `oc exec -n ogsr-showroom deploy/showroom-shared -c terminal -- grep -c ARGO_PROJECT_PIN /showroom/repo/tools/ws/ws`

### A cockpit serves old content

- **Cause:** the cockpits restarted before the mirror caught up.
- **Fix:** `tools/ws/adm git-refresh --restart-terminals --all`
- Check what is really served. Ask the container, not the Route — the Route returns the login page
  (HTTP 403) for everything:
  `oc exec -n ogsr-showroom deploy/showroom-shared -c content -- curl -s http://127.0.0.1:8000/modules/<slug>/lab.html | grep -o '<expected text>'`

### An Argo Application will not sync

- Never start a sync while an operation is Running; it is silently dropped. Do: sync the mirror →
  hard refresh → wait ~10s → sync.
- Stuck operation: patch `status.operationState.phase=Terminating`, then sync.
- Keeps applying old content: the manifest cache is stale. Bump the chart version.
- Helm list literals (`{a,b,c}`) do not work in `helm.parameters`. Keep lists in `values.yaml`.
- A change to a hook only does not propagate. Delete the hook Job, then sync.

### A namespace is stuck Terminating

```bash
oc get ns <name> -o jsonpath='{range .status.conditions[*]}{.type}={.status}: {.message}{"\n"}{end}'
```

| Condition | Fix |
|---|---|
| `NamespaceDeletionDiscoveryFailure=True` | A stale APIService. Every namespace on the cluster is stuck. Remove the unavailable APIService. |
| `NamespaceFinalizersRemaining=True` | Find the blocking object. If its operator is gone, remove the finalizer **from that object** — never from the namespace. |

### An operator stops upgrading

- **Cause:** two OperatorGroups in one namespace. OLM fails every CSV there while the pods keep running.
- Check (must print nothing):
  `oc get operatorgroups -A --no-headers | awk '{print $1}' | sort | uniq -c | awk '$1>1'`
- Always write `subscriptions.operators.coreos.com` in full; three API groups use `subscriptions`.

### Pods stuck Terminating, Multi-Attach errors

- **Cause:** wedged `VolumeAttachment`s after a disruption. Looks like several unrelated outages.
- **Fix:** force-delete the stuck pods, delete the wedged VolumeAttachments, then re-check OperatorGroups.

### Attendee cannot log into a tool

| Tool | Login |
|---|---|
| OpenShift console | `userN` + workshop password, **workshop-users** provider |
| Gitea, SonarQube | Same pair (SonarQube is readable without login) |
| MTA | None — the Hub is open |
| Argo CD (attendee) | Through the cockpit link |

SonarQube rejects the login → its seed job did not run: `oc logs job/sonarqube-user-seed -n sonarqube --tail=20`.
Re-syncing `workshop-config` re-runs it.

### AI modules fail with auth errors

- **Cause:** usually a key for a different model — keys are model-scoped.
- Run `tools/ws/adm maas show`:
  - `credential-rejected-by-endpoint` — wrong key for this endpoint or model.
  - `credential-is-a-jwt-not-an-api-key` — fell back to an adopted Lightspeed secret. Stage the workshop's own key.
- **Fix:** `tools/ws/adm maas set`. No reinstall.

### Lightspeed shows "Waiting for OpenShift Lightspeed service"

- **Cause:** RHDP clusters ship Lightspeed pointed at Azure OpenAI, and its service principal was
  deleted. Not caused by the workshop. **AI modules are unaffected**; only the console assistant is.
- Confirm: the `lightspeed-app-server` pod is `1/2`, and its log shows `AADSTS700016`:
  `oc -n openshift-lightspeed logs deploy/lightspeed-app-server -c lightspeed-service-api --tail=50 | grep -iE "AADSTS|LLM connection"`
- **Fix:** point it at the workshop's MaaS (`adm maas show` prints your endpoint and model):

  ```bash
  oc get olsconfig cluster -o yaml > olsconfig-cluster-ORIGINAL.yaml    # gitignored; restore with oc replace -f
  oc -n openshift-lightspeed create secret generic ogsr-maas-apitoken \
    --from-literal=apitoken="$(oc -n ogsr-system get secret ogsr-maas-credentials -o jsonpath='{.data.apitoken}' | base64 -d)"
  oc patch olsconfig cluster --type merge -p '{"spec": {
    "llm": {"providers": [{"name": "MaaS", "type": "openai", "url": "https://YOUR-MAAS-ENDPOINT/v1",
            "credentialsSecretRef": {"name": "ogsr-maas-apitoken"}, "models": [{"name": "YOUR-MODEL"}]}]},
    "ols": {"defaultProvider": "MaaS", "defaultModel": "YOUR-MODEL"}}}'
  ```

- Done when the pod is `2/2`. Reload the console tab.
- The key now lives in two places. `adm maas set` updates only `ogsr-system`; update
  `openshift-lightspeed/ogsr-maas-apitoken` yourself after a rotation.

### MTA: attendees see each other's applications

Expected — one shared Hub. Attendees name theirs `parasol-legacy-claims-<user>`. `ws reset` does not
remove them; delete stale ones in the MTA console between cohorts.

### A hook Job fails immediately

- `ose-cli` OOMs at 256Mi. Give hook Jobs at least 512Mi.
- No `dnf` at runtime under the restricted SCC. Use a purpose-built image.

### parasol-web or parasol-claims never become Ready

Their images have not loaded yet. Check the ImageStreams in `ogsr-parasol-images`.

### A LoadBalancer Service stays pending

Expected. There is no MetalLB, on purpose. Everything is exposed through Routes.

---

## 6. What the install never changes

- **Operators already on the cluster** are adopted where safe — never reinstalled, upgraded or
  removed. Where adopting is not safe, ours runs alongside theirs and the install says so.
- **Cluster-wide defaults stay as they are.** (That is why the console opens in a new tab: embedding
  it would need a cluster-wide ingress change.)
- **Attendees are walled off** from the organisation's namespaces and from each other: one Argo CD
  AppProject per attendee, enforced by an admission policy.
- **Uninstall removes what we created and leaves the rest.** A CRD the owner's operators also use is
  never offered for deletion.
- Two Argo CD instances: the platform one builds every attendee's world; a second one is where
  attendees create their own Applications, so an attendee mistake cannot break the machinery.

The test for any change: *would anything of the cluster owner's differ after a full removal?*
