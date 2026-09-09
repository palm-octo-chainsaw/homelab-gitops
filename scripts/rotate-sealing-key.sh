#!/usr/bin/env bash
# Rotate the sealing key on purpose. The controller runs with
# --key-renew-period=0 because automatic 30-day renewal quietly invalidates an
# off-box backup with no signal that it has gone stale.
#
# Mints a new key for sealing. Old keys are retained so existing SealedSecrets
# still decrypt, but the backup must be retaken and the files re-sealed.
set -euo pipefail

K="${K:-sudo -n k3s kubectl}"

echo "==> keys before:"
$K -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key \
    -o custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp --no-headers

read -r -p "mint a new sealing key? [y/N] " reply
[ "$reply" = "y" ] || { echo "aborted"; exit 0; }

# The documented trigger is a SIGUSR1 to the running process.
pod=$($K -n kube-system get pod -l name=sealed-secrets-controller -o name | head -1)
$K -n kube-system exec "$pod" -- sh -c 'kill -USR1 1'

sleep 5
echo "==> keys after:"
$K -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key \
    -o custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp --no-headers

cat <<'NEXT'

Now, in order:
  1. ./scripts/backup-sealing-key.sh <path>   — the backup you had is now incomplete
  2. ./scripts/seal-secrets.sh                — re-seal against the new key
  3. commit the re-sealed files
NEXT
