#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
start_vcluster_forward

host_kubectl -n "$HOST_NAMESPACE" delete job workshop-aiperf-load \
  --ignore-not-found --wait=true >/dev/null
stop_aiperf_load
rm -f "$STATE_DIR/prepared.json"

patch='[{"op":"replace","path":"/spec/components/1/replicas","value":1}]'
vc_kubectl -n default patch dynamographdeployments.v1beta1.nvidia.com vllm-base \
  --type=json -p "$patch" >/dev/null &
base_patch_pid=$!
vc_kubectl -n default patch dynamographdeployments.v1beta1.nvidia.com vllm-fast-criu \
  --type=json -p "$patch" >/dev/null &
fast_patch_pid=$!
wait "$base_patch_pid"
wait "$fast_patch_pid"

deadline=$((SECONDS + DEMO_TIMEOUT_SECONDS))
while [ "$SECONDS" -lt "$deadline" ]; do
  settled=yes
  for lane in base fast-criu; do
    counts="$(host_kubectl -n "$HOST_NAMESPACE" get pods \
      -l "nvidia.com/dynamo-graph-deployment-name=vllm-${lane},nvidia.com/dynamo-component-type=worker" \
      -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null)] as $pods | [($pods|length), ([$pods[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length)] | @tsv')"
    [ "$counts" = $'1\t1' ] || settled=no
  done
  [ "$settled" = yes ] && { info 'both lanes are at one Ready worker'; exit 0; }
  sleep 3
done
die 'lanes did not settle to one Ready worker before timeout'
