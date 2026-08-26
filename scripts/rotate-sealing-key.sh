#!/usr/bin/env bash
# Rotate the sealing key on purpose.
#
# The controller runs with --key-renew-period=0, so this never happens on its
# own. That is deliberate: automatic renewal every 30 days quietly invalidates
# an off-box key backup, and nothing tells you it has gone stale.
#
# What this does: asks the controller to mint a new key, which becomes the one
# used for sealing. Old keys are retained, so existing SealedSecrets keep
# decrypting — but anything sealed from now on needs the new key, so the backup
# must be retaken and the sealed files re-sealed.
#
# Run this if the key is believed compromised, or on whatever schedule you decide
# to keep. Not required for normal operation.
set -euo pipefail

K="${K:-sudo -n k3s kubectl}"

echo "==> keys before:"
$K -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key \
    -o custom-columns=NAME:.metadata.name,CREATED:.metadata.creationTimestamp --no-headers

read -r -p "mint a new sealing key? [y/N] " reply
[ "$reply" = "y" ] || { echo "aborted"; exit 0; }

# The controller mints a key on startup when told to; the documented trigger is
# a SIGUSR1 to the running process.
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
