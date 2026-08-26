# homelab-gitops

Declarative state for a single-node k3s cluster, reconciled by ArgoCD.

This repo is public. It is safe only because Secrets and anything naming a
private address stay out of it — see [Not in git](#not-in-git).

## Layout

```
bootstrap/root.yaml     the one object applied by hand; watches apps/
projects/homelab.yaml   AppProject every Application belongs to
apps/                   one ArgoCD Application per workload
manifests/              the Kubernetes resources themselves
```

`apps/` is the app-of-apps, so adding a workload is a commit, not a `kubectl apply`.

## Workloads

| App | Path | Auto-sync | Notes |
|---|---|---|---|
| `crypto-bot` | `manifests/crypto-bot` | **yes**, prune + self-heal | Image tag committed by CI |
| `postgres` | `manifests/postgres` | no | Live data; adopted from a hand-created StatefulSet |
| `mlops` | `manifests/mlops/base` | no | Contains completed Jobs with immutable specs |
| `argo-workflows` | `manifests/argo-workflows` | no | Upstream v4.1.2 + local overlays |
| `argocd` | `manifests/argocd` | no, permanently | Self-management |

Only `crypto-bot` self-heals today. The rest are checked in so their state is
recorded and upgrades become reviewed diffs; each needs its first diff eyeballed
before it is trusted to reconcile itself. Reasons are in each `apps/` file.

## Bootstrap

Both Argo projects are already installed; this only wires them to the repo.

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl apply -f projects/homelab.yaml
kubectl apply -f bootstrap/root.yaml
kubectl apply -f local/ingresses.yaml   # not in git, see below
```

Then verify before trusting anything: `argocd app diff crypto-bot` should be empty.

## Not in git

**Secrets.** Created by hand; the one part of the system not reproducible from
this repo. A rebuild means recreating these first, then bootstrapping.

| Secret | Namespace | Holds |
|---|---|---|
| `crypto-bot-secret` | `default` | Telegram token, exchange API keys, `DATABASE_URL` |
| `postgres-secret` | `default` | Postgres superuser credentials |
| `mlops-secrets` | `mlops` | Per-database DSNs, MinIO credentials |
| `postgres-admin` | `mlops` | Bootstrap Job superuser creds; delete after it runs |

`manifests/mlops/base/secrets.example.yaml` is a `CHANGE_ME` template, excluded
from its own kustomization. Fill in a copy, apply it, don't commit it.

**Ingresses.** `local/ingresses.yaml` holds the Argo, MLflow and API Ingresses.
Their hostnames are nip.io names that encode the node's LAN and Tailscale
addresses, which cannot go in a public repo — and nip.io has no form that omits
the IP. Applied by hand, and gitignored.

## Releases

crypto-bot's release workflow commits the new image tag into
`manifests/crypto-bot/deployment.yaml` on every `v*.*.*` push; ArgoCD rolls it
out. That line is the deploy — reverting it is a rollback.

## Disk pressure

The root disk is 32 GB and shared between the bot and the mlops stack. On
2026-08-26 it crossed kubelet's eviction threshold and evicted `crypto-bot`,
which was using 2.4 MB, because an absent `ephemeral-storage` request counts as
zero when ranking victims and every pod sat at priority 0.

The fix is in `manifests/crypto-bot/`: a PriorityClass and an explicit
`ephemeral-storage` request. Neither creates disk space — if evictions recur the
node is genuinely full and the answer is capacity, not manifests.
