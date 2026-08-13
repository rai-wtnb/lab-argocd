#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
HUB=kind-demo-hub
mkdir -p .work

for env in dev stg; do
  ctx="kind-demo-$env"
  echo "== spoke-$env: RBAC 適用 =="
  kubectl --context "$ctx" apply -f spoke/rbac.yaml

  echo "== spoke-$env: SA token 待ち =="
  token=""
  for i in $(seq 1 30); do
    token=$(kubectl --context "$ctx" -n kube-system get secret argocd-manager-token \
      -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
    [ -n "$token" ] && break
    sleep 2
  done
  [ -n "$token" ] || { echo "NG: token が取得できない"; exit 1; }

  # kind の内部エンドポイント (同一 docker ネットワーク上のコンテナ名) と CA を取得
  kind get kubeconfig --name "demo-$env" --internal > ".work/kubeconfig-$env"
  server=$(kubectl --kubeconfig ".work/kubeconfig-$env" config view --raw -o jsonpath='{.clusters[0].cluster.server}')
  cadata=$(kubectl --kubeconfig ".work/kubeconfig-$env" config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

  echo "== spoke-$env: hub へクラスタ登録 (server=$server) =="
  # ArgoCD の宣言的クラスタ登録 (argocd.argoproj.io/secret-type: cluster)。
  # 認証は bearer token (ラボ用) のためこの Secret は本物の秘密を含む (git にコミットしない)。
  # クラウドの IAM 連携 (execProviderConfig) にすると秘密レスにできる。
  config=$(jq -nc --arg t "$token" --arg ca "$cadata" \
    '{bearerToken:$t, tlsClientConfig:{insecure:false, caData:$ca}}')
  kubectl --context $HUB -n argocd apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cluster-spoke-$env
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: spoke-$env
  server: $server
  config: |
    $config
EOF
done

echo "OK: spoke-dev / spoke-stg 登録完了"
