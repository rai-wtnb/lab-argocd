#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
HUB=kind-demo-hub

kubectl --context $HUB apply -f hub/appproject.yaml
kubectl --context $HUB apply -f hub/platform.yaml
kubectl --context $HUB apply -f hub/applicationset.yaml

echo "OK: AppProject demo/platform + 手書き Application (gitea/vault) + ApplicationSet managed-apps を適用"
echo "    demo 側はマーカーが無いので Application 0 件のはず (opt-in の証明に使える)"
echo "    platform 側は gitea (既存を adopt) と vault (ここから GitOps で新規作成) の 2 件"
kubectl --context $HUB -n argocd get applications 2>/dev/null || true
