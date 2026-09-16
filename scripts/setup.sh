#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

case "${1:---both}" in
  --both|--cold-start|--restore) setup_mode="${1:---both}" ;;
  *) die 'usage: ./workshop.sh setup [--both|--cold-start|--restore]' ;;
esac
[ "$#" -le 1 ] || die 'usage: ./workshop.sh setup [--both|--cold-start|--restore]'

for command_name in kubectl helm git jq curl envsubst; do
  require_command "$command_name"
done
validate_config

host_kubectl cluster-info >/dev/null
render_manifests

if ! helm repo list -o json | jq -e '.[] | select(.name == "loft")' >/dev/null; then
  info 'adding the loft Helm repository'
  helm repo add loft https://charts.loft.sh
fi

info "installing vcluster ${VCLUSTER_NAME} in ${HOST_NAMESPACE}"
helm upgrade --install "$VCLUSTER_NAME" loft/vcluster \
  --version "$VCLUSTER_VERSION" \
  --kube-context "$HOST_CONTEXT" \
  -n "$HOST_NAMESPACE" --create-namespace \
  -f "$ROOT_DIR/manifests/vcluster-values.yaml" \
  --wait --timeout=10m

info 'installing the persistent AIPerf runner'
host_kubectl apply -f "$RENDERED_DIR/aiperf-runner.yaml"
host_kubectl -n "$HOST_NAMESPACE" rollout status deployment/workshop-aiperf-runner \
  --timeout=10m

if [ "$INSTALL_HPM" = yes ]; then
  [ "$ALLOW_PRIVILEGED_HPM" = yes ] || die \
    'vcluster-hpm is privileged and host-wide; review it, then set ALLOW_PRIVILEGED_HPM=yes'
  info 'installing the vcluster host-path mapper'
  helm upgrade --install vcluster-hpm loft/vcluster-hpm \
    --version "$HPM_VERSION" \
    --kube-context "$HOST_CONTEXT" \
    -n "$HOST_NAMESPACE" \
    -f "$RENDERED_DIR/hpm-values.yaml" \
    --wait --timeout=5m
fi

start_vcluster_forward

info "copying ${NGC_SECRET_NAME} into the vcluster"
host_kubectl -n "$NGC_SECRET_SOURCE_NAMESPACE" get secret "$NGC_SECRET_NAME" -o json \
  | jq --arg name "$NGC_SECRET_NAME" \
      '{apiVersion:"v1",kind:"Secret",metadata:{name:$name,namespace:"default"},type:.type,data:.data}' \
  | vc_kubectl apply -f -

if [ "$MODEL_CACHE_MODE" = static-nfs ]; then
  info 'binding the configured existing NFS model cache'
  host_kubectl apply -f "$RENDERED_DIR/host-model-cache-pv.yaml"
  vc_kubectl apply -f "$RENDERED_DIR/storage-static.yaml"
else
  info "creating model and snapshot storage with ${STORAGE_CLASS}"
  vc_kubectl apply -f "$RENDERED_DIR/storage-dynamic.yaml"
fi

if [ -n "$DYNAMO_SOURCE_DIR" ]; then
  DYNAMO_DIR="$(cd "$DYNAMO_SOURCE_DIR" && pwd)"
else
  DYNAMO_DIR="$STATE_DIR/dynamo-${DYNAMO_VERSION}"
  if [ ! -d "$DYNAMO_DIR/.git" ]; then
    info "cloning Dynamo v${DYNAMO_VERSION}"
    git clone --depth 1 --branch "v${DYNAMO_VERSION}" \
      "$DYNAMO_REPO_URL" "$DYNAMO_DIR"
  fi
fi

PLATFORM_CHART="$DYNAMO_DIR/deploy/helm/charts/platform"
SNAPSHOT_CHART="$DYNAMO_DIR/deploy/helm/charts/snapshot"
[ -f "$PLATFORM_CHART/Chart.yaml" ] || die "platform chart not found: $PLATFORM_CHART"
[ -f "$SNAPSHOT_CHART/Chart.yaml" ] || die "snapshot chart not found: $SNAPSHOT_CHART"

info 'building Dynamo platform chart dependencies'
helm dependency build "$PLATFORM_CHART"

info 'installing Dynamo platform inside the vcluster'
helm upgrade --install dynamo-platform "$PLATFORM_CHART" \
  --kubeconfig "$VCLUSTER_KUBECONFIG" --kube-context "$VCLUSTER_CONTEXT" \
  -n dynamo-system --create-namespace \
  --set dynamo-operator.upgradeCRD=true \
  --set dynamo-operator.checkpoint.enabled=true \
  --set dynamo-operator.checkpoint.seccomp.disabled=true \
  --set dynamo-operator.controllerManager.manager.image.repository=nvcr.io/nvidia/ai-dynamo/kubernetes-operator \
  --set "dynamo-operator.controllerManager.manager.image.tag=${DYNAMO_VERSION}" \
  --set "dynamo-operator.imagePullSecrets[0].name=${NGC_SECRET_NAME}" \
  --set dynamo.metrics.podMonitors.enabled=false \
  --set global.etcd.install=true \
  --set "etcd.persistence.storageClass=${STORAGE_CLASS}" \
  --set "nats.config.jetstream.fileStore.pvc.storageClassName=${STORAGE_CLASS}" \
  --wait --timeout=15m

info 'installing the Snapshot agent inside the vcluster'
helm upgrade --install snapshot-agent "$SNAPSHOT_CHART" \
  --kubeconfig "$VCLUSTER_KUBECONFIG" --kube-context "$VCLUSTER_CONTEXT" \
  -n default -f "$ROOT_DIR/manifests/snapshot-agent-values.yaml" \
  --set "daemonset.image.tag=${DYNAMO_VERSION}" \
  --wait --timeout=10m

info "deploying the ${MODEL_PRESET} comparison lanes"
if [ "$MODEL_PRESET" = 120b ]; then
  lane_manifest="$RENDERED_DIR/lanes-120b.yaml"
else
  lane_manifest="$RENDERED_DIR/lanes-qwen06b.yaml"
fi
vc_kubectl apply -f "$lane_manifest"
wait_for_dgds_ready 1200 || die 'lane DGDs did not reconcile the applied generation within 20 minutes'

info 'waiting for a Ready checkpoint'
wait_for_current_checkpoint 1800 \
  || die 'the checkpoint referenced by the current fast lane did not become Ready within 30 minutes'

"$ROOT_DIR/scripts/grafana.sh"
"$ROOT_DIR/scripts/prepare.sh" "$setup_mode"
info 'setup complete'
