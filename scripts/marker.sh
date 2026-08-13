#!/usr/bin/env bash
# マーカー (app.argocd.yaml) の追加/削除を Gitea のリポジトリへ push する。
# 使い方: marker.sh add|remove dev|stg [app]   (app 省略時 demo-app)
set -euo pipefail
cd "$(dirname "$0")/.."

action="${1:?usage: marker.sh add|remove dev|stg [app]}"
env="${2:?usage: marker.sh add|remove dev|stg [app]}"
app="${3:-demo-app}"
[[ "$env" == "dev" || "$env" == "stg" ]] || { echo "env は dev か stg"; exit 1; }

# アプリ名 → app/<kind>/ ディレクトリの対応
case "$app" in
  demo-app)     kind_dir=web ;;
  demo-secrets) kind_dir=secrets ;;
  *) echo "未知のアプリ: $app"; exit 1 ;;
esac

REPO_URL="http://demo:demo12345@localhost:3000/demo/manifests.git"
WORK=.work/manifests

if [ ! -d "$WORK/.git" ]; then
  git clone -q "$REPO_URL" "$WORK"
fi
git -C "$WORK" pull -q --rebase

overlay="app/$kind_dir/overlay/$env/$app"
if [ ! -d "$WORK/$overlay" ]; then
  echo "NG: $overlay がリポジトリに存在しない (このアプリの $env overlay は未定義)"
  exit 1
fi
marker="$WORK/$overlay/app.argocd.yaml"

case "$action" in
  add)
    # Application 名は hub (ArgoCD インスタンス) 内で一意のため stg は別名にする
    name="$app"
    [ "$env" = "stg" ] && name="$app-stg"
    cat > "$marker" <<EOF
# ApplicationSet (hub/applicationset.yaml) の files generator が読むマーカー
name: $name
team: demo
project: demo
namespace: demo-app
env: $env
EOF
    msg="feat($app): [$env] ArgoCD マーカー追加"
    ;;
  remove)
    rm -f "$marker"
    msg="feat($app): [$env] ArgoCD マーカー削除 (Application ごと prune される)"
    ;;
  *)
    echo "action は add か remove"; exit 1;;
esac

git -C "$WORK" -c user.name=demo -c user.email=demo@example.com add -A
if git -C "$WORK" diff --cached --quiet; then
  echo "変更なし (既に $action 済み)"; exit 0
fi
git -C "$WORK" -c user.name=demo -c user.email=demo@example.com commit -qm "$msg"
git -C "$WORK" push -q origin main

echo "pushed: $msg"
echo "ApplicationSet のポーリング (最大30秒〜3分) 後に反映される。確認: make status"
