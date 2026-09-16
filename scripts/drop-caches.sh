#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

[ "$ALLOW_HOST_CACHE_DROP" = yes ] || die \
  'cache drop is host-wide; set ALLOW_HOST_CACHE_DROP=yes after reviewing CACHE_DROP_NODES'
[ -n "$CACHE_DROP_NODES" ] || die 'CACHE_DROP_NODES must list exact node names'
start_vcluster_forward

IFS=',' read -r -a nodes <<<"$CACHE_DROP_NODES"
info "host page cache will be dropped only on: ${nodes[*]}"

for node in "${nodes[@]}"; do
  pod="$(vc_kubectl -n default get pods -l app.kubernetes.io/name=snapshot -o json \
    | jq -r --arg node "$node" '.items[] | select(.spec.nodeName == $node and .status.phase == "Running") | .metadata.name' \
    | head -n 1)"
  [ -n "$pod" ] || die "no Running Snapshot agent found on node $node"
  info "dropping page cache on $node through $pod"
  vc_kubectl -n default exec "$pod" -c agent -- sh -c \
    'free -h; sync; echo 3 > /proc/sys/vm/drop_caches; free -h'
done
