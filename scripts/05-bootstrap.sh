#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
HUB=kind-demo-hub

kubectl --context $HUB apply -f hub/appproject.yaml
kubectl --context $HUB apply -f hub/platform.yaml
kubectl --context $HUB apply -f hub/applicationset.yaml
kubectl --context $HUB apply -f hub/applicationset-pr.yaml

echo "OK: applied AppProject demo/platform + hand-written Applications (gitea/vault) + ApplicationSet managed-apps / pr-preview"
echo "    demo has no markers and no PRs yet, so it should have 0 Applications (this shows it is opt-in)"
echo "    platform has 2: gitea (adopts the existing one) and vault (newly created through GitOps from here)"
kubectl --context $HUB -n argocd get applications 2>/dev/null || true
