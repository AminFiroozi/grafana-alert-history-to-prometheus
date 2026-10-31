#!/usr/bin/env bash
# Wipe env2 Prometheus data (PVC data-prometheus-0) so the import can be redone from scratch.
# env1 and env2 Grafana are not touched. Deletes and recreates the StatefulSet, so manifest
# changes to the PVC template (size) also take effect.
set -euo pipefail
P=$(cd "$(dirname "$0")" && pwd)
export KUBECONFIG="$P/kubeconfig"
NS=monitoring
kubectl -n $NS delete statefulset prometheus --ignore-not-found --wait=true
kubectl -n $NS wait --for=delete pod/prometheus-0 --timeout=120s 2>/dev/null || true
kubectl -n $NS delete pvc data-prometheus-0 --ignore-not-found --wait=true
kubectl apply -f "$P/k8s/10-prometheus.yaml"   # also restores args if you edited them in phase 6
kubectl -n $NS rollout status statefulset/prometheus --timeout=180s
kubectl -n $NS wait --for=condition=Ready pod/prometheus-0 --timeout=180s
echo "env2 Prometheus reset: $(kubectl -n $NS exec prometheus-0 -c prometheus -- ls /prometheus | tr '\n' ' ')"
