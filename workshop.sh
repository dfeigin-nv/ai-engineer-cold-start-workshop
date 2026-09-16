#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command_name="${1:-run}"

case "$command_name" in
  run)
    if ! "$ROOT_DIR/scripts/status.sh" --quiet; then
      "$ROOT_DIR/scripts/setup.sh" --both
    elif [ ! -f "$ROOT_DIR/.state/prepared.json" ]; then
      "$ROOT_DIR/scripts/prepare.sh" --both
    fi
    exec "$ROOT_DIR/scripts/demo.sh" --both
    ;;
  setup|prepare|demo|status|reset|grafana|teardown)
    shift || true
    exec "$ROOT_DIR/scripts/${command_name}.sh" "$@"
    ;;
  cache)
    shift || true
    exec "$ROOT_DIR/scripts/drop-caches.sh" "$@"
    ;;
  *)
    echo "usage: ./workshop.sh [run|setup [--both|--cold-start|--restore]|prepare [--both|--cold-start|--restore]|demo [--both|--cold-start|--restore]|status|reset|cache|grafana|teardown]" >&2
    exit 2
    ;;
esac
