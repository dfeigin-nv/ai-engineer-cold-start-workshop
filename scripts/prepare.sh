#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

case "${1:---both}" in
  --both) prepare_mode=both; lanes=(base fast-criu) ;;
  --cold-start) prepare_mode=cold-start; lanes=(base) ;;
  --restore) prepare_mode=restore; lanes=(fast-criu) ;;
  *) die 'usage: ./workshop.sh prepare [--both|--cold-start|--restore]' ;;
esac
[ "$#" -le 1 ] || die 'usage: ./workshop.sh prepare [--both|--cold-start|--restore]'

for command_name in kubectl curl jq; do require_command "$command_name"; done
validate_config
start_vcluster_forward
start_grafana_forward

for lane in "${lanes[@]}"; do
  if [ "$lane" = base ]; then icon='🔴'; name='cold-start'; else icon='🟢'; name='snapshot'; fi
  push_demo_status "$lane" "${icon} Resetting to one worker — ${name} not requested yet"
done
"$ROOT_DIR/scripts/reset.sh"

if [ "$prepare_mode" != cold-start ]; then
  current_checkpoint_is_ready \
    || die 'the checkpoint referenced by the current snapshot lane is not Ready'
fi

if [ "$DROP_CACHES_BEFORE_DEMO" = yes ]; then
  "$ROOT_DIR/scripts/drop-caches.sh"
fi

for lane in "${lanes[@]}"; do
  if [ "$lane" = base ]; then icon='🔴'; else icon='🟢'; fi
  push_demo_status "$lane" "${icon} Starting sustained load — not requested yet"
done
start_aiperf_load "$prepare_mode"

input_sha=''
if [ "$prepare_mode" = both ]; then
  runner_pod="$(aiperf_runner_pod)"
  host_kubectl -n "$HOST_NAMESPACE" exec "$runner_pod" -- \
    cmp -s /tmp/aiperf-base/inputs.json /tmp/aiperf-fast-criu/inputs.json \
    || die 'AIPerf generated different inputs for the two lanes'
  input_sha="$(host_kubectl -n "$HOST_NAMESPACE" exec "$runner_pod" -- \
    sha256sum /tmp/aiperf-base/inputs.json | awk '{print $1}')"
fi

prepared_state="$(jq -nc --arg mode "$prepare_mode" --arg prepared "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg input_sha "$input_sha" \
  '{mode:$mode,prepared:$prepared,input_sha256:$input_sha,worker_uids:{}}')"
for lane in "${lanes[@]}"; do
  ensure_frontend_forward "$lane"
  uids="$(host_kubectl -n "$HOST_NAMESPACE" get pods \
    -l "nvidia.com/dynamo-graph-deployment-name=vllm-${lane},nvidia.com/dynamo-component-type=worker" \
    -o json | jq -c '[.items[] | select(.metadata.deletionTimestamp == null) | .metadata.uid]')"
  key="${lane//-/_}"
  prepared_state="$(jq -nc --argjson state "$prepared_state" --arg key "$key" \
    --argjson uids "$uids" '$state | .worker_uids[$key]=$uids')"
done
printf '%s\n' "$prepared_state" >"$STATE_DIR/prepared.json"
for lane in "${lanes[@]}"; do
  if [ "$lane" = base ]; then icon='🔴'; else icon='🟢'; fi
  push_demo_status "$lane" "${icon} FIXED LOAD ACTIVE · 5 req/s · run demo ${1:---both}"
done
info "${prepare_mode} is prepared: one worker per lane and fixed 5 req/s load active"
info "Grafana: $GRAFANA_DASHBOARD_URL"
