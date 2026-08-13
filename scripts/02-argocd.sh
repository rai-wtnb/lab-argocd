#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
HUB=kind-demo-hub

# kustomize の helmCharts 機構 (--enable-helm) で argo-cd チャートを展開して適用する。
# ポーリング短縮などの設定は hub/argocd/values.yaml 側にある。
# CRD が巨大で client-side apply の annotation 上限 (256KiB) を超えるため server-side apply。
kubectl kustomize --enable-helm hub/argocd \
  | kubectl --context $HUB apply --server-side --force-conflicts -f -

echo "rollout 待ち..."
kubectl --context $HUB -n argocd rollout status deployment/argocd-repo-server --timeout=300s
kubectl --context $HUB -n argocd rollout status deployment/argocd-server --timeout=300s
kubectl --context $HUB -n argocd rollout status deployment/argocd-applicationset-controller --timeout=300s
kubectl --context $HUB -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

# RBAC デモ用ローカルアカウント demo-dev のパスワードを設定 (values.yaml の accounts.demo-dev と対)
hash=$(htpasswd -nbBC 10 "" demo12345 | tr -d ':\n' | sed 's/^\$2y/\$2a/')
kubectl --context $HUB -n argocd patch secret argocd-secret --type merge \
  -p "{\"stringData\":{\"accounts.demo-dev.password\":\"$hash\"}}"

echo "OK: ArgoCD 起動 (RBAC デモ用アカウント: demo-dev / demo12345)"
