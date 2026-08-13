#!/usr/bin/env bash
set -euo pipefail

missing=0
for c in docker kind kubectl git curl jq; do
  if ! command -v "$c" >/dev/null 2>&1; then
    echo "NG: $c が見つからない (brew install $c)"
    missing=1
  fi
done
[ "$missing" -eq 0 ] || exit 1

if ! docker info >/dev/null 2>&1; then
  echo "NG: docker デーモンに繋がらない。colima を起動して: colima start --cpu 4 --memory 8 --disk 30"
  exit 1
fi

echo "OK: 前提ツール・docker デーモン確認済み"
