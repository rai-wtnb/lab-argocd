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
  # Secret の形 (登録簿の構造) は hub/clusters.yaml を参照。ここは値を埋めて apply するだけ。
  # 認証は bearer token (ラボ用) のため出来上がった Secret は本物の秘密を含む (git にコミットしない)。
  config=$(jq -nc --arg t "$token" --arg ca "$cadata" \
    '{bearerToken:$t, tlsClientConfig:{insecure:false, caData:$ca}}')
  sed -e "s|__ENV__|$env|g" \
      -e "s|__SERVER__|$server|g" \
      -e "s|__CONFIG__|$config|g" \
      hub/clusters.yaml | kubectl --context $HUB -n argocd apply -f -
done

echo "OK: spoke-dev / spoke-stg 登録完了"
