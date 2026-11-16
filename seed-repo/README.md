# manifests (seed repository for the lab)

A repository that manages Kubernetes manifests in the `app/<kind>/overlay/<env>/<app>/` layout.

- Placing `app.argocd.yaml` (a marker) in an overlay directory makes the ApplicationSet on the hub
  generate an Application that syncs that overlay (opt-in).
- Markers are added / removed from the demo repository with `mise marker-dev` / `mise unmark-dev` and so on.

`platform/` holds the manifests of the platform components on the hub (Gitea / Vault). These do not use
markers. Hand-written Applications (`platform.yaml` on the hub) sync them. Gitea keeps its own manifest
in this repository, a chicken-and-egg relation, so the setup script applies it directly the first time only.
