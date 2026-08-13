#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

existing=$(kind get clusters 2>/dev/null || true)

if ! grep -qx "demo-hub" <<<"$existing"; then
  kind create cluster --name demo-hub --config kind/hub.yaml
else
  echo "skip: demo-hub は作成済み"
fi

for env in dev stg; do
  if ! grep -qx "demo-$env" <<<"$existing"; then
    kind create cluster --name "demo-$env" --config "kind/$env.yaml"
  else
    echo "skip: demo-$env は作成済み"
  fi
done

kubectl --context kind-demo-hub get nodes

# デモアプリのイメージを spoke へ先読み込みする。
# Pod 起動時の pull はノードコンテナ内からの egress に依存し、colima の NAT 不調で
# ImagePullBackOff になる事例があるため、ホスト側 docker で pull して搬入しておく。
# (`kind load docker-image` は provenance 付き multi-arch index の blob 欠落で
#  ctr import --all-platforms が失敗するため、docker save | ctr import を直接使う)
PODINFO_IMG=$(grep -o 'ghcr.io/stefanprodan/podinfo:[0-9.]*' seed-repo/app/web/base/demo-app/deployment.yaml | head -1)
echo "== $PODINFO_IMG を pull して spoke へ搬入 =="
# タグ固定なのでキャッシュ済みなら pull しない (egress が不安定でも進めるように)
if docker image inspect "$PODINFO_IMG" >/dev/null 2>&1; then
  echo "skip: ホスト側にキャッシュ済み"
else
  docker pull "$PODINFO_IMG"
fi
for env in dev stg; do
  if docker exec "demo-$env-control-plane" crictl inspecti "$PODINFO_IMG" >/dev/null 2>&1; then
    echo "skip: demo-$env には搬入済み"
  else
    docker save "$PODINFO_IMG" | docker exec -i "demo-$env-control-plane" \
      ctr --namespace=k8s.io images import --digests - >/dev/null
    echo "OK: demo-$env へ搬入"
  fi
done
