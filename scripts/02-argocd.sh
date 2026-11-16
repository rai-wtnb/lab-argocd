#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
HUB=kind-demo-hub

# Render the argo-cd chart with kustomize's helmCharts feature (--enable-helm) and apply it.
# Settings such as the shorter polling interval live in hub/argocd/values.yaml.
# The CRDs are huge and exceed the annotation limit of client-side apply (256KiB), hence server-side apply.
kubectl kustomize --enable-helm hub/argocd \
  | kubectl --context $HUB apply --server-side --force-conflicts -f -

echo "Waiting for the rollout..."
kubectl --context $HUB -n argocd rollout status deployment/argocd-repo-server --timeout=300s
kubectl --context $HUB -n argocd rollout status deployment/argocd-server --timeout=300s
kubectl --context $HUB -n argocd rollout status deployment/argocd-applicationset-controller --timeout=300s
kubectl --context $HUB -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

# Set the password of demo-dev, the local account for the RBAC demo (pairs with accounts.demo-dev in values.yaml)
hash=$(htpasswd -nbBC 10 "" demo12345 | tr -d ':\n' | sed 's/^\$2y/\$2a/')
kubectl --context $HUB -n argocd patch secret argocd-secret --type merge \
  -p "{\"stringData\":{\"accounts.demo-dev.password\":\"$hash\"}}"

echo "OK: Argo CD is up (RBAC demo account: demo-dev / demo12345)"
