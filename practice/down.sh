#!/usr/bin/env bash
# Tear down the practice environment only: kind cluster "ahpractice" and compose project "ahpractice".
set -euo pipefail
P=$(cd "$(dirname "$0")" && pwd)
KIND=${KIND:-$(command -v kind || echo "$HOME/.local/bin/kind")}
"$KIND" delete cluster --name ahpractice --kubeconfig "$P/kubeconfig" || true
docker compose -f "$P/docker-compose.yml" down -v
rm -f "$P/kubeconfig"
