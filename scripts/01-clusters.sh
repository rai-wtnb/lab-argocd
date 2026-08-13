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
