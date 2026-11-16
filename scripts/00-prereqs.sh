#!/usr/bin/env bash
set -euo pipefail

missing=0
for c in docker kind kubectl helm jq git curl htpasswd; do
  if ! command -v "$c" >/dev/null 2>&1; then
    echo "NG: $c not found (run mise install for the tools in mise.toml. git / curl / htpasswd come from macOS)"
    missing=1
  fi
done
[ "$missing" -eq 0 ] || exit 1

if ! docker info >/dev/null 2>&1; then
  echo "NG: cannot reach the docker daemon. Start colima: colima start argocd-lab --cpu 4 --memory 8 --disk 30"
  exit 1
fi

echo "OK: prerequisite tools and the docker daemon are available"
