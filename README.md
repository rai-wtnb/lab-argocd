# lab-argocd

A hands-on lab for experiencing Argo CD end to end, locally. Three kind clusters reproduce a
**hub-spoke (multi-cluster) setup + mass production of Applications with the git generator**.

- One Argo CD (the hub) deploys to several destination clusters (the spokes)
- An opt-in approach where placing `app.argocd.yaml` (called a "marker" below) in the Git repository
  is all it takes to generate an Application (the git files generator of ApplicationSet)
- selfHeal / prune / AppProject boundaries / External Secrets Operator can all be tried

## The 3 clusters

```
1. kind-demo-hub (management cluster)
  ├── Argo CD (non-HA)
  ├── Gitea (the Git server that is the source for GitOps. http://localhost:3000)
  ├── Vault (the external secret store for ESO)
  ├── ApplicationSet (watches app/*/overlay/{dev,stg}/*/app.argocd.yaml)
  ├── AppProject demo (the team's project) / platform (the platform project)
  ├── hand-written Application x2 (sync gitea / vault to the hub itself = in-cluster)
  └── cluster Secret x2 (registration of spoke-dev / spoke-stg)
2. kind-demo-dev (spoke. destination cluster) ── demo-app ns + least-privilege RBAC
3. kind-demo-stg (spoke. destination cluster) ── same as above
```

Gitea and Vault are more than a foundation. They are themselves teaching material for Argo CD's **hand-written Applications** (Gitea is a chicken-and-egg case of managing the Git server itself through GitOps, so a script applies it directly the first time only and Argo CD adopts it afterwards).

## Components

| Component | What it is | Role in this lab |
|---|---|---|
| **Argo CD** | A GitOps CD tool. It keeps comparing what Git declares with the state of the real cluster and syncs the difference | Sits on the hub and deploys to the two spokes |
| **Gitea** | A lightweight self-hosted Git service (a GitHub-like UI/API in a single binary) | The source repository for GitOps. Repository creation can be scripted through the API, and a public repository can be cloned anonymously, so Argo CD needs no auth settings |
| **Vault** | HashiCorp's secret management tool (storage, dynamic issuing, auditing). dev mode is a disposable setup, in-memory with a fixed root token | The external secret store for the ESO hands-on. The lightest of ESO's official providers that runs entirely locally |
| **ESO** (External Secrets Operator) | An operator that keeps syncing values from an external store into K8s Secrets | Demonstrates the pattern "only the declaration in Git, the value in an external store" |
| **podinfo** | A small Go web app made for Kubernetes / GitOps demos (it has a UI, health checks and metrics) | The demo app `demo-app` that gets deployed. `PODINFO_UI_MESSAGE` makes the difference between environments (dev / stg) visible as text in the UI, and readyz / healthz feed Argo CD's Health assessment |
| **kind** | A tool that builds K8s clusters by treating docker containers as nodes | The three clusters (hub / spoke x2) |
| **colima** | Provides a Linux VM + docker runtime on macOS (Docker Desktop replacement) | The base kind runs on |

## Directory structure

```
├── mise.toml       # pins the tool versions; entry-point tasks (cluster-up / argocd-info / status / marker-* / pr-* / eso-up / rotate / cluster-down. List them with mise tasks)
├── docs/           # documents (prerequisites / Argo CD / CRDs / ESO / hands-on scenarios / Pull Request generator)
├── kind/           # kind config of each cluster (publishes the NodePorts of Argo CD / Gitea / demo-app to the host)
├── hub/            # what goes on the hub cluster
│   ├── argocd/     #   Argo CD itself (kustomize + helmCharts. values.yaml holds the settings)
│   ├── appproject.yaml      # the team's project demo (allowlist of sync destinations)
│   ├── platform.yaml        # the platform project: AppProject platform + hand-written Applications (gitea / vault)
│   ├── clusters.yaml        # template of the cluster registration Secret (04-spokes.sh fills in the dynamic values and the secret)
│   ├── applicationset.yaml  # reads markers and mass-produces Applications
│   └── applicationset-pr.yaml  # creates an Application per open Pull Request (pull request generator)
├── spoke/          # what goes on the destination clusters
│   ├── rbac.yaml        #   least-privilege RBAC + the ServiceAccount used to connect
│   └── eso-values.yaml  #   values for ESO (all defaults. Comments explain the defaults worth knowing)
├── seed-repo/      # the initial content of the repository on Gitea
│                   #   (app/ = base/overlay of the demo app, platform/ = the manifests of Gitea / Vault themselves)
├── scripts/        # what the setup actually runs (table below. mise cluster-up calls 00 to 06 in order)
└── .work/          # files generated at run time (the repository clone, kubeconfigs with tokens. Not tracked by git)
```

### What is in scripts/

All of them are idempotent (if one fails midway, re-running picks up where it stopped).

| Script | What it does |
|---|---|
| `00-prereqs.sh` | Checks that the required CLIs (docker / kind / kubectl / helm / jq / git / curl / htpasswd) exist and that the docker daemon is reachable. If something is missing it points to `mise install` and fails |
| `01-clusters.sh` | Creates the three kind clusters (demo-hub / demo-dev / demo-stg) from the settings in `kind/*.yaml` (the hub publishes the NodePorts of Argo CD and Gitea to the host, the spokes that of demo-app). Skips the ones that exist. Finally it pulls the podinfo image with the host's docker and loads it into the spokes (keeps a pull at Pod start from ending in ImagePullBackOff when in-cluster egress misbehaves) |
| `02-argocd.sh` | Renders `hub/argocd/` with `kubectl kustomize --enable-helm` and applies it to the hub with server-side apply (the CRDs are huge and exceed the limit of client-side apply). Waits for the rollout of every component |
| `03-gitea.sh` | Deploys Gitea to the hub (applies `seed-repo/platform/gitea/` directly = the chicken-and-egg bootstrap) -> waits for healthz -> creates the admin user `demo` -> creates the public repository `manifests` through the API -> pushes the content of `seed-repo/` to the main branch |
| `04-spokes.sh` | Applies `spoke/rbac.yaml` to each spoke -> gets the ServiceAccount token and kind's internal endpoint + CA -> fills them into `hub/clusters.yaml` (the template) and registers the cluster Secrets (`spoke-dev` / `spoke-stg`) on the hub |
| `05-bootstrap.sh` | Applies AppProject `demo`/`platform`, the hand-written Applications (`gitea`/`vault`) and ApplicationSet `managed-apps`/`pr-preview` to the hub. gitea adopts the existing resources, vault is newly created through GitOps from here. The demo side has no markers, so 0 Applications |
| `06-eso.sh` | Waits for Vault to start (the sync of Application `vault`) and seeds the initial value -> installs ESO on spoke-dev with helm (values: `spoke/eso-values.yaml`) -> creates the `vault-token` Secret the SecretStore authenticates with (re-run it on its own with `mise eso-up`) |
| `pr.sh` | For the Pull Request generator demo. Pushes a branch to Gitea and opens a PR / adds a commit / closes it / shows the state. `mise pr-open` and friends are wrappers around it (`open\|update\|close\|status`) |
| `marker.sh` | Adds / removes a marker (`app.argocd.yaml`). Clones/pulls the Gitea repository into `.work/manifests` -> generates or deletes the marker -> commit & push. `mise marker-dev` and friends are wrappers around it (`add\|remove x dev\|stg x app name`) |

## Resources per cluster

Everything that `mise cluster-up` and each step create, and in which cluster.

**kind-demo-hub (management cluster)**

| namespace | Resource | Created when |
|---|---|---|
| argocd | Argo CD (Deployment: server / repo-server / applicationset-controller / redis, StatefulSet: application-controller) + 3 CRDs | mise cluster-up |
| argocd | AppProject `demo` / `platform`, ApplicationSet `managed-apps` / `pr-preview` | mise cluster-up |
| argocd | hand-written Application `gitea` / `vault` (the destination is in-cluster = the hub itself) | mise cluster-up |
| argocd | cluster Secret `cluster-spoke-dev` / `cluster-spoke-stg` (registration of the spokes) | mise cluster-up |
| argocd | Application `demo-app` / `demo-app-stg` / `demo-secrets` (**the Application resources themselves live on the hub**. What they deploy is created on the spokes) | generated after each marker is pushed |
| gitea | Gitea (Deployment + Service NodePort 30300 + PVC). A script applies it the first time, then Application `gitea` manages it (adopt) | mise cluster-up |
| vault | Vault in dev mode (Deployment + Service NodePort 30201). Created by the sync of Application `vault` | mise cluster-up |

**kind-demo-dev (spoke)**

| namespace | Resource | Created when |
|---|---|---|
| kube-system | ServiceAccount `argocd-manager` + long-lived token Secret | mise cluster-up |
| (cluster) | ClusterRole `argocd-manager` / `argocd-app-writer` + Binding | mise cluster-up |
| demo-app | RoleBinding (grants app-writer limited to the ns) | mise cluster-up |
| demo-app | Deployment `demo-app` (replicas 2) + Service | after mise marker-dev |
| external-secrets | ESO (controller / webhook / cert-controller) | mise cluster-up |
| demo-app | `vault-token` Secret (the SecretStore authenticates with it) | mise cluster-up |
| demo-app | SecretStore `vault` + ExternalSecret `demo-app` -> generated Secret `demo-app-secret` | after mise marker-secrets |

**kind-demo-stg (spoke)**

| namespace | Resource | Created when |
|---|---|---|
| kube-system / (cluster) / demo-app | the same RBAC set as dev | mise cluster-up |
| demo-app | Deployment `demo-app` (replicas 1) + Service | after mise marker-stg |

## Endpoints / UIs

| What | URL | Auth | Notes |
|---|---|---|---|
| Argo CD UI | https://localhost:8080 | admin / the password shown by `mise argocd-info` | Always on (through kind's extraPortMappings). The self-signed certificate warning can be ignored |
| Gitea UI | http://localhost:3000 | demo / demo12345 | Always on (through kind's extraPortMappings). You can watch the marker commits pile up |
| demo-app (the podinfo UI) | dev: http://localhost:9898 / stg: http://localhost:9899 | none | Always on (through kind's extraPortMappings). After a marker is synced the page shows "hello from DEV" / "hello from STG" |
| Vault | not published to the host | root token `root` | Check the value with `mise vault-get`, update it with `mise rotate` (both go through `kubectl exec`). Between clusters it is `demo-hub-control-plane:30201` |

## Preparation

The tools are installed together with [mise](https://mise.jdx.dev/). The versions are pinned under `[tools]` in `mise.toml`.

| Tool | Purpose |
|---|---|
| colima | Local VM + docker runtime (Docker Desktop replacement) |
| docker-cli | The docker CLI (the daemon runs inside the colima VM) |
| kind | Creates three Kubernetes clusters inside the VM |
| kubectl | Operates the clusters |
| jq | JSON processing in the setup scripts |
| helm | Used to render Argo CD itself (kustomize --enable-helm) and to install ESO |

git / curl / htpasswd from macOS are fine. mise itself installs with `brew install mise`.

```bash
mise trust     # trust the mise.toml of this repository (first time only)
mise install   # install everything under [tools] in mise.toml
colima start argocd-lab --cpu 4 --memory 8 --disk 30
```

Tasks are run with `mise <task>`. `mise tasks` lists them. The long form `mise run <task>` always works too.
The short form only works while the task name is not a mise command, which is why the setup task is
`cluster-up` and not `up` (`mise up` upgrades the tools). If a later mise release adds a command that
matches a task name here, fall back to `mise run <task>`.

If mise is not hooked into your shell (no `mise activate`), prefix direct calls to `colima` or `kubectl`
with `mise exec --`, as in `mise exec -- colima start ...`.

This creates a VM under the dedicated profile `argocd-lab` (your everyday colima default is not touched).
On start, the docker context switches to `colima-argocd-lab` automatically.

## Start

```bash
mise cluster-up    # create kind x3 -> Argo CD -> Gitea + seed repo -> register spokes -> bootstrap (5-10 min)
mise argocd-info   # show the UI URL and the admin password
```

Gitea: <http://localhost:3000> (demo / demo12345)

## Hands-on

The scenarios are collected in [docs/05-handson.md](docs/05-handson.md)
(part 1: basics / part 2: experiments / part 3: "what if" extensions).

The demo that creates an environment per Pull Request is in [docs/06-pr-generator.md](docs/06-pr-generator.md).

## How this lab differs from production

The lab is simplified to stay self-contained. The pieces that change in production:

| Element | This lab | Common in production |
|---|---|---|
| Auth for cluster registration | ServiceAccount bearer token (**a real secret. Never commit it**) | Cloud IAM integration (on GKE, Connect Gateway + Workload Identity) removes the secret from the cluster Secret |
| Git repository | Gitea in the cluster (public repo, no auth) | GitHub etc. + repo-creds with an App / deploy key |
| Managing Argo CD itself | The Helm chart is rendered with kustomize and a script applies it | The same rendering + self-management (Argo CD keeps syncing itself) |
| How fast a marker takes effect | Polling (30 seconds to 3 minutes) | Git webhook (immediate) + polling (fallback) |
| Destination RBAC | wildcard app-writer | Least privilege listing the resource kinds that get deployed |
| External secret store | Vault in dev mode | A cloud secret manager + IAM auth |

## Cleanup

```bash
mise cluster-down         # delete the three kind clusters and .work
colima stop argocd-lab    # stop the VM
colima delete argocd-lab  # to delete the VM entirely
```
