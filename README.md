# Open IdP

Infrastructure for production workloads on Kubernetes, managed through a **GitOps flow** with Argo CD.

Git is the single source of truth: everything that runs in the cluster is declared here as a Helm chart. Argo CD is the only component installed by hand — from there on, it reconciles the rest of the platform from this repository.

> **Current base:** a local [KinD](https://kind.sigs.k8s.io/) cluster running Kubernetes **v1.37.0**, declared in [`00-local/kind/cluster.yaml`](00-local/kind/cluster.yaml) and created by `make bootstrap`.

## Repository layout

| Path | Purpose |
| --- | --- |
| [`00-core/`](00-core/) | Bootstrap layer, installed manually. Today it holds Argo CD and the App of Apps declaration. |
| [`01-applications/`](01-applications/) | One folder per workload, each a Helm chart. Argo CD syncs these automatically. |
| [`charts/`](charts/) | Local reusable charts. See [`argocd-app-of-apps`](charts/argocd-app-of-apps/README.md). |
| [`00-local/`](00-local/) | Everything that lives outside the cluster: the [KinD cluster declaration](00-local/kind/cluster.yaml) and the host nginx reverse proxy. |
| [`Makefile`](Makefile) | Wraps cluster creation, chart dependencies, the Argo CD install and the host proxy into `make bootstrap`. |

Vendored chart dependencies (`**/charts/*.tgz`) and `Chart.lock` files are git-ignored, so `helm dependency build` is required before installing.

## How the GitOps flow works

1. `00-core/argo` is installed manually with Helm. It bundles the upstream `argo-cd` chart plus the local `argocd-app-of-apps` chart.
2. `argocd-app-of-apps` renders, for each entry in its `applications` map, an `AppProject` and an `Application` pointing at `01-applications/<name>`.
3. Argo CD syncs each application (auto-sync with prune and self-heal), creating its namespace on the fly.
4. Adding a workload = a new folder in `01-applications/` plus one line in [`00-core/argo/values.yaml`](00-core/argo/values.yaml). No `kubectl apply`.

Application-specific parameters are documented in the [chart README](charts/argocd-app-of-apps/README.md).

## Platform components

| Component | Chart | Managed by | Purpose |
| --- | --- | --- | --- |
| Cluster | — (`00-local/kind`) | `make cluster` | KinD v1.37.0, one control-plane + one worker |
| Argo CD | `argo-cd` 10.7.1 | Manual (`00-core/argo`) | GitOps controller and UI |
| Traefik | `traefik` 41.4.0 | Argo CD | Ingress controller (CRD + Gateway API providers) |
| Elasticsearch | `elasticsearch` 8.x | Argo CD | Log storage |
| OpenTelemetry Collector | `opentelemetry-collector` 0.172.0 | Argo CD | Pod log collection (DaemonSet, filelog receiver) → Elasticsearch |
| Grafana | `grafana` 13.0.1 | Argo CD | Dashboards and log querying |

## Requirements

| Tool | Version used | Notes |
| --- | --- | --- |
| Docker | 20.10+ | KinD runs the nodes as containers; the host proxy is a container too |
| kind | 0.33+ | Older versions may not know the `v1.37.0` node image |
| kubectl | 1.30+ | Skew against the v1.37 control plane is fine within two minors |
| helm | 4.x | The bootstrap chart is installed with `helm upgrade --install` |
| make | any | Only used to sequence the commands below |

The host also needs a raised inotify budget — every KinD node runs its own
systemd and kubelet, and the kernel defaults (128 instances) are not enough for
a multi-node cluster. Without this, `kind create cluster` fails with
`could not find a log line that matches "Reached target .*Multi-User System.*"`:

```sh
sudo tee /etc/sysctl.d/99-kind.conf >/dev/null <<'EOF'
fs.inotify.max_user_instances = 512
fs.inotify.max_user_watches = 524288
EOF
sudo sysctl --system
```

`make preflight` checks this for you and is run automatically by `make bootstrap`.

## Bootstrap

```sh
make bootstrap
```

That single target is the whole setup, and it is safe to re-run:

0. **`preflight`** — verifies the host inotify sysctls above.
1. **`cluster`** — `kind create cluster --config 00-local/kind/cluster.yaml`, skipped if `open-idp` already exists. The node image is pinned by digest, and the control-plane node publishes port `30080` to the host as `127.0.0.1:8081`.
2. **`deps`** — `helm dependency build 00-core/argo`, required because vendored charts are git-ignored.
3. **`argo-init`** — installs Argo CD *without* the Applications. See [Bootstrap ordering](#bootstrap-ordering) below; skipped once the CRDs exist.
4. **`argo`** — installs the full bootstrap layer. Argo CD then syncs Traefik, Elasticsearch, OTel and Grafana on its own.
5. **`wait-traefik`** — blocks until Argo CD has created the `traefik.io` CRDs, i.e. the ingress path is live.
6. **`proxy`** — starts the host nginx container.

Useful during and after: `make status` lists the Argo CD applications and their sync state, `make down` deletes the cluster and stops the proxy.

> **Argo CD syncs from `origin/main`, not from your working tree.** Anything you
> change under [`01-applications/`](01-applications/) has to be committed and
> pushed before the cluster sees it. Only [`00-core/`](00-core/) is installed
> from local files, by Helm.

## Local access

Traffic reaches the cluster without any `port-forward`: Traefik's `web` entrypoint is a `NodePort` on a fixed port (`30080`), the KinD node publishes it as `127.0.0.1:8081`, and the host nginx container proxies `k8s.com` to it. The three numbers are coupled — changing one means changing [`00-local/kind/cluster.yaml`](00-local/kind/cluster.yaml), [`01-applications/traefik/values.yaml`](01-applications/traefik/values.yaml) and [`00-local/nginx/nginx.conf`](00-local/nginx/nginx.conf) together.

The only manual step left is DNS:

```sh
# add "127.0.0.1 k8s.com" to /etc/hosts — see 00-local/nginx/hosts.txt
```

The nginx container itself is started by `make proxy` (part of `make bootstrap`).

| URL | Service |
| --- | --- |
| `http://k8s.com/argo` | Argo CD UI |
| `http://k8s.com/grafana` | Grafana |

## Roadmap

The cluster is now declared and reproducible. What is still open:

- [x] Declare the KinD cluster (`00-local/kind/cluster.yaml`): node image pinned by digest, control-plane/worker topology, `extraPortMappings` for the Traefik entrypoint.
- [x] Wrap cluster creation, `helm dependency build` and the Argo CD install into one reproducible command (`make bootstrap`).
- [x] Document the host requirements.
- [ ] Replace the hardcoded Elasticsearch endpoint in [`01-applications/otel/values.yaml`](01-applications/otel/values.yaml) with the in-cluster service DNS name, so the collector config survives a cluster rebuild.
- [ ] Persist Elasticsearch data across `make down` (KinD `extraMounts` plus a `hostPath` volume), otherwise every rebuild starts from empty logs.
