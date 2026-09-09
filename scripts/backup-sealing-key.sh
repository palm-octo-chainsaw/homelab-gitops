#!/usr/bin/env bash
# Export the controller's sealing key — the whole disaster-recovery story.
# Without it every SealedSecret in this repo is ciphertext nobody can open.
#
# Written 0600 to a path you pass in, never to the repo. Put the contents in your
# password manager and delete the file.
#
#   ./scripts/backup-sealing-key.sh ~/sealing-key.yaml
#
# Restoring on a rebuilt cluster, BEFORE ArgoCD syncs anything:
#   kubectl apply -f sealing-key.yaml
#   kubectl -n kube-system delete pod -l name=sealed-secrets-controller
set -euo pipefail

OUT="${1:-}"
if [ -z "$OUT" ]; then
    echo "usage: $0 <output-path>" >&2
    exit 1
fi

K="${K:-sudo -n k3s kubectl}"

# Renewal is disabled, so there is normally one. The selector returns all of
# them, which is what you want if renewal is ever turned back on.
count=$($K -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o name | wc -l)
if [ "$count" -eq 0 ]; then
    echo "no sealing key found — is the controller running?" >&2
    exit 1
fi

umask 077
$K -n kube-system get secret \
    -l sealedsecrets.bitnami.com/sealed-secrets-key \
    -o yaml > "$OUT"

echo "wrote $count sealing key(s) to $OUT (mode $(stat -c %a "$OUT"))"
echo
echo "Next, and not optional:"
echo "  1. copy the contents into your password manager"
echo "  2. shred -u $OUT"
echo "  3. verify the restore path works before you rely on it"
