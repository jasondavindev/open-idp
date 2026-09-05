# k8s-cluster

Infrastructure for production workloads on Kubernetes, managed through a **GitOps flow** with Argo CD.

Git is the single source of truth: everything that runs in the cluster is declared here as a Helm chart. Argo CD is the only component installed by hand — from there on, it reconciles the rest of the platform from this repository.

> **Current base:** a local [KinD](https://kind.sigs.k8s.io/) cluster running Kubernetes **v1.37.0**. See [Cluster setup (TODO)](#cluster-setup-todo).

## Repository layout

| Path | Purpose |
| --- | --- |
| [`00-core/`](00-core/) | Bootstrap layer, installed manually. Today it holds Argo CD and the App of Apps declaration. |
| [`01-applications/`](01-applications/) | One folder per workload, each a Helm chart. Argo CD syncs these automatically. |
| [`charts/`](charts/) | Local reusable charts. See [`argocd-app-of-apps`](charts/argocd-app-of-apps/README.md). |
| [`00-local/`](00-local/) | Local-development helpers that live outside the cluster (host nginx reverse proxy). |

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
| Argo CD | `argo-cd` 10.7.1 | Manual (`00-core/argo`) | GitOps controller and UI |
| Traefik | `traefik` 41.4.0 | Argo CD | Ingress controller (CRD + Gateway API providers) |
| Elasticsearch | `elasticsearch` 8.x | Argo CD | Log storage |
| OpenTelemetry Collector | `opentelemetry-collector` 0.172.0 | Argo CD | Pod log collection (DaemonSet, filelog receiver) → Elasticsearch |
| Grafana | `grafana` 13.0.1 | Argo CD | Dashboards and log querying |

## Bootstrap

```sh
# 1. Create the cluster (see the TODO below — this step is not declared yet)
kind create cluster --image kindest/node:v1.37.0

# 2. Resolve chart dependencies
helm dependency build 00-core/argo

# 3. Install the bootstrap layer
helm upgrade --install argo 00-core/argo --namespace argo --create-namespace
```

Argo CD takes over from here and syncs Traefik, Elasticsearch, OTel and Grafana.

## Local access

Routing is exposed through a host nginx container that proxies into the cluster's Traefik entrypoint.

```sh
# add "127.0.0.1 k8s.com" to /etc/hosts — see 00-local/nginx/hosts.txt
docker compose -f 00-local/nginx/docker-compose.yaml up -d
```

| URL | Service |
| --- | --- |
| `http://k8s.com/argo` | Argo CD UI |
| `http://k8s.com/grafana` | Grafana |

## Cluster setup (TODO)

The Kubernetes cluster itself is **not declared in this repository yet** — it is currently created by hand with KinD (Kubernetes v1.37.0), which makes the base layer non-reproducible and undocumented.

- [ ] Add a `kind` cluster declaration (`kind-config.yaml`): node image pinned to `v1.37.0`, control-plane/worker topology, `extraPortMappings` for the Traefik entrypoint the local nginx proxy targets.
- [ ] Add a bootstrap script or `Makefile` wrapping cluster creation, `helm dependency build` and the Argo CD install into one reproducible command.
- [ ] Document the host requirements (Docker, kind, kubectl, helm versions).
- [ ] Replace the hardcoded Elasticsearch endpoint in [`01-applications/otel/values.yaml`](01-applications/otel/values.yaml) with the in-cluster service DNS name, so the collector config survives a cluster rebuild.
- [ ] Plan the path off KinD for real production workloads (managed control plane or kubeadm), keeping the same GitOps layout.
