#!/usr/bin/env bash
# ESO デモ用の追加セットアップ:
#   1. hub の Vault (dev モード) の起動を待って初期値を投入
#      (配置自体は GitOps: hub/platform.yaml の Application `vault` が行う)
#   2. spoke-dev に External Secrets Operator を helm で導入
#   3. SecretStore の認証用 vault-token Secret を demo-app ns に作成
# この後 `make marker-secrets` で ExternalSecret を GitOps 経由で配ると Secret が生成される。
set -euo pipefail
cd "$(dirname "$0")/.."
HUB=kind-demo-hub
DEV=kind-demo-dev

if ! command -v helm >/dev/null 2>&1; then
  echo "NG: helm が見つからない (brew install helm)。ESO は helm チャートのみで配布されているためこのステップだけ helm が必要"
  exit 1
fi

echo '== Vault の起動待ち (Application vault の sync が作る。hub/platform.yaml) =='
for i in $(seq 1 60); do
  kubectl --context $HUB -n vault get deploy/vault >/dev/null 2>&1 && break
  # 30 秒ごとに sync を蹴り直す。自動 sync は同一リビジョンで一度失敗すると再試行しない
  # (例: ns 削除の直後に走った sync が終了処理と競合して Failed で止まる) ための保険
  if [ $((i % 6)) -eq 0 ]; then
    kubectl --context $HUB -n argocd patch application vault --type merge \
      -p '{"operation":{"initiatedBy":{"username":"06-eso.sh"},"sync":{"revision":"HEAD"}}}' \
      >/dev/null 2>&1 || true
  fi
  sleep 5
done
kubectl --context $HUB -n vault rollout status deployment/vault --timeout=180s

echo "== Vault に初期値を投入 (secret/demo-app message=...) =="
kubectl --context $HUB -n vault exec deploy/vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root \
  vault kv put secret/demo-app message="s3cr3t-from-vault-v1"

echo "== ESO を spoke-dev へ (helm) =="
helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo update external-secrets >/dev/null
# 初回はイメージ pull で時間がかかることがあるため timeout は長めに取る
helm upgrade --install external-secrets external-secrets/external-secrets \
  --kube-context $DEV --namespace external-secrets --create-namespace --wait --timeout 10m \
  -f spoke/eso-values.yaml

echo "== SecretStore の認証用 token を demo-app ns に作成 =="
# クラウドの IAM 連携 (Workload Identity 等) なら不要になる部品 (ラボの token 認証代替)
kubectl --context $DEV create namespace demo-app --dry-run=client -o yaml | kubectl --context $DEV apply -f -
kubectl --context $DEV -n demo-app create secret generic vault-token \
  --from-literal=token=root --dry-run=client -o yaml | kubectl --context $DEV apply -f -

echo ""
echo "OK: ESO 準備完了。次:"
echo "  make marker-secrets   # ExternalSecret を GitOps で配る"
echo "  kubectl --context $DEV -n demo-app get secret demo-app-secret -o jsonpath='{.data.message}' | base64 -d"
echo "  make rotate MSG=new-value   # Vault の値を更新 → refreshInterval(15s) 後に Secret が追随"
