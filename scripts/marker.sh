#!/usr/bin/env bash
# Pushes adding / removing a marker (app.argocd.yaml) to the repository on Gitea.
# Usage: marker.sh add|remove dev|stg [app]   (app defaults to demo-app)
set -euo pipefail
cd "$(dirname "$0")/.."

action="${1:?usage: marker.sh add|remove dev|stg [app]}"
env="${2:?usage: marker.sh add|remove dev|stg [app]}"
app="${3:-demo-app}"
[[ "$env" == "dev" || "$env" == "stg" ]] || { echo "env must be dev or stg"; exit 1; }

# App name -> app/<kind>/ directory
case "$app" in
  demo-app)     kind_dir=web ;;
  demo-secrets) kind_dir=secrets ;;
  *) echo "unknown app: $app"; exit 1 ;;
esac

REPO_URL="http://demo:demo12345@localhost:3000/demo/manifests.git"
WORK=.work/manifests

if [ ! -d "$WORK/.git" ]; then
  git clone -q "$REPO_URL" "$WORK"
fi
git -C "$WORK" pull -q --rebase

overlay="app/$kind_dir/overlay/$env/$app"
if [ ! -d "$WORK/$overlay" ]; then
  echo "NG: $overlay does not exist in the repository (this app has no $env overlay)"
  exit 1
fi
marker="$WORK/$overlay/app.argocd.yaml"

case "$action" in
  add)
    # Application names are unique within the hub (the Argo CD instance), so stg gets a different name
    name="$app"
    [ "$env" = "stg" ] && name="$app-stg"
    cat > "$marker" <<EOF
# Marker read by the files generator of the ApplicationSet (hub/applicationset.yaml)
name: $name
team: demo
project: demo
namespace: demo-app
env: $env
EOF
    msg="feat($app): [$env] add the Argo CD marker"
    ;;
  remove)
    rm -f "$marker"
    msg="feat($app): [$env] remove the Argo CD marker (the whole Application is pruned)"
    ;;
  *)
    echo "action must be add or remove"; exit 1;;
esac

git -C "$WORK" -c user.name=demo -c user.email=demo@example.com add -A
if git -C "$WORK" diff --cached --quiet; then
  echo "no change (already done: $action)"; exit 0
fi
git -C "$WORK" -c user.name=demo -c user.email=demo@example.com commit -qm "$msg"
git -C "$WORK" push -q origin main

echo "pushed: $msg"
echo "Takes effect after the ApplicationSet polls (30 seconds to 3 minutes at most). Check: mise status"
