# Pull Request generator: an environment per PR

This assumes `mise cluster-up` is done. With the pull request generator of ApplicationSet, it confirms that
one Application is created per open PR and removed when the PR is closed.

Official documentation: <https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Pull-Request/>

## How it works

```
Gitea (demo/manifests)                 hub                                   spoke-dev (ns demo-app)
  PR #1 preview/blue ──┐   ApplicationSet pr-preview                    Deployment demo-app-pr-1
  PR #2 preview/green ─┼─▶  fetches the PR list via the API every 30s ─▶ Deployment demo-app-pr-2
                       │    generates an Application per PR
  main ────────────────┘    (demo-app-pr-1 / demo-app-pr-2)             Deployment demo-app (main. marker approach)
```

The definition is in `hub/applicationset-pr.yaml`. There are three key points.

- The input of the generator is the list of PRs returned by the Git server's API, not files in Git.
  The Gitea provider fetches only open PRs.
- `targetRevision: '{{ .head_sha }}'` syncs the head commit of the PR.
  When a commit is added to the PR, `head_sha` changes and the Application is rewritten.
- They sit in the same namespace as main's `demo-app`, so `nameSuffix` and `commonLabels`
  change the names and labels per PR.

The generator does not build images. This demo only changes the settings of a public image (podinfo) in the PR.
For a PR that changes application code, CI pushes an image tagged with the commit SHA and
the template sets the same tag with `kustomize.images`.

## Steps

Keeping three views open makes the changes easy to follow.
Argo CD UI (https://localhost:8080) / the PR list in Gitea (http://localhost:3000/demo/manifests/pulls) / `watch mise pr-status`

### 1. Opening a PR creates an Application

```bash
mise pr-open blue
```

`scripts/pr.sh` creates the branch `preview/blue`, changes the UI message of the dev overlay to
`hello from PR blue`, pushes it, and opens a PR through the Gitea API.

- In about 30 seconds the Application `demo-app-pr-1` appears and becomes Synced / Healthy.
- The Deployment `demo-app-pr-1` and the Service `demo-app-pr-1` appear on spoke-dev.
- Look at the UI. Port-forward in another terminal and open http://localhost:9900.

  ```bash
  mise pr-forward 1
  ```

- Look at the generated Application. `targetRevision` is a commit SHA.

  ```bash
  kubectl --context kind-demo-hub -n argocd get application demo-app-pr-1 -o yaml
  ```

### 2. Adding a commit to the PR is followed

```bash
mise pr-update blue
```

- REVISION in `mise pr-status` changes to the new commit SHA.
- The Pod is recreated and the UI message gets a timestamp. The port-forward drops when the Pod is replaced, so start it again.

### 3. Two PRs side by side

```bash
mise pr-open green
mise marker-dev      # to also have main's demo-app alongside
```

- One Application is created per PR.
- With `kubectl --context kind-demo-dev -n demo-app get deploy,svc,pods --show-labels`, confirm that
  the value of the label `app` differs per PR and that each Service selects only its own Pods.

### 4. Closing a PR removes it

```bash
mise pr-close blue
```

- In about 30 seconds the Application `demo-app-pr-1` is removed, and so are the Deployment and the Service.
- `green` and main's `demo-app` remain.
- Merging the PR in the Gitea UI removes it in the same way. In that case the change lands in main, and
  the marker-based `demo-app` syncs main and picks it up.

## Experiments worth trying

- Make it opt-in by label. Uncomment `labels` in `hub/applicationset-pr.yaml` and apply.
  Create the label `preview` in Gitea and confirm that only PRs carrying it get an Application.

  ```bash
  kubectl --context kind-demo-hub apply -f hub/applicationset-pr.yaml
  ```

- Remove `commonLabels` and apply. Confirm with
  `kubectl --context kind-demo-dev -n demo-app get endpointslices` that main's Service `demo-app` also selects the Pods of the PR.
  This shows why the selectors must be separated when sharing a namespace.
- Delete the ApplicationSet. Running `kubectl --context kind-demo-hub -n argocd delete applicationset pr-preview`
  removes every generated Application and its deployed resources. `mise cluster-up` or an apply brings them back.

## How this demo differs from production

| Element | This demo | Common in production |
|---|---|---|
| Git server | Gitea (public repository, no token) | GitHub + `tokenRef` or `appSecretName` (GitHub App) |
| Detecting PRs | Polling every 30 seconds | Immediate with a webhook + polling (the default is 30 minutes) |
| What a PR changes | Only manifest settings | Application code. CI pushes an image tagged with the commit SHA |
| Placement | Shares main's namespace under a different name | Often a namespace per PR |
| Access | port-forward | A hostname per PR, or header-based routing |
