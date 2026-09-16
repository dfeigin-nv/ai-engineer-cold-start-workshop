#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$ROOT_DIR/.state"
RENDERED_DIR="$STATE_DIR/rendered"

if [ -f "$ROOT_DIR/config.local.env" ]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/config.local.env"
else
  # shellcheck disable=SC1091
  source "$ROOT_DIR/config.env"
fi

VCLUSTER_CONTEXT=kubernetes-super-admin@kubernetes
VCLUSTER_KUBECONFIG="$STATE_DIR/vcluster.kubeconfig"
VCLUSTER_PF_PID_FILE="$STATE_DIR/vcluster-port-forward.pid"
GRAFANA_PF_PID_FILE="$STATE_DIR/grafana-port-forward.pid"
BASE_FRONTEND_PF_PID_FILE="$STATE_DIR/base-frontend-port-forward.pid"
FAST_FRONTEND_PF_PID_FILE="$STATE_DIR/fast-frontend-port-forward.pid"
GRAFANA_PASSWORD_FILE="$STATE_DIR/grafana-admin-password"
GRAFANA_URL="http://localhost:${GRAFANA_LOCAL_PORT}"
export GRAFANA_DASHBOARD_URL="${GRAFANA_URL}/d/workshop-vcluster/workshop-vcluster?from=now-15m&to=now&refresh=2s"
AIPERF_MODE="${AIPERF_MODE:-both}"

mkdir -p "$STATE_DIR" "$RENDERED_DIR"

info() { printf '[workshop] %s\n' "$*"; }
warn() { printf '[workshop] WARN: %s\n' "$*" >&2; }
die() { printf '[workshop] ERROR: %s\n' "$*" >&2; exit 1; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

host_kubectl() {
  kubectl --context "$HOST_CONTEXT" "$@"
}

vc_kubectl() {
  kubectl --kubeconfig "$VCLUSTER_KUBECONFIG" \
    --context "$VCLUSTER_CONTEXT" "$@"
}

pid_is_live() {
  [ -f "$1" ] || return 1
  local pid
  pid="$(cat "$1")"
  kill -0 "$pid" 2>/dev/null
}

stop_pid_file() {
  [ -f "$1" ] || return 0
  local pid
  pid="$(cat "$1")"
  kill "$pid" 2>/dev/null || true
  rm -f "$1"
}

extract_vcluster_kubeconfig() {
  host_kubectl -n "$HOST_NAMESPACE" get secret "vc-${VCLUSTER_NAME}" \
    -o jsonpath='{.data.config}' | base64 -d >"$VCLUSTER_KUBECONFIG"
  kubectl config set-cluster kubernetes \
    --server="https://localhost:${VCLUSTER_LOCAL_PORT}" \
    --kubeconfig="$VCLUSTER_KUBECONFIG" >/dev/null
  chmod 600 "$VCLUSTER_KUBECONFIG"
}

start_vcluster_forward() {
  extract_vcluster_kubeconfig
  if vc_kubectl get --raw=/readyz >/dev/null 2>&1; then
    return 0
  fi

  stop_pid_file "$VCLUSTER_PF_PID_FILE"
  nohup kubectl --context "$HOST_CONTEXT" -n "$HOST_NAMESPACE" \
    port-forward "svc/${VCLUSTER_NAME}" "${VCLUSTER_LOCAL_PORT}:443" \
    </dev/null >"$STATE_DIR/vcluster-port-forward.log" 2>&1 &
  echo $! >"$VCLUSTER_PF_PID_FILE"
  disown || true

  local attempts=0
  while [ "$attempts" -lt 40 ]; do
    if vc_kubectl get --raw=/readyz >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    attempts=$((attempts + 1))
  done
  die "vcluster API did not become ready; see $STATE_DIR/vcluster-port-forward.log"
}

start_grafana_forward() {
  if curl -fsS "${GRAFANA_URL}/api/health" >/dev/null 2>&1; then
    return 0
  fi

  stop_pid_file "$GRAFANA_PF_PID_FILE"
  nohup kubectl --context "$HOST_CONTEXT" -n "$MONITORING_NAMESPACE" \
    port-forward "svc/${GRAFANA_SERVICE}" "${GRAFANA_LOCAL_PORT}:80" \
    </dev/null >"$STATE_DIR/grafana-port-forward.log" 2>&1 &
  echo $! >"$GRAFANA_PF_PID_FILE"
  disown || true

  local attempts=0
  while [ "$attempts" -lt 40 ]; do
    if curl -fsS "${GRAFANA_URL}/api/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    attempts=$((attempts + 1))
  done
  die "Grafana did not become reachable; see $STATE_DIR/grafana-port-forward.log"
}

grafana_password() {
  if [ ! -s "$GRAFANA_PASSWORD_FILE" ]; then
    host_kubectl -n "$MONITORING_NAMESPACE" get secret "$GRAFANA_SECRET" \
      -o jsonpath='{.data.admin-password}' | base64 -d >"$GRAFANA_PASSWORD_FILE"
    chmod 600 "$GRAFANA_PASSWORD_FILE"
  fi
  cat "$GRAFANA_PASSWORD_FILE"
}

ensure_frontend_forward() {
  local lane="$1" port pid_file attempts
  if [ "$lane" = base ]; then
    port="$BASE_FRONTEND_LOCAL_PORT"
    pid_file="$BASE_FRONTEND_PF_PID_FILE"
  else
    port="$FAST_FRONTEND_LOCAL_PORT"
    pid_file="$FAST_FRONTEND_PF_PID_FILE"
  fi
  if curl -fsS "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
    return 0
  fi
  stop_pid_file "$pid_file"
  nohup kubectl --context "$HOST_CONTEXT" -n "$HOST_NAMESPACE" port-forward \
    "svc/vllm-${lane}-frontend-x-default-x-${VCLUSTER_NAME}" "${port}:8000" \
    </dev/null >"$STATE_DIR/${lane}-frontend-port-forward.log" 2>&1 &
  echo $! >"$pid_file"
  disown || true
  attempts=0
  while [ "$attempts" -lt 30 ]; do
    curl -fsS "http://127.0.0.1:${port}/health" >/dev/null 2>&1 && return 0
    sleep 1
    attempts=$((attempts + 1))
  done
  die "${lane} frontend did not become reachable on local port ${port}"
}

push_demo_status() {
  local lane="$1" message="$2" password timestamp payload
  password="$(grafana_password)"
  timestamp="$(date +%s%N)"
  payload="$(jq -nc --arg timestamp "$timestamp" --arg lane "$lane" \
    --arg message "$message" \
    '{streams:[{stream:{job:"workshop-vcluster-status",lane:$lane},values:[[$timestamp,$message]]}]}')"
  curl -fsS -u "admin:${password}" -H 'Content-Type: application/json' \
    -X POST "${GRAFANA_URL}/api/datasources/proxy/uid/${GRAFANA_LOKI_DATASOURCE_UID}/loki/api/v1/push" \
    -d "$payload" >/dev/null
}

aiperf_runner_pod() {
  host_kubectl -n "$HOST_NAMESPACE" get pods -l app=workshop-aiperf-runner -o json \
    | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | first | .metadata.name // empty'
}

stop_aiperf_load() {
  local pod
  pod="$(aiperf_runner_pod)"
  [ -n "$pod" ] || return 0
  host_kubectl -n "$HOST_NAMESPACE" exec "$pod" -- \
    /opt/workshop/stop-load.sh >/dev/null 2>&1 || true
}

aiperf_load_is_active() {
  local pod
  pod="$(aiperf_runner_pod)"
  [ -n "$pod" ] && host_kubectl -n "$HOST_NAMESPACE" exec "$pod" -- \
    test -f /tmp/load-active >/dev/null 2>&1
}

start_aiperf_load() {
  local mode="$1" pod deadline model
  case "$MODEL_PRESET" in
    120b) model='openai/gpt-oss-120b' ;;
    qwen06b) model='Qwen/Qwen3-0.6B' ;;
  esac
  pod="$(aiperf_runner_pod)"
  [ -n "$pod" ] || die 'the persistent AIPerf runner is not Ready; run setup'
  host_kubectl -n "$HOST_NAMESPACE" exec "$pod" -- env \
    AIPERF_MODE="$mode" AIPERF_MODEL="$model" \
    AIPERF_CONCURRENCY="$AIPERF_CONCURRENCY" \
    AIPERF_MAX_COMPLETION_TOKENS="$AIPERF_MAX_COMPLETION_TOKENS" \
    VCLUSTER_NAME="$VCLUSTER_NAME" /opt/workshop/start-load.sh
  deadline=$((SECONDS + 60))
  until aiperf_load_is_active; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      host_kubectl -n "$HOST_NAMESPACE" exec "$pod" -- \
        tail -n 100 /tmp/workshop-aiperf.log >&2 || true
      die 'AIPerf load did not become active within 60 seconds'
    fi
    sleep 1
  done
}

wait_for_dgds_ready() {
  local timeout_seconds="$1"
  local deadline=$((SECONDS + timeout_seconds))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if vc_kubectl -n default get dynamographdeployment \
        vllm-base vllm-fast-criu -o json 2>/dev/null \
      | jq -e 'all(.items[];
          .status.observedGeneration == .metadata.generation and
          any(.status.conditions[]?; .type == "Ready" and .status == "True"))' \
        >/dev/null; then
      return 0
    fi
    sleep 5
  done
  return 1
}

current_checkpoint_name() {
  vc_kubectl -n default get dynamographdeployment vllm-fast-criu -o json \
    | jq -r '.status.checkpoints.VllmWorker.checkpointName // empty'
}

current_checkpoint_is_ready() {
  local checkpoint_name
  checkpoint_name="$(current_checkpoint_name)"
  [ -n "$checkpoint_name" ] || return 1
  vc_kubectl -n default get dynamocheckpoint "$checkpoint_name" -o json \
    | jq -e '.status.phase == "Ready"' >/dev/null
}

wait_for_current_checkpoint() {
  local timeout_seconds="$1"
  local deadline=$((SECONDS + timeout_seconds))
  while [ "$SECONDS" -lt "$deadline" ]; do
    current_checkpoint_is_ready && return 0
    sleep 10
  done
  return 1
}

render_manifests() {
  case "$MODEL_PRESET" in
    120b) AIPERF_MODEL='openai/gpt-oss-120b' ;;
    qwen06b) AIPERF_MODEL='Qwen/Qwen3-0.6B' ;;
  esac
  export HOST_NAMESPACE VCLUSTER_NAME STORAGE_CLASS MODEL_CACHE_SIZE
  export MODEL_CACHE_NFS_SERVER MODEL_CACHE_NFS_PATH SNAPSHOT_SIZE
  export MONITORING_NAMESPACE PROMETHEUS_RELEASE GRAFANA_DATASOURCE_UID GRAFANA_LOKI_DATASOURCE_UID
  export WORKER_CPU_REQUEST WORKER_CPU_LIMIT
  export WORKER_MEMORY_REQUEST WORKER_MEMORY_LIMIT
  export KV_CACHE_MEMORY_BYTES
  export VLLM_RUNTIME_IMAGE VLLM_PLACEHOLDER_IMAGE
  export AIPERF_MODEL AIPERF_MODE AIPERF_CONCURRENCY AIPERF_DURATION_SECONDS AIPERF_MAX_COMPLETION_TOKENS

  # shellcheck disable=SC2016
  envsubst '${VCLUSTER_NAME}' \
    <"$ROOT_DIR/manifests/templates/hpm-values.yaml.tmpl" \
    >"$RENDERED_DIR/hpm-values.yaml"
  # shellcheck disable=SC2016
  envsubst '${HOST_NAMESPACE} ${VCLUSTER_NAME} ${MODEL_CACHE_SIZE} ${MODEL_CACHE_NFS_SERVER} ${MODEL_CACHE_NFS_PATH}' \
    <"$ROOT_DIR/manifests/templates/host-model-cache-pv.yaml.tmpl" \
    >"$RENDERED_DIR/host-model-cache-pv.yaml"
  # shellcheck disable=SC2016
  envsubst '${STORAGE_CLASS} ${MODEL_CACHE_SIZE} ${SNAPSHOT_SIZE}' \
    <"$ROOT_DIR/manifests/templates/storage-dynamic.yaml.tmpl" \
    >"$RENDERED_DIR/storage-dynamic.yaml"
  # shellcheck disable=SC2016
  envsubst '${SNAPSHOT_SIZE} ${STORAGE_CLASS} ${MODEL_CACHE_SIZE}' \
    <"$ROOT_DIR/manifests/templates/storage-static.yaml.tmpl" \
    >"$RENDERED_DIR/storage-static.yaml"
  # shellcheck disable=SC2016
  envsubst '${HOST_NAMESPACE} ${MONITORING_NAMESPACE} ${PROMETHEUS_RELEASE}' \
    <"$ROOT_DIR/manifests/templates/podmonitors.yaml.tmpl" \
    >"$RENDERED_DIR/podmonitors.yaml"
  # shellcheck disable=SC2016
  envsubst '${HOST_NAMESPACE} ${MONITORING_NAMESPACE} ${GRAFANA_DATASOURCE_UID} ${GRAFANA_LOKI_DATASOURCE_UID} ${AIPERF_CONCURRENCY}' \
    <"$ROOT_DIR/manifests/templates/grafana-dashboard.yaml.tmpl" \
    >"$RENDERED_DIR/grafana-dashboard.yaml"
  # shellcheck disable=SC2016
  envsubst '${HOST_NAMESPACE} ${AIPERF_MODEL}' \
    <"$ROOT_DIR/manifests/templates/aiperf-runner.yaml.tmpl" \
    >"$RENDERED_DIR/aiperf-runner.yaml"
  # shellcheck disable=SC2016
  envsubst '${WORKER_CPU_REQUEST} ${WORKER_CPU_LIMIT} ${WORKER_MEMORY_REQUEST} ${WORKER_MEMORY_LIMIT} ${KV_CACHE_MEMORY_BYTES} ${VLLM_RUNTIME_IMAGE} ${VLLM_PLACEHOLDER_IMAGE}' \
    <"$ROOT_DIR/manifests/templates/lanes-120b.yaml.tmpl" \
    >"$RENDERED_DIR/lanes-120b.yaml"
  # shellcheck disable=SC2016
  envsubst '${VLLM_RUNTIME_IMAGE} ${VLLM_PLACEHOLDER_IMAGE}' \
    <"$ROOT_DIR/manifests/lanes-qwen06b.yaml" \
    >"$RENDERED_DIR/lanes-qwen06b.yaml"
}

validate_config() {
  [ -n "$HOST_CONTEXT" ] || die 'HOST_CONTEXT is empty'
  [ -n "$HOST_NAMESPACE" ] || die 'HOST_NAMESPACE is empty'
  [ -n "$VCLUSTER_NAME" ] || die 'VCLUSTER_NAME is empty'
  [ -n "$VLLM_RUNTIME_IMAGE" ] || die 'VLLM_RUNTIME_IMAGE is empty'
  [ -n "$VLLM_PLACEHOLDER_IMAGE" ] || die 'VLLM_PLACEHOLDER_IMAGE is empty'
  [ -n "$GRAFANA_LOKI_DATASOURCE_UID" ] || die 'GRAFANA_LOKI_DATASOURCE_UID is empty'
  [ -n "$STORAGE_CLASS" ] || die 'STORAGE_CLASS is empty'
  [ -n "$WORKER_CPU_REQUEST" ] || die 'WORKER_CPU_REQUEST is empty'
  [ -n "$WORKER_CPU_LIMIT" ] || die 'WORKER_CPU_LIMIT is empty'
  [ -n "$WORKER_MEMORY_REQUEST" ] || die 'WORKER_MEMORY_REQUEST is empty'
  [ -n "$WORKER_MEMORY_LIMIT" ] || die 'WORKER_MEMORY_LIMIT is empty'
  [[ "$KV_CACHE_MEMORY_BYTES" =~ ^[1-9][0-9]*$ ]] || die \
    'KV_CACHE_MEMORY_BYTES must be a positive integer'
  [[ "$AIPERF_CONCURRENCY" =~ ^[1-9][0-9]*$ ]] || die \
    'AIPERF_CONCURRENCY must be a positive integer'
  [[ "$AIPERF_DURATION_SECONDS" =~ ^[1-9][0-9]*$ ]] || die \
    'AIPERF_DURATION_SECONDS must be a positive integer'
  [[ "$AIPERF_MAX_COMPLETION_TOKENS" =~ ^[1-9][0-9]*$ ]] || die \
    'AIPERF_MAX_COMPLETION_TOKENS must be a positive integer'
  [[ "$AIPERF_RECOVERY_SECONDS" =~ ^[1-9][0-9]*$ ]] || die \
    'AIPERF_RECOVERY_SECONDS must be a positive integer'
  case "$MODEL_PRESET" in
    120b|qwen06b) ;;
    *) die 'MODEL_PRESET must be 120b or qwen06b' ;;
  esac
  case "$MODEL_CACHE_MODE" in
    dynamic) ;;
    static-nfs)
      [ -n "$MODEL_CACHE_NFS_SERVER" ] || die 'static-nfs requires MODEL_CACHE_NFS_SERVER'
      [ -n "$MODEL_CACHE_NFS_PATH" ] || die 'static-nfs requires MODEL_CACHE_NFS_PATH'
      ;;
    *) die 'MODEL_CACHE_MODE must be dynamic or static-nfs' ;;
  esac
}
