#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

[ "${CONFIRM_TEARDOWN:-no}" = yes ] || die \
  'teardown deletes the vcluster namespace; rerun with CONFIRM_TEARDOWN=yes'

stop_pid_file "$GRAFANA_PF_PID_FILE"
stop_pid_file "$VCLUSTER_PF_PID_FILE"
stop_pid_file "$BASE_FRONTEND_PF_PID_FILE"
stop_pid_file "$FAST_FRONTEND_PF_PID_FILE"
host_kubectl -n "$MONITORING_NAMESPACE" delete podmonitor \
  workshop-vcluster-frontend workshop-vcluster-worker --ignore-not-found
host_kubectl -n "$MONITORING_NAMESPACE" delete configmap \
  workshop-vcluster-dashboard --ignore-not-found
helm uninstall vcluster-hpm --kube-context "$HOST_CONTEXT" \
  -n "$HOST_NAMESPACE" --ignore-not-found
helm uninstall "$VCLUSTER_NAME" --kube-context "$HOST_CONTEXT" \
  -n "$HOST_NAMESPACE" --ignore-not-found
host_kubectl delete namespace "$HOST_NAMESPACE" --ignore-not-found
if [ "$MODEL_CACHE_MODE" = static-nfs ]; then
  host_kubectl delete persistentvolume "${VCLUSTER_NAME}-shared-model-cache" \
    --ignore-not-found
  info 'deleted only the PV object; the configured NFS export was not deleted'
fi
info 'teardown complete'
