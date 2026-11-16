# Hands-on scenarios

This assumes `mise cluster-up` is done. Three parts:

- **Part 1 (basics)**: one pass through the basic behaviour of GitOps
- **Part 2 (experiments)**: experiments that dig into how Argo CD behaves. All of them can be done in this lab
- **Part 3 (extensions)**: explanations of "what would it take to ...". Reading only (nothing is actually done)

Keeping three views open as you go makes the changes easy to follow:
Argo CD UI (https://localhost:8080) / Gitea (http://localhost:3000) / podinfo (http://localhost:9898)

---

## Part 1: basic scenarios

### 1. Proving it is opt-in

- **Goal**: Confirm that Applications are generated only for the markers that exist
- **Steps**: Open the Argo CD UI
- **Observe**: The only Applications are the two of the platform project, `gitea` / `vault` (hand-written Applications. `hub/platform.yaml`), and the demo project has 0. AppProject `demo` and ApplicationSet `managed-apps` exist, yet there is no Application. The machinery is waiting and has no input (markers)

### 2. Generate with a marker -> sync

- **Goal**: Experience "pushing a single file deploys an app"
- **Steps**: `mise marker-dev` -> see the commit land in Gitea -> watch the UI and wait (30 seconds to 3 minutes)
- **What gets placed**: `scripts/marker.sh` generates the following as
  `app/web/overlay/dev/demo-app/app.argocd.yaml` and pushes it
  (you can see the real file in the Gitea UI or in `.work/manifests/`):
  ```yaml
  # Marker read by the files generator of the ApplicationSet (hub/applicationset.yaml)
  name: demo-app       # Application name (unique within the hub)
  team: demo           # owning team (becomes a label)
  project: demo        # the AppProject it belongs to
  namespace: demo-app  # destination namespace
  env: dev             # used to resolve the destination cluster (spoke-<env>)
  ```
- **Observe**:
  - The Application `demo-app` appears and moves OutOfSync -> Syncing -> **Synced / Healthy**
  - The tree view shows the Deployment / Service / Pods hanging off it (the parent-child relation of resources)
  - `kubectl --context kind-demo-dev -n demo-app get pods` shows the real thing on the spoke
  - http://localhost:9898 shows "hello from DEV"

### 3. selfHeal: manual changes are reverted

- **Goal**: See the force behind "Git is the single source of truth"
- **Steps**:
  ```bash
  kubectl --context kind-demo-dev -n demo-app scale deploy/demo-app --replicas=5
  watch kubectl --context kind-demo-dev -n demo-app get deploy
  ```
- **Observe**: Within tens of seconds replicas goes back to 2. The Application events in the UI keep a record of the sync.
  This is what it feels like when operating by poking the cluster directly no longer works

### 4. A change through Git is the only way to change

- **Goal**: Experience the proper change flow (edit -> push -> reflected automatically)
- **Steps**: In `.work/manifests/app/web/overlay/dev/demo-app/kustomization.yaml`, change
  `replicas: 2` to `3`, then commit & push (or change the text of the message)
- **Observe**: After the poll it is synced and the Pods grow to 3 (if you changed the message, the text
  in the podinfo UI changes. It is a change to the Deployment's env, so the Pods are recreated)

### 5. Rolling out to stg, and unique Application names

- **Goal**: Learn how to design names when one hub manages several environments
- **Steps**: `mise marker-stg`
- **Observe**: The Application is generated under a **different name**, `demo-app-stg`, and synced to spoke-stg
  ("hello from STG" at http://localhost:9899). Application names are unique within one Argo CD, so
  environments that live side by side need the environment woven into the name (`name` in the marker is where it goes)

### 6. AppProject boundaries: restricting the destination

- **Goal**: Confirm that AppProject stops a deployment that crosses the boundary
- **Steps**: In `.work/manifests`, rewrite `namespace: demo-app` in the dev marker to `namespace: default`
  and push
- **Observe**: The Application hits a sync error (`destination ... is not permitted in project demo`).
  A destination that is not in the destinations allowlist of the AppProject is never synced, whatever the manifests say.
  Afterwards, put `namespace: demo-app` back and push (recovery goes through Git too)

### 7. prune: removing the marker = removing the app

- **Goal**: Grasp "what is removed from Git is removed for real", and why a revert is a rollback
- **Steps**: `mise unmark-dev`
- **Observe**: The whole Application `demo-app` disappears, and the Deployment / Pods on spoke-dev are deleted.
  http://localhost:9898 stops responding. Put the other way round, reverting the commit that made the switch
  restores the previous state completely. That is rollback in GitOps

### 8-10. ESO: shipping secrets without putting them in Git

The foundation (Vault = the external store, ESO) is already installed by `mise cluster-up`.

```bash
mise marker-secrets  # 8. ship the ExternalSecret as a "second marker app"
kubectl --context kind-demo-dev -n demo-app get secret demo-app-secret -o jsonpath='{.data.message}' | base64 -d
                     # 9. check the value of the generated Secret (=> s3cr3t-from-vault-v1)
mise rotate v2       # 10. update the source of truth (Vault) -> the Secret follows after refreshInterval (15s)
```

- **Observe**:
  - The K8s Secret is generated and updated while the secret value appears nowhere in Git (details in [04-eso.md](04-eso.md))
  - One marker file grew a second app = the mass-production machinery again (`app/secrets/` is a
    different directory from `app/web/`, but the generator's glob picks it up automatically)
  - A point to watch: on Argo CD the ExternalSecret can end up **permanently OutOfSync because of CRD schema defaults**.
    Adding the annotation `argocd.argoproj.io/compare-options: ServerSideDiff=true`
    to the ApplicationSet template resolves it
    (a demonstration of why ServerSideDiff is recommended in production)

---

## Part 2: experiments (digging into the behaviour)

### A. Synced and Healthy are independent

- **Goal**: Learn that "applied exactly as in Git (Synced)" and "the app is well (Healthy)" are different things
- **Steps**: In `.work/manifests/app/web/overlay/dev/demo-app/kustomization.yaml`,
  add an override to an image tag that does not exist and push:
  ```yaml
  images:
    - name: ghcr.io/stefanprodan/podinfo
      newTag: 0.0.0-broken
  ```
- **Observe**: The sync succeeds and it becomes **Synced**, but the Pods go into ImagePullBackOff and it
  drops to **Progressing -> Degraded**. A concrete case of "Synced" not meaning "safe"
- **Recover**: `git -C .work/manifests revert HEAD --no-edit && git -C .work/manifests push`
  -> the revert commit is synced and it returns to Healthy (putting "revert = rollback" from part 1, scenario 7 into practice)

### B. A generated Application cannot be edited by hand

- **Goal**: Experience the ownership of an ApplicationSet (policy in the template, data in the marker)
- **Steps**: Try rewriting the generated object directly:
  ```bash
  kubectl --context kind-demo-hub -n argocd patch application demo-app --type merge \
    -p '{"spec":{"source":{"path":"app/web/overlay/stg/demo-app"}}}'
  kubectl --context kind-demo-hub -n argocd get application demo-app -o jsonpath='{.spec.source.path}' -w
  ```
- **Observe**: applicationset-controller reverts it to the value in the template.
  The same structure as selfHeal (which protects the resources on the spoke) applies to the Application resource itself.
  To change it, the only way is to change the marker or the template

### C. Cause a name collision

- **Goal**: Safely confirm what happens when Application names collide within the hub
- **Steps**: In `.work/manifests`, rewrite `name: demo-app-stg` in the stg marker to `name: demo-app`
  and push (while the dev marker is alive)
- **Observe**: The ApplicationSet detects the duplicate, and the status conditions of `kubectl --context kind-demo-hub -n argocd describe
  applicationset managed-apps` record an error.
  One definition wins and the other is not applied (which one wins is not guaranteed, which is why you prevent it by design)
- **Recover**: Put `name: demo-app-stg` back and push

### D. The difference between Refresh / Hard Refresh / Sync

- **Goal**: Know exactly what the buttons in the UI mean
- **Steps**: Open an Application in the UI, press each and watch what happens

| Operation | What it does | When to use it |
|---|---|---|
| Refresh | Re-reads Git, renders, and recomputes the diff (no apply) | When you pushed but do not see it reflected |
| Hard Refresh | Discards the render cache, then Refresh | When the kustomize output looks off |
| Sync | Applies the diff | When you want it reflected now instead of waiting for automated |

- **Note**: This lab uses automated sync + shortened polling (20-30 seconds), so the buttons are normally not needed.
  In production the norm is to wire a Git webhook for an immediate, push-driven Refresh (part 3, X6)

### E. Argo CD RBAC (policy.csv): the permission boundary on the human side

- **Goal**: Experience the authorization of "what a human can do in the Argo CD UI/API",
  a different layer from K8s RBAC (the permissions of whoever executes the sync)
- **Background**: Permissions are defined in `policy.csv` of `argocd-rbac-cm` (Casbin format):
  ```
  p, role:team-demo, applications, sync, demo/*, allow   # p line: a permission for a role (limited to project demo)
  g, demo-dev, role:team-demo                            # g line: assigns a user to a role
  ```
  The default is deny (policy.default is empty), and only admin is a superuser that bypasses RBAC
- **Steps**: Open https://localhost:8080 in a private window and
  log in as **demo-dev / demo12345** (the local account defined in `hub/argocd/values.yaml`)
  1. The Application list, details and logs are **visible** (get / logs allowed)
  2. The Sync button -> **succeeds** (sync allowed)
  3. Delete -> **permission denied** (delete is not allowed)
  4. `gitea` / `vault` of the platform project **do not show in the list** (the permission is limited to `demo/*`, so
     other projects are not even visible)
- **Observe**: Next to an admin tab, the same screen has different buttons you can press.
  In production the norm is to make the subject of this `g` line an SSO (IdP) team or group instead of a local user,
  building the multi-tenant boundary "team X can only touch the Applications of project X"

### F. A failed automatic sync is not retried on the same revision

- **Goal**: Learn where "with automated + selfHeal everything fixes itself" stops being true
- **Steps**: Delete Vault of the platform project together with its namespace
  ```bash
  kubectl --context kind-demo-hub delete ns vault
  ```
- **Observe**: selfHeal starts a sync right away, but it can race with the termination of the ns and
  fail to create the Deployment/Service with `namespaces "vault" not found`.
  The few retries then re-apply **only the failed tasks**
  (the Namespace, counted as succeeded, is not recreated), so the failure becomes final, and after that
  **the automatic sync is not retried for the same revision**. The app stays stuck in SyncError
- **Recover**: A manual sync (the Sync button in the UI) starts a new operation and fixes it in one go.
  `mise eso-up` works too (the script does the same with an operation patch through kubectl and
  also re-seeds the initial value in Vault. Vault in dev mode is in-memory, so the value is gone when the pod is gone)
- **Lesson**: What triggers a retry of the automatic sync is "a new commit" or "a new change in the live state".
  Once it has stopped on a failure, a human (or a new commit) has to start an operation

---

## Part 3: extensions (explanation only. Nothing is actually done)

### X1. To add a spoke cluster

For each new destination cluster, five gates have to be opened:

1. **Connection**: place a cluster registration Secret (`argocd.argoproj.io/secret-type: cluster`) on the hub.
   name / server URL / auth (an SA token in this lab, IAM integration in production)
2. **Write permission**: lay down RBAC on the destination cluster for argocd-manager (read + Namespace) and
   app-writer (write on the kinds of the apps)
3. **Allowance**: add "new cluster x namespace" to the destinations of the AppProject
4. **Discovery**: can the ApplicationSet read the markers of that environment (the generator of this lab
   lists the dev / stg paths, so a new environment needs a path added. See X4)
5. **Naming**: decide a naming scheme that keeps Application names unique within the hub

In this lab `hub/clusters.yaml` + `scripts/04-spokes.sh` + `hub/appproject.yaml` correspond to this set.
If any one of the checks is missing, it stops with a **different symptom** each time: "not generated / sync denied /
resources invisible / apply forbidden". Being able to work back from the symptom to the missing gate is a real strength.

### X2. To add an app

1. On the seed-repo side, create `app/<kind>/base/<new app>/` and `app/<kind>/overlay/<env>/<new app>/`
2. If it goes in a different namespace: add the namespace to the destinations of the AppProject and to the RoleBinding on the spoke
   (staying in the demo-app namespace means zero platform changes)
3. Place a marker. That is all

The aim of the mass-production machinery is that "the cost of adding an app approaches one marker file".
In fact `demo-secrets` (ESO) in this lab is a real example of a second app.

### X3. To add a target directory (app/<kind>)

**Nothing needs to be done**. The path of the generator is `app/*/overlay/dev/*/app.argocd.yaml`, with
wildcards, so newly created `app/api/` or `app/batch/` are picked up automatically.
A real example: `app/web/` (demo-app) and `app/secrets/` (demo-secrets) in this lab
coexist without touching the ApplicationSet at all.
This is a glob design meant to keep the platform untouched when things are added. The trade-off is that
once you want to narrow the targets, you change the paths into an explicit list.

### X4. To add an environment (prod)

On top of X1 (adding a cluster):

1. Add `app/*/overlay/prod/*/app.argocd.yaml` to files of the ApplicationSet
   (the env paths are listed explicitly. The design says adding an environment should be a deliberate act)
2. Destination resolution (`spoke-{{ .env }}`) is driven by the env field, so the template does not change
3. To make only production behave differently (for example, dropping automated for a manual Sync),
   since the template is shared by every app, you end up splitting the ApplicationSet per environment.
   The norm is "when the shape diverges, split the ApplicationSet"

### X5. To make the repository private

If the Gitea repository is made private, Argo CD can no longer clone it. The remedy is to
place a Secret of `argocd.argoproj.io/secret-type: repository` (a single repository) or `repo-creds`
(an auth template per URL prefix) on the hub.
Details are in the section on registry Secrets in [03-argocd-crds.md](03-argocd-crds.md).

### X6. To get immediate, push-driven updates

To Refresh right on push instead of waiting for the poll, wire two webhooks from the Git server:

1. For refreshing Applications: `https://<argocd-server>/api/webhook`
2. For the ApplicationSet (marker detection): the webhook of applicationset-controller (port 7000)

This lab substitutes shortened polling intervals (`timeout.reconciliation` / requeue).

### X7. To add notifications

Enable notifications-controller (disabled in the values of this lab),
configure triggers (on-sync-failed etc.) and templates (the messages), and then
subscribe with an annotation on the Application (`notifications.argoproj.io/subscribe.<trigger>.<service>: <recipient>`).
Through an ApplicationSet, putting it in annotations of the template subscribes every app at once.
The operational norm is "notify failures only (silent when healthy)". Notifying every event always turns into noise.

### X8. The remaining gap to production

For the differences between this lab and a production setup, see the table "How this lab differs from production" in the README.
The three biggest:

- **Secretless auth**: SA token -> cloud IAM integration (the secret disappears from the cluster Secret)
- **Self-management**: Argo CD itself is managed as an Argo CD Application too, and
  upgrades of Argo CD itself ride on GitOps (the app-of-apps pattern)
- **SSO (IdP integration)**: the team boundary by `policy.csv` itself was experienced in scenario E. What changes in production is
  that the subject of the `g` line is replaced from a local user (demo-dev) with an IdP team or group, and
  that admin login and local accounts are disabled
