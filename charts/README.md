## ArgoCD Sync Waves

| Sync Wave Number | Name | Annotations |
| --- | --- | --- |
| `-1` | Pre all | `argocd.argoproj.io/sync-wave: -1` |
| `0` | default / unset | `argocd.argoproj.io/sync-wave: 0` |
| `1` | Configs and secrets | `argocd.argoproj.io/sync-wave: 1` |
| `2` | Addons Pre | `argocd.argoproj.io/sync-wave: 2` |
| `3` | Addons | `argocd.argoproj.io/sync-wave: 3` |
| `4` | Addons Post | `argocd.argoproj.io/sync-wave: 4` |
| `5` | Compute: Deployments, Crons, Jobs, etc. | `argocd.argoproj.io/sync-wave: 5` |
| `6` | Services and Routes | `argocd.argoproj.io/sync-wave: 6` |
| `7` | Post all | `argocd.argoproj.io/sync-wave: 7` |
