# Open IdP

Infrastructure for production workloads on Kubernetes, managed through a **GitOps flow** with Argo CD.

Git is the single source of truth: everything that runs in the cluster is declared here as a Helm chart. Argo CD is the only component installed by hand — from there on, it reconciles the rest of the platform from this repository.

> **Current base:** a local [KinD](https://kind.sigs.k8s.io/) cluster running Kubernetes **v1.37.0**, declared in [`00-local/kind/cluster.yaml`](00-local/kind/cluster.yaml) and created by `make bootstrap`.

## Repository layout

| Path | Purpose |
| --- | --- |
| [`00-core/`](00-core/) | Bootstrap layer, installed manually. Today it holds Argo CD and the App of Apps declaration. |
| [`01-applications/`](01-applications/) | One folder per workload, each a Helm chart. Argo CD syncs these automatically. |
| [`charts/`](charts/) | Local reusable charts, consumed by path (`file://`). See [Local charts](#local-charts). |
| [`00-local/`](00-local/) | Everything that lives outside the cluster: the [KinD cluster declaration](00-local/kind/cluster.yaml) and the host nginx reverse proxy. |
| [`Makefile`](Makefile) | Wraps cluster creation, chart dependencies, the Argo CD install and the host proxy into `make bootstrap`. |

Vendored chart dependencies (`**/charts/*.tgz`) and `Chart.lock` files are git-ignored, so `helm dependency build` is required before installing.

## How the GitOps flow works

1. `00-core/argo` is installed manually with Helm. It bundles the upstream `argo-cd` chart plus two instances of the local `argocd-app-of-apps` chart: `app-of-apps` for platform components and `idp-apps` for developer applications.
2. `app-of-apps` renders, for each entry in its `applications` map, an `AppProject` and an `Application` pointing at `01-applications/<name>` in this repository — the platform components listed below.
3. `idp-apps` does the same, but pointing at `apps/<name>` in the [`open-idp-apps`](https://github.com/jasondavindev/open-idp-apps) catalog repository — one entry per developer application registered through the [`deploy.yaml`](.github/workflows/deploy.yaml) reusable workflow (see [Reusable workflows](#reusable-workflows)).
4. Argo CD syncs each application (auto-sync with prune and self-heal), creating its namespace on the fly.
5. Adding a platform workload = a new folder in `01-applications/` plus one line in [`00-core/argo/values.yaml`](00-core/argo/values.yaml). Registering a developer application = wiring its CI to `deploy.yaml`, which commits it into `open-idp-apps` automatically. No `kubectl apply` either way.

Application-specific parameters are documented in the [chart README](charts/argocd-app-of-apps/README.md).

## Local charts

Reusable charts kept in this repository. The shared Argo CD sync-wave convention
they all follow is documented in [`charts/README.md`](charts/README.md).

| Chart | Version | Purpose | Distribution | Reference |
| --- | --- | --- | --- | --- |
| [`argocd-app-of-apps`](charts/argocd-app-of-apps/) | 0.1.0 | Renders one `AppProject` + one `Application` per entry in `applications`, pointing at `01-applications/<name>`. The entry point of the whole GitOps flow. | By path only — a subchart of [`00-core/argo`](00-core/argo/), aliased `app-of-apps` | [README](charts/argocd-app-of-apps/README.md) |
| [`web`](charts/web/) | 1.0.0 | Generic HTTP workload: `Deployment`, `ClusterIP` `Service`, Traefik `IngressRoute`, `ServiceAccount`, plus optional `HorizontalPodAutoscaler` and `PodDisruptionBudget`. | Published as an OCI chart (see below); not consumed by any application in this repository yet | [README](charts/web/README.md) |

### Publishing

[`.github/workflows/charts.yaml`](.github/workflows/charts.yaml) runs on every push to `main`
that touches `charts/**`. For each chart in its `matrix.chart` list (today: `web`) it runs
`helm dep build`, `helm package` and `helm push` to `oci://registry-1.docker.io/<HELM_REGISTRY_USER>`
(today [`jasoncarneiro`](https://hub.docker.com/u/jasoncarneiro)), authenticating with the
`HELM_REGISTRY_USER` / `HELM_REGISTRY_PASSWORD` repository secrets.

The version pushed is the `version` field of the chart's `Chart.yaml` — bump it in the same
commit, otherwise the push overwrites the existing tag. Charts absent from the matrix
(`argocd-app-of-apps`) are never packaged and stay path-only.

## Reusable workflows

Two `workflow_call` workflows in [`.github/workflows/`](.github/workflows/) are published for
application repositories to consume as CI/CD building blocks — they are never triggered directly
in this repository.

| Workflow | Purpose | Inputs | Secrets | Outputs |
| --- | --- | --- | --- | --- |
| [`build.yaml`](.github/workflows/build.yaml) | Builds the calling repo's `Dockerfile` with `docker buildx`, using a registry-backed cache (`<image>:cache`), and pushes the image tagged with the commit SHA. | — | `CONTAINER_REGISTRY`, `REGISTRY_USER`, `REGISTRY_PASSWORD` | `full_image_name`, `image_tag` |
| [`deploy.yaml`](.github/workflows/deploy.yaml) | Copies the calling repo's `.idp/` manifests into the [`open-idp-apps`](https://github.com/jasondavindev/open-idp-apps) catalog repository (`apps/<app_name>/`), sets `global.image.tag` to the given `image_tag` in its `values.yaml`, then commits (`[skip ci]`) and force-pushes to the catalog repo's `main`. This is what registers the app under `idp-apps` in Argo CD — see [How the GitOps flow works](#how-the-gitops-flow-works). No-ops if the file is already up to date. | `image_tag` (required) | `pat_write_token` — a PAT with `contents: write` on `open-idp-apps` | — |

`<app_name>` is derived from the calling repository's name (the part of `GITHUB_REPOSITORY` after
the `/`), and `deploy.yaml` requires `.idp/values.yaml` to already exist in that repo, plus a
matching `apps/<app_name>/` folder and `idp-apps.applications` entry already present in
`open-idp-apps` / [`00-core/argo/values.yaml`](00-core/argo/values.yaml).

Typical caller, in an application repository:

```yaml
jobs:
  build:
    uses: jasondavindev/open-idp/.github/workflows/build.yaml@main
    secrets:
      CONTAINER_REGISTRY: ${{ secrets.CONTAINER_REGISTRY }}
      REGISTRY_USER: ${{ secrets.REGISTRY_USER }}
      REGISTRY_PASSWORD: ${{ secrets.REGISTRY_PASSWORD }}

  deploy:
    needs: build
    uses: jasondavindev/open-idp/.github/workflows/deploy.yaml@main
    with:
      image_tag: ${{ needs.build.outputs.image_tag }}
    secrets:
      pat_write_token: ${{ secrets.OPEN_IDP_APPS_TOKEN }}
```

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
| yq | 4.x | Reads the chart dependencies the bootstrap pass has to disable |

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
- [x] Replace the hardcoded Elasticsearch endpoint in [`01-applications/otel/values.yaml`](01-applications/otel/values.yaml) with the in-cluster service DNS name, so the collector config survives a cluster rebuild.
- [ ] Persist Elasticsearch data across `make down` (KinD `extraMounts` plus a `hostPath` volume), otherwise every rebuild starts from empty logs.
