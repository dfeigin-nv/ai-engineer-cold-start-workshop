#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

quiet=no
[ "${1:-}" = --quiet ] && quiet=yes

check() {
  host_kubectl -n "$HOST_NAMESPACE" get service "$VCLUSTER_NAME" >/dev/null 2>&1
  start_vcluster_forward
  vc_kubectl -n default get dynamographdeployment vllm-base vllm-fast-criu -o json \
    | jq -e 'all(.items[];
        .status.observedGeneration == .metadata.generation and
        any(.status.conditions[]?; .type == "Ready" and .status == "True"))' >/dev/null
  current_checkpoint_is_ready
  [ -n "$(aiperf_runner_pod)" ]
}

if ! check; then
  [ "$quiet" = yes ] || warn 'workshop is not fully ready'
  exit 1
fi

if [ "$quiet" = no ]; then
  info 'workshop is ready'
  vc_kubectl -n default get dynamographdeployment
  checkpoint_name="$(current_checkpoint_name)"
  info 'current fast-lane checkpoint'
  vc_kubectl -n default get dynamocheckpoint "$checkpoint_name"
  host_kubectl -n "$HOST_NAMESPACE" get pods \
    -l nvidia.com/dynamo-component-type=worker -o wide
  if curl -fsS "$GRAFANA_URL/api/health" >/dev/null 2>&1; then
    info "Grafana: $GRAFANA_DASHBOARD_URL"
  else
    warn "Grafana forward is not running; use ./workshop.sh grafana"
  fi
fi
