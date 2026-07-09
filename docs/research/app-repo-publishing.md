# Publishing an app/config repo into the in-cluster Gitea

How to publish a standalone repository into the workshop's in-cluster Gitea under the
`parasol` org, so that per-user entry-state fork jobs can fork it. Written from the M04
`claims-config-template` publish (2026-07-09, Gitea 1.26.4); the same procedure applies to any
app or config repo that needs a canonical upstream in Gitea (M02's `parasol-claims` /
`parasol-notifications` sources, future config templates, etc.).

## When to use this

The workshop mirrors this monorepo into Gitea as `parasol/ocp-getting-started` (the
git-localize flow). But some artifacts need to live as their **own** Gitea repo so attendees
can fork *just that repo* — e.g. M04's promotion template, which each user forks to
`{user}/claims-config`. Those repos are published **once** by a builder/platform step; the
entry-state fork job then forks them per user (see `gitops/entry-states/mNN/templates/gitea-fork.yaml`).

## Prerequisites

- Admin kubeconfig for the cluster (`~/.kube/ocp-ws-revamped.config`).
- The in-cluster Gitea is up (`oc get route gitea -n gitea`).
- Local `git` (laptop) or any pod with `git`/`curl`.

## Step 1 — discover the Gitea host and admin credentials

The admin password is on the Gitea CR status (authoritative) with the admin Secret as a
fallback — the same discovery the fork jobs use:

```sh
export KUBECONFIG=~/.kube/ocp-ws-revamped.config
GITEA_NS=gitea
HOST="$(oc get route gitea -n $GITEA_NS -o jsonpath='{.spec.host}')"
ADMIN_USER="$(oc get gitea gitea -n $GITEA_NS -o jsonpath='{.spec.giteaAdminUser}' 2>/dev/null || echo gitea-admin)"
ADMIN_PASS="$(oc get gitea gitea -n $GITEA_NS -o jsonpath='{.status.adminPassword}' 2>/dev/null || true)"
[ -z "$ADMIN_PASS" ] && ADMIN_PASS="$(oc get secret gitea-admin-credentials -n $GITEA_NS -o jsonpath='{.data.password}' | base64 -d)"
```

Never print or commit these. Keep them in a root-only temp file if you need them across steps.

## Step 2 — create the (empty) repo via the admin API

Idempotent: check for existence first (HTTP 200 = already there), else create under the org
with `auto_init: false` so the first push defines `main`:

```sh
curl -ks -u "${ADMIN_USER}:${ADMIN_PASS}" -X POST "https://${HOST}/api/v1/orgs/parasol/repos" \
  -H 'Content-Type: application/json' \
  -d '{"name":"claims-config-template","private":false,"default_branch":"main","auto_init":false}'
```

## Step 3 — push the content

`git push` with credentials embedded in the URL is simplest (the URL is not persisted). Use a
throwaway repo so you never touch the project's `.git` or `~/.gitconfig` (`-c` flags keep the
identity local):

```sh
PUB=$(mktemp -d); cp -R gitops/promotion/claims-config-template/. "$PUB"/
cd "$PUB"
git init -q -b main
git -c user.email="workshop@parasol.local" -c user.name="Parasol Workshop" add -A
git -c user.email="workshop@parasol.local" -c user.name="Parasol Workshop" commit -q -m "Initial import"
git push -q "https://${ADMIN_USER}:${ADMIN_PASS}@${HOST}/parasol/claims-config-template.git" main
```

Alternative (no local git): push each file via the contents API
(`PUT /api/v1/repos/parasol/<repo>/contents/<path>` with base64 `content`) — see the fork
job's personalization step for the pattern. `git push` is faster for more than a couple of files.

## Step 4 — verify

```sh
curl -ksf "https://${HOST}/api/v1/repos/parasol/claims-config-template/git/trees/main?recursive=true" \
  | python3 -c "import sys,json;[print(e['path']) for e in json.load(sys.stdin)['tree'] if e['type']=='blob']"
```

## Fork API notes (Gitea 1.26.4)

- Fork with a **rename**: `POST /api/v1/repos/{org}/{repo}/forks` accepts `{"name":"<new-name>"}`
  in the body (verified in the swagger `CreateForkOption`), so `parasol/claims-config-template`
  forks to `{user}/claims-config`.
- Fork **as a user**: add the `Sudo: {user}` header (admin impersonation) so the fork lands in
  the user's account and is authored by them.
- Forking is **async** (HTTP `202`); poll `GET /repos/{user}/{repo}` until `200` before doing
  anything with the fork (e.g. personalizing files).
- The tools image `registry.redhat.io/openshift4/ose-cli:latest` has `oc`, `curl`, `python3`,
  `base64`, `sed` — but **no `jq` and no `git`**. Personalization that edits files in a fork must
  use the contents API with `python3` (stdlib `urllib`), not `git`.

## Published repos (running record)

| Repo | Published | For | Forked to |
|---|---|---|---|
| `parasol/claims-config-template` | 2026-07-09 (M04 build) | M04 promotion template (base + dev/stage/prod overlays) | `{user}/claims-config` (personalized: `__user__` → `{user}` in overlay namespaces) |
