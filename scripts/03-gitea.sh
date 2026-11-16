#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
HUB=kind-demo-hub
GITEA_URL=http://localhost:3000
GITEA_USER=demo
GITEA_PASS=demo12345

# Chicken-and-egg bootstrap: Gitea's own manifest is managed in a repository on Gitea
# (platform/gitea), but the very first time there is no Git server yet, so the same file
# is applied directly. After that, the hand-written Application `gitea` (hub/platform.yaml)
# adopts and manages it.
kubectl --context $HUB apply -f seed-repo/platform/gitea/gitea.yaml
kubectl --context $HUB -n gitea rollout status deployment/gitea --timeout=300s

echo "Waiting for Gitea healthz..."
for i in $(seq 1 60); do
  curl -fsS "$GITEA_URL/api/healthz" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS "$GITEA_URL/api/healthz" >/dev/null

# Create the admin user (on a re-run it already exists, so failing is fine)
kubectl --context $HUB -n gitea exec deploy/gitea -- \
  gitea admin user create --admin --username "$GITEA_USER" --password "$GITEA_PASS" \
  --email demo@example.com --must-change-password=false 2>/dev/null \
  || echo "skip: user $GITEA_USER already exists"

# Create the public repository manifests (public = Argo CD can clone it anonymously)
if ! curl -fsS -u "$GITEA_USER:$GITEA_PASS" "$GITEA_URL/api/v1/repos/$GITEA_USER/manifests" >/dev/null 2>&1; then
  curl -fsS -u "$GITEA_USER:$GITEA_PASS" -X POST "$GITEA_URL/api/v1/user/repos" \
    -H 'Content-Type: application/json' \
    -d '{"name":"manifests","private":false,"default_branch":"main","auto_init":false}' >/dev/null
  echo "OK: created the repository manifests"
else
  echo "skip: the repository manifests already exists"
fi

# Push the seed content (idempotent: main is always recreated from seed-repo)
rm -rf .work/seed
mkdir -p .work
cp -R seed-repo .work/seed
pushd .work/seed >/dev/null
git init -q -b main
git -c user.name=demo -c user.email=demo@example.com add -A
git -c user.name=demo -c user.email=demo@example.com commit -qm "seed: demo-app base/overlay"
git push -q --force "http://$GITEA_USER:$GITEA_PASS@localhost:3000/$GITEA_USER/manifests.git" main
popd >/dev/null

echo "OK: Gitea is ready ($GITEA_URL, $GITEA_USER/$GITEA_PASS)"
