#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
HUB=kind-demo-hub
GITEA_URL=http://localhost:3000
GITEA_USER=demo
GITEA_PASS=demo12345

# 鶏と卵のブートストラップ: Gitea 自身のマニフェストは Gitea 上のリポジトリ (platform/gitea)
# で管理されるが、最初の 1 回は Git サーバがまだ無いので同じファイルを直接 apply する。
# 以後は手書き Application `gitea` (hub/platform.yaml) がこれを adopt して管理する。
kubectl --context $HUB apply -f seed-repo/platform/gitea/gitea.yaml
kubectl --context $HUB -n gitea rollout status deployment/gitea --timeout=300s

echo "Gitea healthz 待ち..."
for i in $(seq 1 60); do
  curl -fsS "$GITEA_URL/api/healthz" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS "$GITEA_URL/api/healthz" >/dev/null

# 管理ユーザー作成 (再実行時は既存のため失敗してよい)
kubectl --context $HUB -n gitea exec deploy/gitea -- \
  gitea admin user create --admin --username "$GITEA_USER" --password "$GITEA_PASS" \
  --email demo@example.com --must-change-password=false 2>/dev/null \
  || echo "skip: ユーザー $GITEA_USER は作成済み"

# 公開リポジトリ manifests を作成 (public = ArgoCD が匿名 clone できる)
if ! curl -fsS -u "$GITEA_USER:$GITEA_PASS" "$GITEA_URL/api/v1/repos/$GITEA_USER/manifests" >/dev/null 2>&1; then
  curl -fsS -u "$GITEA_USER:$GITEA_PASS" -X POST "$GITEA_URL/api/v1/user/repos" \
    -H 'Content-Type: application/json' \
    -d '{"name":"manifests","private":false,"default_branch":"main","auto_init":false}' >/dev/null
  echo "OK: リポジトリ manifests 作成"
else
  echo "skip: リポジトリ manifests は作成済み"
fi

# シード内容を push (冪等: 常に seed-repo の内容で main を作り直す)
rm -rf .work/seed
mkdir -p .work
cp -R seed-repo .work/seed
pushd .work/seed >/dev/null
git init -q -b main
git -c user.name=demo -c user.email=demo@example.com add -A
git -c user.name=demo -c user.email=demo@example.com commit -qm "seed: demo-app base/overlay"
git push -q --force "http://$GITEA_USER:$GITEA_PASS@localhost:3000/$GITEA_USER/manifests.git" main
popd >/dev/null

echo "OK: Gitea 準備完了 ($GITEA_URL, $GITEA_USER/$GITEA_PASS)"
