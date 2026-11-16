#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

existing=$(kind get clusters 2>/dev/null || true)

if ! grep -qx "demo-hub" <<<"$existing"; then
  kind create cluster --name demo-hub --config kind/hub.yaml
else
  echo "skip: demo-hub already exists"
fi

for env in dev stg; do
  if ! grep -qx "demo-$env" <<<"$existing"; then
    kind create cluster --name "demo-$env" --config "kind/$env.yaml"
  else
    echo "skip: demo-$env already exists"
  fi
done

kubectl --context kind-demo-hub get nodes

# Preload the demo app image into the spokes.
# A pull at Pod start depends on egress from inside the node container, and it has
# ended in ImagePullBackOff when colima's NAT misbehaved. So pull with the host's
# docker and load the image in advance.
# (`kind load docker-image` fails in ctr import --all-platforms on a missing blob of a
#  multi-arch index with provenance, so docker save | ctr import is used directly)
PODINFO_IMG=$(grep -o 'ghcr.io/stefanprodan/podinfo:[0-9.]*' seed-repo/app/web/base/demo-app/deployment.yaml | head -1)
echo "== Pulling $PODINFO_IMG and loading it into the spokes =="
# The tag is pinned, so skip the pull when cached (keeps going even if egress is flaky)
if docker image inspect "$PODINFO_IMG" >/dev/null 2>&1; then
  echo "skip: already cached on the host"
else
  docker pull "$PODINFO_IMG"
fi
for env in dev stg; do
  if docker exec "demo-$env-control-plane" crictl inspecti "$PODINFO_IMG" >/dev/null 2>&1; then
    echo "skip: already loaded into demo-$env"
  else
    docker save "$PODINFO_IMG" | docker exec -i "demo-$env-control-plane" \
      ctr --namespace=k8s.io images import --digests - >/dev/null
    echo "OK: loaded into demo-$env"
  fi
done
