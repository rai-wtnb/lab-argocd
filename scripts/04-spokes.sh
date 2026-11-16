#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
HUB=kind-demo-hub
mkdir -p .work

for env in dev stg; do
  ctx="kind-demo-$env"
  echo "== spoke-$env: applying RBAC =="
  kubectl --context "$ctx" apply -f spoke/rbac.yaml

  echo "== spoke-$env: waiting for the SA token =="
  token=""
  for i in $(seq 1 30); do
    token=$(kubectl --context "$ctx" -n kube-system get secret argocd-manager-token \
      -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
    [ -n "$token" ] && break
    sleep 2
  done
  [ -n "$token" ] || { echo "NG: could not get the token"; exit 1; }

  # Get kind's internal endpoint (the container name on the shared docker network) and the CA
  kind get kubeconfig --name "demo-$env" --internal > ".work/kubeconfig-$env"
  server=$(kubectl --kubeconfig ".work/kubeconfig-$env" config view --raw -o jsonpath='{.clusters[0].cluster.server}')
  cadata=$(kubectl --kubeconfig ".work/kubeconfig-$env" config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

  echo "== spoke-$env: registering the cluster on the hub (server=$server) =="
  # See hub/clusters.yaml for the shape of the Secret (the registry entry). This only fills in the values and applies it.
  # Auth is a bearer token (lab only), so the resulting Secret holds a real secret (do not commit it to git).
  config=$(jq -nc --arg t "$token" --arg ca "$cadata" \
    '{bearerToken:$t, tlsClientConfig:{insecure:false, caData:$ca}}')
  sed -e "s|__ENV__|$env|g" \
      -e "s|__SERVER__|$server|g" \
      -e "s|__CONFIG__|$config|g" \
      hub/clusters.yaml | kubectl --context $HUB -n argocd apply -f -
done

echo "OK: registered spoke-dev / spoke-stg"
