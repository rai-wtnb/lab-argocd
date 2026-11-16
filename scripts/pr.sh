#!/usr/bin/env bash
# For the Pull Request generator demo. Pushes a branch to the repository on Gitea and opens / updates / closes a PR.
# Usage: pr.sh open|update|close [name]   (name defaults to blue. The branch is preview/<name>)
#        pr.sh status
# The ApplicationSet pr-preview (hub/applicationset-pr.yaml) detects open PRs and creates Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

action="${1:?usage: pr.sh open|update|close [name] / pr.sh status}"
name="${2:-blue}"
branch="preview/$name"

GITEA_URL=http://localhost:3000
GITEA_AUTH=demo:demo12345
API="$GITEA_URL/api/v1/repos/demo/manifests"
REPO_URL="http://$GITEA_AUTH@localhost:3000/demo/manifests.git"
WORK=.work/manifests
OVERLAY=app/web/overlay/dev/demo-app/kustomization.yaml
git_c() { git -C "$WORK" -c user.name=demo -c user.email=demo@example.com "$@"; }

# Number of the open PR of this branch (empty if none)
pr_number() {
  curl -fsS -u "$GITEA_AUTH" "$API/pulls?state=open" \
    | jq -r --arg b "$branch" '.[] | select(.head.ref == $b) | .number'
}

# Rewrites the message shown in the UI, then commits and pushes.
# Changes PODINFO_UI_MESSAGE of podinfo so the difference between PRs is visible.
push_change() {
  local message="$1"
  sed -i.bak -E "s|(value: )\"hello from [^\"]*\"|\1\"$message\"|" "$WORK/$OVERLAY"
  rm -f "$WORK/$OVERLAY.bak"
  git_c add -A
  if git_c diff --cached --quiet; then
    echo "no change"; return 0
  fi
  git_c commit -qm "feat(demo-app): [$branch] set the UI message to \"$message\""
  git_c push -q origin "$branch"
  echo "pushed: $branch ($(git_c rev-parse --short HEAD)) \"$message\""
}

if [ "$action" = "status" ]; then
  echo "== Open PRs (Gitea) =="
  curl -fsS -u "$GITEA_AUTH" "$API/pulls?state=open" \
    | jq -r '.[] | "#\(.number)  \(.head.ref)  \(.head.sha[0:8])  \(.title)"'
  echo "== Applications generated from PRs (hub) =="
  kubectl --context kind-demo-hub -n argocd get applications -l preview=true \
    -o custom-columns='NAME:.metadata.name,REVISION:.spec.source.targetRevision,SYNC:.status.sync.status,HEALTH:.status.health.status' 2>/dev/null || true
  echo "== Deployments / Services on spoke-dev =="
  kubectl --context kind-demo-dev -n demo-app get deploy,svc 2>/dev/null || echo "(none)"
  exit 0
fi

if [ ! -d "$WORK/.git" ]; then
  git clone -q "$REPO_URL" "$WORK"
fi
# marker.sh assumes it is on main, so always go back to main at the end
trap 'git -C "$WORK" checkout -q main' EXIT
git_c checkout -q main
git_c pull -q --rebase
git_c fetch -q --prune origin

case "$action" in
  open)
    if [ -n "$(pr_number)" ]; then
      echo "skip: the PR of $branch is already open (#$(pr_number))"; exit 0
    fi
    # Recreate the branch from the tip of main
    git_c checkout -q -B "$branch" main
    sed -i.bak -E "s|(value: )\"hello from [^\"]*\"|\1\"hello from PR $name\"|" "$WORK/$OVERLAY"
    rm -f "$WORK/$OVERLAY.bak"
    git_c add -A
    git_c commit -qm "feat(demo-app): [$branch] set the UI message to \"hello from PR $name\""
    git_c push -q --force origin "$branch"
    number=$(curl -fsS -u "$GITEA_AUTH" -X POST "$API/pulls" \
      -H 'Content-Type: application/json' \
      -d "$(jq -n --arg h "$branch" --arg t "preview: $name" '{head:$h, base:"main", title:$t}')" \
      | jq -r '.number')
    echo "OK: opened PR #$number ($GITEA_URL/demo/manifests/pulls/$number)"
    echo "    The Application demo-app-pr-$number appears in about 30 seconds. Check: mise pr-status"
    echo "    View the UI: mise pr-forward $number -> http://localhost:9900"
    ;;
  update)
    number=$(pr_number)
    [ -n "$number" ] || { echo "NG: $branch has no open PR (run mise pr-open $name first)"; exit 1; }
    git_c checkout -q -B "$branch" "origin/$branch"
    push_change "hello from PR $name ($(date +%H:%M:%S))"
    echo "    head_sha of PR #$number changed. targetRevision of the Application follows. Check: mise pr-status"
    ;;
  close)
    number=$(pr_number)
    [ -n "$number" ] || { echo "skip: $branch has no open PR"; exit 0; }
    curl -fsS -u "$GITEA_AUTH" -X PATCH "$API/pulls/$number" \
      -H 'Content-Type: application/json' -d '{"state":"closed"}' >/dev/null
    echo "OK: closed PR #$number"
    echo "    The Application demo-app-pr-$number and its Deployment / Service are removed in about 30 seconds. Check: mise pr-status"
    ;;
  *)
    echo "action must be open / update / close / status"; exit 1;;
esac
