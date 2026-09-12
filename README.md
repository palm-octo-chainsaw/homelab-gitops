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
| `crypto-bot` | `manifests/crypto-bot` | self-heal + prune | Image tag committed by CI |
| `postgres` | `manifests/postgres` | self-heal | Live data, so prune stays off |
| `sealed-secrets` | `manifests/sealed-secrets` | self-heal | Controller mints its own key Secret at runtime, so prune stays off |
| `airflow` | upstream chart + `manifests/airflow` | no | Chart's migrate and create-user Jobs are sync hooks |
| `mlops` | `manifests/mlops/base` | no | Self-deleting Job would cause an hourly recreate loop |
| `hermes` | vendored chart + `manifests/hermes` | no | Adopting a live helm CLI release |
| `argocd` | `manifests/argocd` | no, permanently | Self-management |

`postgres` reproduces live state byte-identically, which is why it is trusted to
self-heal. Neither it nor `sealed-secrets` prunes, for the different reasons
above: one would cost data, the other would delete a Secret that was never in
git. `airflow` and `mlops` both re-run Jobs on every drift check, so auto-sync
would loop; the fixes are described in their `apps/` files. `argocd` stays
manual permanently.

`hermes` is the one workload whose chart is vendored rather than pulled: it is
published nowhere reachable, and `manifests/hermes/chart` was recovered from the
release Secret of the original `helm install`. It still has a helm CLI release
behind it, so its first sync is an adoption — do it by hand, then treat helm as
read-only for it.

## Bootstrap

ArgoCD is already installed; this only wires it to the repo.

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl apply -f projects/homelab.yaml
kubectl apply -f bootstrap/root.yaml
kubectl apply -f local/ingresses.yaml   # not in git, see below
```

Then verify before trusting anything: `argocd app diff crypto-bot` should be empty.

## Not in git

**The sealing key.** Secrets themselves now live in this repo as SealedSecrets —
ciphertext, safe to publish — under `manifests/*/sealed/`. What is not here, and
can never be, is the key that decrypts them: a Secret in `kube-system` created by
the sealed-secrets controller, exported by `scripts/backup-sealing-key.sh` and
kept in a password manager.

That single file is the whole disaster-recovery story. Repo plus key restores
everything. Repo alone restores nothing.

Key renewal is disabled (`--key-renew-period=0`). The controller's default is a
fresh key every 30 days with old keys retained, which quietly makes an off-box
backup stop covering anything sealed after it was taken, with no signal that it
has gone stale. Rotate deliberately via `scripts/rotate-sealing-key.sh`, which
also tells you to retake the backup and re-seal.

**`postgres-admin`** in `mlops` is the exception that stays out entirely. It
holds the Postgres superuser password for the one-shot bootstrap Jobs and should
be deleted once they have run, not committed in any form.

Adopting a Secret that already existed before the controller did needs one
annotation — `sealedsecrets.bitnami.com/managed: "true"` — or the controller
refuses to overwrite it and the SealedSecret sits at `Synced=False`. It fails
safely, leaving the live Secret untouched. `scripts/seal-secrets.sh` sets it.

**Ingresses.** `local/ingresses.yaml` holds the Airflow, MLflow and API Ingresses.
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
