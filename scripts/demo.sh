#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

case "${1:---both}" in
  --both) demo_mode=both; lanes=(base fast-criu) ;;
  --cold-start) demo_mode=cold-start; lanes=(base) ;;
  --restore) demo_mode=restore; lanes=(fast-criu) ;;
  *) die 'usage: ./workshop.sh demo [--both|--cold-start|--restore]' ;;
esac
[ "$#" -le 1 ] || die 'usage: ./workshop.sh demo [--both|--cold-start|--restore]'
export AIPERF_MODE="$demo_mode"

for command_name in kubectl curl jq; do require_command "$command_name"; done
validate_config

[ -f "$STATE_DIR/prepared.json" ] \
  || die "the demo is not prepared; run ./workshop.sh prepare --${demo_mode}"
prepared_mode="$(jq -r '.mode' "$STATE_DIR/prepared.json")"
case "${prepared_mode}:${demo_mode}" in
  both:*|cold-start:cold-start|restore:restore) ;;
  *) die "prepared mode is ${prepared_mode}; run ./workshop.sh prepare --${demo_mode}" ;;
esac

case "$MODEL_PRESET" in
  120b) model='openai/gpt-oss-120b' ;;
  qwen06b) model='Qwen/Qwen3-0.6B' ;;
esac
request_body="$(jq -nc --arg model "$model" \
  '{model:$model,messages:[{role:"user",content:"Reply with OK"}],max_tokens:8,temperature:0}')"
stream_request_body="$(jq -nc --arg model "$model" \
  '{model:$model,messages:[{role:"user",content:"Reply with OK"}],max_tokens:8,temperature:0,stream:true}')"

run_dir="$STATE_DIR/runs/$(date +%Y%m%d-%H%M%S)-${demo_mode}"
mkdir -p "$run_dir"

demo_consumed=no
cleanup_demo() {
  if [ "$demo_consumed" = yes ]; then
    stop_aiperf_load
    rm -f "$STATE_DIR/prepared.json"
  fi
}
trap cleanup_demo EXIT INT TERM

for lane in "${lanes[@]}"; do
  if [ "$lane" = base ]; then
    port="$BASE_FRONTEND_LOCAL_PORT"
  else
    port="$FAST_FRONTEND_LOCAL_PORT"
  fi
  curl -fsS "http://127.0.0.1:${port}/health" >/dev/null 2>&1 \
    || die "prepared ${lane} frontend is not reachable; run ./workshop.sh prepare --${demo_mode}"
done

info "prepared AIPerf load is active; firing ${demo_mode} without reset"

declare -A existing_worker_uids
for lane in "${lanes[@]}"; do
  key="${lane//-/_}"
  existing_worker_uids[$lane]="$(jq -c --arg key "$key" '.worker_uids[$key]' "$STATE_DIR/prepared.json")"
done

t0_epoch="$(date +%s.%N)"
t0_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
t0_display="$(date +%H:%M:%S) local"

info "firing ${demo_mode} at $t0_iso"
demo_consumed=yes
for lane in "${lanes[@]}"; do
  if [ "$lane" = base ]; then icon='🔴'; else icon='🟢'; fi
  push_demo_status "$lane" "${icon} Requested ${t0_display} — waiting for first token"
done
patch='[{"op":"replace","path":"/spec/components/1/replicas","value":2}]'
patch_pids=()
for lane in "${lanes[@]}"; do
  vc_kubectl -n default patch dynamographdeployments.v1beta1.nvidia.com "vllm-${lane}" \
    --type=json -p "$patch" >"$run_dir/${lane}-patch.json" &
  patch_pids+=($!)
done
for patch_pid in "${patch_pids[@]}"; do wait "$patch_pid"; done

declare -A new_pod container_start_iso container_delay_seconds
declare -A runtime_ready_seconds trigger_ready_seconds
declare -A client_ttft_seconds container_first_token_seconds scale_first_token_seconds
measure_first_token() {
  local lane="$1" ready_epoch="$2" port first_token_epoch started_epoch
  if [ "$lane" = base ]; then
    port="$BASE_FRONTEND_LOCAL_PORT"
  else
    port="$FAST_FRONTEND_LOCAL_PORT"
  fi
  client_ttft_seconds[$lane]="$(curl -fsS -N --max-time 120 \
    -o "$run_dir/${lane}-first-token.txt" -w '%{time_starttransfer}' \
    "http://127.0.0.1:${port}/v1/chat/completions" \
    -H 'Content-Type: application/json' -d "$stream_request_body")"
  grep -q '^data:' "$run_dir/${lane}-first-token.txt" \
    || die "${lane} first-token request did not return an SSE stream"
  first_token_epoch="$(awk -v ready="$ready_epoch" -v ttft="${client_ttft_seconds[$lane]}" \
    'BEGIN {printf "%.6f", ready+ttft}')"
  started_epoch="$(date --date="${container_start_iso[$lane]}" +%s.%N)"
  container_first_token_seconds[$lane]="$(awk -v end="$first_token_epoch" -v start="$started_epoch" \
    'BEGIN {printf "%.1f", end-start}')"
  scale_first_token_seconds[$lane]="$(awk -v end="$first_token_epoch" -v start="$t0_epoch" \
    'BEGIN {printf "%.1f", end-start}')"
  if [ "$lane" = base ]; then icon='🔴'; else icon='🟢'; fi
  push_demo_status "$lane" \
    "${icon} ${container_first_token_seconds[$lane]} s · requested ${t0_display} · container start → first token"
  info "${lane}: first token ${container_first_token_seconds[$lane]}s after container start (serving TTFT ${client_ttft_seconds[$lane]}s)"
}

deadline=$((SECONDS + DEMO_TIMEOUT_SECONDS))
while [ "$SECONDS" -lt "$deadline" ]; do
  for lane in "${lanes[@]}"; do
    [ -n "${runtime_ready_seconds[$lane]:-}" ] && continue
    pod_json="$(host_kubectl -n "$HOST_NAMESPACE" get pods \
      -l "nvidia.com/dynamo-graph-deployment-name=vllm-${lane},nvidia.com/dynamo-component-type=worker" \
      -o json)"
    pod="$(printf '%s' "$pod_json" | jq -r --argjson existing "${existing_worker_uids[$lane]}" \
      '[.items[] | select(.metadata.deletionTimestamp == null) | select((.metadata.uid as $uid | $existing | index($uid)) == null)] | sort_by(.metadata.creationTimestamp) | last | .metadata.name // empty')"
    [ -n "$pod" ] || continue
    new_pod[$lane]="$pod"
    pod_item="$(printf '%s' "$pod_json" | jq -c --arg pod "$pod" \
      '.items[] | select(.metadata.name == $pod)')"
    created_iso="$(printf '%s' "$pod_item" | jq -r '.metadata.creationTimestamp')"
    started_iso="$(printf '%s' "$pod_item" | jq -r '.status.containerStatuses[0].state.running.startedAt // empty')"
    if [ -n "$started_iso" ] && [ -z "${container_start_iso[$lane]:-}" ]; then
      container_start_iso[$lane]="$started_iso"
      created_epoch="$(date --date="$created_iso" +%s.%N)"
      started_epoch="$(date --date="$started_iso" +%s.%N)"
      container_delay_seconds[$lane]="$(awk -v end="$started_epoch" -v start="$created_epoch" 'BEGIN {printf "%.1f", end-start}')"
      info "${lane}: container running (${container_delay_seconds[$lane]}s after pod creation)"
    fi
    is_ready="$(printf '%s' "$pod_item" | jq -r \
      'any(.status.conditions[]?; .type == "Ready" and .status == "True")')"
    if [ "$is_ready" = true ] && [ -n "${container_start_iso[$lane]:-}" ]; then
      if [ "$lane" = fast-criu ]; then
        restore_status="$(printf '%s' "$pod_item" \
          | jq -r '.metadata.annotations["nvidia.com/snapshot-restore-status.main"] // empty')"
        [ "$restore_status" = completed ] \
          || die 'fast-criu worker became Ready without completed restore evidence'
      fi
      ready_iso="$(printf '%s' "$pod_item" | jq -r \
        '.status.conditions[] | select(.type == "Ready") | .lastTransitionTime')"
      ready_epoch="$(date --date="$ready_iso" +%s.%N)"
      started_epoch="$(date --date="${container_start_iso[$lane]}" +%s.%N)"
      runtime_ready_seconds[$lane]="$(awk -v end="$ready_epoch" -v start="$started_epoch" 'BEGIN {printf "%.1f", end-start}')"
      trigger_ready_seconds[$lane]="$(awk -v end="$ready_epoch" -v start="$t0_epoch" 'BEGIN {printf "%.1f", end-start}')"
      measure_first_token "$lane" "$ready_epoch"
      info "${lane}: ${pod} Ready in ${runtime_ready_seconds[$lane]}s from container start (${trigger_ready_seconds[$lane]}s from trigger)"
    fi
  done
  all_ready=yes
  for lane in "${lanes[@]}"; do
    [ -n "${runtime_ready_seconds[$lane]:-}" ] || all_ready=no
  done
  [ "$all_ready" = yes ] && break
  sleep 2
done

for lane in "${lanes[@]}"; do
  [ -n "${runtime_ready_seconds[$lane]:-}" ] \
    || die "${lane} worker did not become Ready before timeout"
done

info "selected second worker(s) are Ready; holding load for ${AIPERF_RECOVERY_SECONDS}s to show TTFT recovery"
sleep "$AIPERF_RECOVERY_SECONDS"

for lane in "${lanes[@]}"; do
  if [ "$lane" = base ]; then
    port="$BASE_FRONTEND_LOCAL_PORT"
  else
    port="$FAST_FRONTEND_LOCAL_PORT"
  fi
  curl -fsS --max-time 120 "http://127.0.0.1:${port}/v1/chat/completions" \
    -H 'Content-Type: application/json' -d "$request_body" >"$run_dir/${lane}-inference.json"
  jq -e '.choices | length > 0' "$run_dir/${lane}-inference.json" >/dev/null
done

summary="$(jq -nc --arg started "$t0_iso" --arg mode "$demo_mode" \
  '{started:$started,mode:$mode,inference:"passed"}')"
for lane in "${lanes[@]}"; do
  key="${lane//-/_}"
  lane_summary="$(jq -nc \
    --arg pod "${new_pod[$lane]}" \
    --argjson container_delay "${container_delay_seconds[$lane]}" \
    --argjson runtime "${runtime_ready_seconds[$lane]}" \
    --argjson trigger "${trigger_ready_seconds[$lane]}" \
    --argjson client_ttft "${client_ttft_seconds[$lane]}" \
    --argjson container_first_token "${container_first_token_seconds[$lane]}" \
    --argjson scale_first_token "${scale_first_token_seconds[$lane]}" \
    '{pod:$pod,container_delay_seconds:$container_delay,container_to_ready_seconds:$runtime,trigger_to_ready_seconds:$trigger,serving_ttft_seconds:$client_ttft,container_to_first_token_seconds:$container_first_token,scale_to_first_token_seconds:$scale_first_token}')"
  if [ "$lane" = fast-criu ]; then
    lane_summary="$(printf '%s' "$lane_summary" | jq '. + {restore_status:"completed"}')"
  fi
  summary="$(jq -nc --argjson current "$summary" --arg key "$key" \
    --argjson lane_summary "$lane_summary" '$current + {($key):$lane_summary}')"
done

if [ "$demo_mode" = both ]; then
  speedup="$(awk -v base="${runtime_ready_seconds[base]}" -v fast="${runtime_ready_seconds[fast-criu]}" 'BEGIN {printf "%.2f", base/fast}')"
  container_first_token_speedup="$(awk -v base="${container_first_token_seconds[base]}" -v fast="${container_first_token_seconds[fast-criu]}" 'BEGIN {printf "%.2f", base/fast}')"
  scale_first_token_speedup="$(awk -v base="${scale_first_token_seconds[base]}" -v fast="${scale_first_token_seconds[fast-criu]}" 'BEGIN {printf "%.2f", base/fast}')"
  summary="$(printf '%s' "$summary" | jq \
    --argjson ready "$speedup" \
    --argjson container_first "$container_first_token_speedup" \
    --argjson scale_first "$scale_first_token_speedup" \
    '. + {container_to_ready_speedup:$ready,container_to_first_token_speedup:$container_first,scale_to_first_token_speedup:$scale_first}')"
fi
printf '%s\n' "$summary" >"$run_dir/summary.json"

printf '\n%-12s %18s %18s %12s  %s\n' LANE CONTAINER_TO_READY TRIGGER_TO_READY START_DELAY POD
for lane in "${lanes[@]}"; do
  printf '%-12s %18s %18s %12s  %s\n' "$lane" "${runtime_ready_seconds[$lane]}s" \
    "${trigger_ready_seconds[$lane]}s" "${container_delay_seconds[$lane]}s" "${new_pod[$lane]}"
done
printf '\nInference: passed on selected lane(s)\nResults: %s\nGrafana: %s\n' \
  "$run_dir" "$GRAFANA_DASHBOARD_URL"
if [ "$demo_mode" = both ]; then
  printf 'Container-to-Ready speedup: %sx\n' "$speedup"
  printf 'Container-start-to-first-token: cold-start %ss, snapshot %ss (%sx)\n' \
    "${container_first_token_seconds[base]}" "${container_first_token_seconds[fast-criu]}" "$container_first_token_speedup"
else
  lane="${lanes[0]}"
  if [ "$lane" = base ]; then display_lane=cold-start; else display_lane=snapshot; fi
  printf 'Container-start-to-first-token: %s %ss\n' "$display_lane" "${container_first_token_seconds[$lane]}"
fi
