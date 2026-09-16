# AI Engineer cold-start workshop

This workshop makes the checkpoint-restore advantage visible under real inference
load. Two otherwise equivalent NVIDIA Dynamo lanes begin with one Ready vLLM worker:

- **cold-start** starts a second worker normally;
- **snapshot** restores a second worker from a Ready Dynamo checkpoint.

AIPerf sends a fixed 6 requests/s to each selected lane before scale-up. The Grafana
chart shows serving time to first token (TTFT) under that load. Both lanes begin above
the 50 ms healthy boundary with one worker; the snapshot lane should recover first
when its restored worker joins, followed by the cold-start lane after model startup.

The terminal reports the separate lifecycle result: **container start to first token**.
That measurement excludes controller and scheduling delay, verifies a streamed token,
and requires `snapshot-restore-status.main=completed` for the snapshot worker.

## What the audience sees

Open Grafana before firing the demo:

```text
http://localhost:3030/d/workshop-vcluster/workshop-vcluster?from=now-15m&to=now&refresh=2s
```

The dashboard contains one red cold-start line and one green snapshot line, plus three
event markers: demo fired, snapshot completed, and cold-start completed. Grafana
refreshes every 2 seconds. Prometheus scrapes the workshop frontends every second; the
chart plots a 30-second rolling p50 at 10-second points to keep the comparison readable.

## Run the workshop

First configure the target cluster. Local configuration is ignored by Git:

```bash
cp config.env config.local.env
$EDITOR config.local.env
```

Install the environment before the workshop. Setup also creates a checkpoint, resets
the selected lanes to one worker, starts sustained AIPerf traffic, and opens the
Grafana port-forward:

```bash
./workshop.sh setup --both
```

When the dashboard shows the loaded one-worker state, fire the scale-up:

```bash
./workshop.sh demo --both
```

For another run, prepare first; `demo` deliberately performs no reset or load startup:

```bash
./workshop.sh prepare --both
./workshop.sh demo --both
```

To present the lanes one after the other, use matching prepare/demo modes:

```bash
./workshop.sh prepare --cold-start
./workshop.sh demo --cold-start

./workshop.sh prepare --restore
./workshop.sh demo --restore
```

`setup`, `prepare`, and `demo` all accept `--both`, `--cold-start`, or `--restore`.
With no arguments, `./workshop.sh` sets up or prepares `--both` as needed and then
fires the demo. Prefer the explicit two-command flow during a live presentation so
the audience never waits for preparation.

## Preconditions

- Bash 4+, `kubectl`, Helm 3, Git, `jq`, `curl`, and `envsubst`.
- Kubernetes 1.30+ with NVIDIA GPU nodes, the `nvidia` RuntimeClass, and the NVIDIA
  device plugin.
- Four free GPUs for the simultaneous 120B 1-to-2 comparison. The 120B preset is
  validated on B200. `MODEL_PRESET=qwen06b` is the smaller setup-test preset.
- An RWX storage class for checkpoint storage and, in dynamic mode, model storage.
- An NGC image-pull secret in the configured host namespace.
- Prometheus Operator and Grafana. Grafana must discover ConfigMaps labelled
  `grafana_dashboard=1` and expose the configured Prometheus and Loki datasources.
- Permission to install vcluster and its privileged host-path mapper.
- Registry, GitHub, Helm repository, and Hugging Face access unless all required
  artifacts are already cached.

By default, setup clones the configured Dynamo release into ignored `.state/`.
Set `DYNAMO_SOURCE_DIR` to reuse an existing checkout.

## Important configuration

- `MODEL_PRESET=120b|qwen06b` selects the workload manifest.
- The 120B preset requests 32 CPU cores and 192 GiB RAM per worker, with limits of
  127 cores and 256 GiB. Override `WORKER_CPU_*` and `WORKER_MEMORY_*` for the cluster.
- `KV_CACHE_MEMORY_BYTES=68719476736` allocates a 64 GiB KV cache. The cold-start
  lane's `--gpu-memory-utilization 0.01` only bypasses vLLM's percentage-based
  free-memory precheck; it does not limit the cache to 1%.
- `MODEL_CACHE_MODE=dynamic` creates a portable RWX cache. `static-nfs` binds an
  explicitly configured existing export with reclaim policy `Retain`.
- `ALLOW_PRIVILEGED_HPM=yes` is required to install the vcluster host-path mapper.
- `INSTALL_PODMONITORS=yes` installs workshop-scoped one-second scrapes.

## Commands

```text
./workshop.sh setup [MODE]    install, verify, and prepare the environment
./workshop.sh prepare [MODE]  reset to one worker and start fixed-rate load
./workshop.sh demo [MODE]     scale selected lane(s) from one to two workers
./workshop.sh status          show workloads, checkpoint, and Grafana URL
./workshop.sh reset           stop load and return both lanes to one worker
./workshop.sh grafana         install the dashboard and start its port-forward
./workshop.sh cache           drop cache only on explicitly approved nodes
./workshop.sh teardown        remove workshop-owned Kubernetes resources
```

`MODE` is `--both`, `--cold-start`, or `--restore` and defaults to `--both`.

Run evidence is written to `.state/runs/<timestamp>/summary.json` with patch results,
inference responses, pod timing, TTFT, and calculated speedups. `.state/` also contains
generated kubeconfigs, rendered YAML, logs, and local port-forward PIDs; it must never
be committed.

## Safety and cleanup

The page cache is host-wide. Cache dropping is disabled unless all three settings are
explicitly configured:

```bash
DROP_CACHES_BEFORE_DEMO=yes
CACHE_DROP_NODES=node-a,node-b
ALLOW_HOST_CACHE_DROP=yes
```

The script touches only the named nodes, but cache eviction can still affect unrelated
workloads. Coordinate the maintenance window first.

Teardown also requires an explicit acknowledgement:

```bash
CONFIRM_TEARDOWN=yes ./workshop.sh teardown
```

Static NFS model data is retained; teardown does not delete the underlying export.

## Repository layout

```text
.
├── README.md
├── config.env                  portable defaults
├── config.env.example          copyable configuration reference
├── workshop.sh                 entrypoint
├── scripts/                    setup, load, demo, Grafana, and cleanup
└── manifests/                  workloads and rendered-resource templates
```

The Kubernetes resource names remain `base` and `fast-criu` internally for compatibility,
but the workshop UI and operator workflow consistently call them **cold-start** and
**snapshot**.
