# web

Generic Helm chart for HTTP applications. A release exposes a single container over
port `80` through a Traefik `IngressRoute`, with probes, resource limits and optional
autoscaling / disruption budget derived from a handful of values.

## Provisioned resources

| Resource | API version | Name | Sync wave | Condition | Purpose |
| --- | --- | --- | --- | --- | --- |
| `Deployment` | `apps/v1` | `web.fullname` | `5` | always | Runs the application container. `RollingUpdate` (`maxSurge: 25%`, `maxUnavailable: 0`), `progressDeadlineSeconds: 60`, `revisionHistoryLimit: 3`, `terminationGracePeriodSeconds: 60`, `enableServiceLinks: false`. Replicas are pinned to `1` unless `scaling` is set (then the HPA owns them). |
| `Service` | `v1` | `web.fullname` | `6` | always | `ClusterIP` publishing port `80` to the container's `http` port. |
| `IngressRoute` | `traefik.io/v1alpha1` | `.Release.Name` | `6` | always | Traefik route on the `web` entrypoint matching `Host(route.host) && PathPrefix(route.pathPrefix)`, forwarding to `<release>-web:80`. |
| `ServiceAccount` | `v1` | `.Release.Name` | — | always | Identity used by the pods (`automountServiceAccountToken: true`). |
| `HorizontalPodAutoscaler` | `autoscaling/v2` | `web.fullname` | `7` | `scaling` is set | Scales the Deployment between `scaling.min` and `scaling.max` on average CPU utilization (`scaling.target`). |
| `PodDisruptionBudget` | `policy/v1` | `web.fullname` | `7` | `pdb` is set | Protects the pods during voluntary disruptions. |

Additional behaviour baked into the Deployment:

| Aspect | Rule |
| --- | --- |
| Secrets | Not managed yet — `templates/secrets.yaml` is a placeholder until an external secrets controller is available. |
| Security context | `allowPrivilegeEscalation: false`; drops `all` capabilities and adds back `CHOWN`, `NET_BIND_SERVICE`, `SETGID`, `SETUID`. |
| High availability | `topologySpreadConstraints` with `maxSkew: 1` over `kubernetes.io/hostname`, `whenUnsatisfiable: ScheduleAnyway`. |
| Resources | `requests` = `cpu` + `memory`; `limits` = `memory` only (no CPU limit, so the pod is never CPU-throttled). |
| Labels | `app.kubernetes.io/{component,name,instance,version,managed-by}` plus `opentelemetry/service` and `opentelemetry/version`. |

## Parameters

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `global.image.repository` | string | _(required)_ | Container image repository. Injected by the CD pipeline / parent chart — see the note below. |
| `global.image.tag` | string | _(required)_ | Container image tag. Also used as `opentelemetry/version`. |
| `name` | string | `web` | Application name. |
| `nameOverride` | string | `""` | Overrides the chart name used in `web.name` / `web.fullname`. |
| `fullnameOverride` | string | `""` | Replaces the generated fullname entirely. |
| `env` | map | _unset_ | Non-sensitive environment variables, rendered as `name`/`value` pairs. |
| `command` | list | _unset_ | Entrypoint override. The first item becomes `command`, the remaining ones `args`. |
| `port` | int | `8080` | Container port. Exposed as the `http` port and as the `PORT` environment variable. |
| `route.host` | string | `k8s.com` | Host matched by the Traefik `IngressRoute`. |
| `route.pathPrefix` | string | `/` | Path prefix matched by the Traefik `IngressRoute`. |
| `cpu` | string | `100m` | CPU request (falls back to `100m` when empty). |
| `memory` | string | `100Mi` | Memory request **and** limit. |
| `scaling` | object | _unset_ | Enables the `HorizontalPodAutoscaler`. When unset, the Deployment keeps a fixed single replica. |
| `scaling.min` | int | — | Minimum replicas. |
| `scaling.max` | int | — | Maximum replicas. Rendering **fails** when equal to `scaling.min`. |
| `scaling.target` | int | — | Target average CPU utilization, in percent. |
| `pdb` | object | _unset_ | Enables the `PodDisruptionBudget`. Only one of the two fields below may be set — rendering **fails** otherwise. |
| `pdb.minAvailable` | int \| string | — | Minimum pods that must stay available. |
| `pdb.maxUnavailable` | int \| string | `1` | Maximum pods that may be unavailable (used when `minAvailable` is absent). |
| `livenessProbe` | object | see below | Liveness probe. |
| `readinessProbe` | object | see below | Readiness probe. |
| `startupProbe` | object | see below | Startup probe (`initialDelaySeconds: 1`). |

> **Image values.** The Deployment reads `global.image.repository` / `global.image.tag`, while `values.yaml` ships a
> commented-out local `image` block. Set the values under `global` (globals are inherited by subcharts and are what the
> CD pipeline injects) — a plain `image.tag` is ignored and the pod renders with an empty tag.

### Probe parameters

The three probes share the same shape and are rendered by the `web.probes` helper.

| Key | Type | Default (`liveness` / `readiness`) | Default (`startup`) | Description |
| --- | --- | --- | --- | --- |
| `path` | string | `/healthz` | `/healthz` | HTTP path probed on the `http` port. Ignored when `exec` is set. |
| `exec` | list | _unset_ | _unset_ | Command to run instead of the HTTP check. Takes precedence over `path`. |
| `failureThreshold` | int | `5` | `5` | Consecutive failures before the probe is considered failed. |
| `initialDelaySeconds` | int | `10` | `1` | Delay before the first probe. |
| `periodSeconds` | int | `5` | `5` | Interval between probes. |
| `timeoutSeconds` | int | `5` | `5` | Probe timeout. |

## Usage

```yaml
# 01-applications/<name>/values.yaml
global:
  image:
    repository: ghcr.io/acme/web
    tag: "1.4.2"

port: 3000

route:
  host: api.k8s.com
  pathPrefix: /v1

cpu: 200m
memory: 256Mi

env:
  LOG_LEVEL: info

scaling:
  min: 2
  max: 5
  target: 80

pdb:
  maxUnavailable: 1
```

As a subchart:

```yaml
# 01-applications/<name>/Chart.yaml
dependencies:
  - name: web
    version: "1.0.0"
    repository: "oci://registry-1.docker.io/jasoncarneiro"
```

Standalone:

```sh
helm template my-app ./charts/web -f my-values.yaml | kubectl apply -f -
```
