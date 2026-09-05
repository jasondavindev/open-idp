# argocd-app-of-apps

Helm chart that bootstraps an Argo CD **App of Apps**. For every entry in `applications`, the chart renders:

- an `Application` (`argoproj.io/v1alpha1`) pointing at `<repository>/<pathPrefix>/<name>`, and
- a dedicated `AppProject` named after the application.

Everything else is derived by convention, so declaring a new application is a single line in `values.yaml`.

## Conventions

| Aspect | Rule |
| --- | --- |
| Source path | `<pathPrefix>/<application name>` in `repository` |
| Project | One `AppProject` per application, named after it |
| Destination namespace | Same as the application name (created via `CreateNamespace=true`) |
| Sync policy | Automated with `prune`, `selfHeal`, `allowEmpty: false`; retry 3x (5s backoff, factor 2, max 1m) |
| Sync options | `CreateNamespace=true`, `ApplyOutOfSyncOnly=true` |
| Project permissions | Permissive: any destination, any source repo, any cluster resource |

## Global parameters

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `repository` | string | `https://github.com/jasondavindev/open-idp.git` | Git repository holding the application manifests. |
| `pathPrefix` | string | `01-applications` | Directory inside the repository that contains one folder per application. |
| `targetRevision` | string | `main` | Git revision (branch, tag or commit) tracked by every `Application`. |
| `cluster` | string | `in-cluster` | Argo CD destination cluster **name** (not the API server URL). |
| `argoNamespace` | string | `argo` | Namespace where the `Application` objects are created. |
| `namespace` | string | `argo` | Namespace where the `AppProject` objects are created. |
| `applications` | map | `{}` | Applications to generate, keyed by name. See below. |

> `argoNamespace` and `namespace` are separate keys but must normally hold the same value — set both when Argo CD does not run in `argo`.

## Per-application parameters

Each key under `applications` is the application name; the value is an object with the fields below (`{}` accepts all defaults).

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `kind` | string | `helm` | Rendering engine for the source folder. `helm` or `kustomize` (case-insensitive). |
| `disableAutoSync` | bool | `false` | When `true`, renders an empty `automated` block, so the application only syncs on demand. |

### Behaviour per `kind`

| `kind` | Generated source block | Folder must contain |
| --- | --- | --- |
| `helm` | `helm.valueFiles: [values.yaml]` and the parameter `global.name=<application name>` | `Chart.yaml` + `values.yaml` |
| `kustomize` | `kustomize.commonAnnotations: {kustomize/app: <application name>}` | `kustomization.yaml` |

**Kustomize requires `--enable-helm` on the Argo CD side.** Without it, a `kustomization.yaml` that inflates charts through `helmCharts:` fails to build. Enable it once in `argocd-cm` — this repository does it in [`00-core/argo/values.yaml`](../../00-core/argo/values.yaml):

```yaml
argo:
  configs:
    cm:
      kustomize.buildOptions: "--enable-helm"
```

## Usage

As a subchart (how this repository consumes it — see [`00-core/argo`](../../00-core/argo)):

```yaml
# 00-core/argo/Chart.yaml
dependencies:
  - name: argocd-app-of-apps
    version: 0.1.0
    repository: file://../../charts/argocd-app-of-apps
    alias: app-of-apps
```

```yaml
# 00-core/argo/values.yaml
app-of-apps:
  repository: https://github.com/jasondavindev/open-idp.git
  pathPrefix: 01-applications
  targetRevision: main

  applications:
    traefik: {}
    elasticsearch: {}
    grafana: {}
    otel:
      kind: kustomize
      disableAutoSync: true
```

Standalone:

```sh
helm template argo-apps ./charts/argocd-app-of-apps -f my-values.yaml | kubectl apply -f -
```

The example above expects the repository layout:

```
01-applications/
├── traefik/
│   ├── Chart.yaml          # chart definition (dependencies, version)
│   └── values.yaml         # read via helm.valueFiles
├── elasticsearch/
│   ├── Chart.yaml
│   └── values.yaml
├── grafana/
│   ├── Chart.yaml
│   └── values.yaml
└── otel/
    └── kustomization.yaml  # may use helmCharts: thanks to --enable-helm
```

## Adding an application

1. Create `01-applications/<name>/` in the repository with either a Helm chart (`Chart.yaml` + `values.yaml`) or a `kustomization.yaml`.
2. Add `<name>: {}` under `applications` (plus `kind: kustomize` when it is not a Helm chart).
3. Commit — Argo CD creates the project, the namespace and syncs the application.
