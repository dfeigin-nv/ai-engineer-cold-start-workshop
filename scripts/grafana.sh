#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

case "${1:-}" in
  '') ;;
  --preserve) ;;
  *) die 'usage: grafana.sh [--preserve]' ;;
esac

for command_name in kubectl curl jq envsubst; do
  require_command "$command_name"
done
validate_config
render_manifests

host_kubectl -n "$MONITORING_NAMESPACE" get service "$GRAFANA_SERVICE" >/dev/null

if [ "$INSTALL_PODMONITORS" = yes ]; then
  host_kubectl get crd podmonitors.monitoring.coreos.com >/dev/null 2>&1 || \
    die 'PodMonitor CRD missing; install a Prometheus Operator stack first'
  host_kubectl apply -f "$RENDERED_DIR/podmonitors.yaml"
fi
host_kubectl apply -f "$RENDERED_DIR/grafana-dashboard.yaml"
start_grafana_forward

password="$(grafana_password)"
dashboard="$(host_kubectl -n "$MONITORING_NAMESPACE" get configmap \
  workshop-vcluster-dashboard -o json \
  | jq -c '.data["workshop-vcluster.json"] | fromjson')"
dashboard_payload="$(jq -nc --argjson dashboard "$dashboard" \
  '{dashboard:$dashboard,overwrite:true}')"
curl -fsS -u "admin:${password}" -H 'Content-Type: application/json' \
  -X POST "${GRAFANA_URL}/api/dashboards/db" -d "$dashboard_payload" >/dev/null
case "$AIPERF_MODE" in
  both)
    push_demo_status base '🔴 Run the demo'
    push_demo_status fast-criu '🟢 Run the demo'
    ;;
  cold-start) push_demo_status base '🔴 Run the demo' ;;
  restore) push_demo_status fast-criu '🟢 Run the demo' ;;
esac
attempts=0
while [ "$attempts" -lt 30 ]; do
  if curl -fsS -u "admin:${password}" \
      "${GRAFANA_URL}/api/dashboards/uid/workshop-vcluster" >/dev/null 2>&1; then
    info "Grafana is running in the background: $GRAFANA_DASHBOARD_URL"
    exit 0
  fi
  sleep 1
  attempts=$((attempts + 1))
done

die 'Grafana is reachable, but the dashboard sidecar did not import the dashboard'
