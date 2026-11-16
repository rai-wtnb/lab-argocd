#!/usr/bin/env bash
# Extra setup for the ESO demo:
#   1. Wait for Vault (dev mode) on the hub and seed the initial value
#      (the deployment itself is GitOps: the Application `vault` in hub/platform.yaml does it)
#   2. Install External Secrets Operator on spoke-dev with helm
#   3. Create the vault-token Secret, used by the SecretStore to authenticate, in the demo-app ns
# After this, `mise marker-secrets` ships the ExternalSecret through GitOps and the Secret is generated.
set -euo pipefail
cd "$(dirname "$0")/.."
HUB=kind-demo-hub
DEV=kind-demo-dev

if ! command -v helm >/dev/null 2>&1; then
  echo "NG: helm not found (mise install). ESO is distributed only as a helm chart, so this step alone needs helm"
  exit 1
fi

echo '== Waiting for Vault (created by the sync of the Application vault. hub/platform.yaml) =='
for i in $(seq 1 60); do
  kubectl --context $HUB -n vault get deploy/vault >/dev/null 2>&1 && break
  # Kick the sync again every 30 seconds. Auto-sync does not retry once it has failed on the
  # same revision (e.g. a sync that ran right after an ns deletion raced with the termination
  # and stopped as Failed), so this is a safety net
  if [ $((i % 6)) -eq 0 ]; then
    kubectl --context $HUB -n argocd patch application vault --type merge \
      -p '{"operation":{"initiatedBy":{"username":"06-eso.sh"},"sync":{"revision":"HEAD"}}}' \
      >/dev/null 2>&1 || true
  fi
  sleep 5
done
kubectl --context $HUB -n vault rollout status deployment/vault --timeout=180s

echo "== Seeding the initial value into Vault (secret/demo-app message=...) =="
kubectl --context $HUB -n vault exec deploy/vault -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root \
  vault kv put secret/demo-app message="s3cr3t-from-vault-v1"

echo "== Installing ESO on spoke-dev (helm) =="
helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo update external-secrets >/dev/null
# The first run can take a while pulling images, so the timeout is generous
helm upgrade --install external-secrets external-secrets/external-secrets \
  --kube-context $DEV --namespace external-secrets --create-namespace --wait --timeout 10m \
  -f spoke/eso-values.yaml

echo "== Creating the token the SecretStore authenticates with, in the demo-app ns =="
# With cloud IAM integration (Workload Identity etc.) this piece is not needed (the lab substitutes token auth)
kubectl --context $DEV create namespace demo-app --dry-run=client -o yaml | kubectl --context $DEV apply -f -
kubectl --context $DEV -n demo-app create secret generic vault-token \
  --from-literal=token=root --dry-run=client -o yaml | kubectl --context $DEV apply -f -

echo ""
echo "OK: ESO is ready. Next:"
echo "  mise marker-secrets   # ship the ExternalSecret through GitOps"
echo "  kubectl --context $DEV -n demo-app get secret demo-app-secret -o jsonpath='{.data.message}' | base64 -d"
echo "  mise rotate new-value   # update the value in Vault -> the Secret follows after refreshInterval (15s)"
