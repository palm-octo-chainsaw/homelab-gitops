#!/usr/bin/env bash
# Convert the cluster's existing hand-made Secrets into committable SealedSecrets.
#
# Reads each live Secret, strips the server-side fields, seals it against the
# controller's public certificate, and writes the result next to the workload it
# belongs to. Plaintext never touches disk — the pipeline goes straight from
# kubectl into kubeseal.
#
# Safe to rerun: sealing is deterministic per key, and re-sealing an unchanged
# secret produces an equivalent file. Nothing is deleted from the cluster; the
# live Secrets keep working until you decide to hand them over.
#
# Run on the server, from the repo root.
set -euo pipefail

K="${K:-sudo -n k3s kubectl}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT="${CERT:-}"

# namespace:secret:destination-directory
TARGETS=(
    "default:crypto-bot-secret:manifests/crypto-bot/sealed"
    "default:postgres-secret:manifests/postgres/sealed"
    "mlops:mlops-secrets:manifests/mlops/sealed"
    "mlops:airflow-metadata:manifests/airflow/sealed"
    "mlops:airflow-db:manifests/airflow/sealed"
    "mlops:airflow-fernet-key:manifests/airflow/sealed"
    "mlops:airflow-jwt:manifests/airflow/sealed"
    "mlops:airflow-api-secret:manifests/airflow/sealed"
    "mlops:airflow-webserver:manifests/airflow/sealed"
)

# postgres-admin is deliberately absent. It holds the Postgres superuser password
# for the one-shot bootstrap Jobs and should be deleted once they have run, not
# committed in any form.

fetch_cert() {
    if [ -n "$CERT" ]; then
        echo "$CERT"
        return
    fi
    local out="/tmp/sealed-secrets-cert.pem"
    kubeseal --controller-namespace kube-system --fetch-cert > "$out"
    echo "$out"
}

CERT_FILE="$(fetch_cert)"
echo "==> sealing against $CERT_FILE"

for target in "${TARGETS[@]}"; do
    IFS=: read -r ns name dir <<< "$target"

    if ! $K get secret "$name" -n "$ns" >/dev/null 2>&1; then
        echo "    skip $ns/$name (not present)"
        continue
    fi

    mkdir -p "$REPO_ROOT/$dir"
    out="$REPO_ROOT/$dir/${name}.sealed.yaml"

    # creationTimestamp, resourceVersion, uid and the last-applied annotation are
    # server-side noise; leaving them in makes every re-seal a spurious diff.
    #
    # JSON, not YAML: the host python has no PyYAML, and kubeseal accepts either.
    # metadata.name and metadata.namespace must survive — strict scope binds the
    # ciphertext to both, and dropping either makes the result undecryptable.
    $K get secret "$name" -n "$ns" -o json \
        | python3 -c '
import json, sys
d = json.load(sys.stdin)
m = d.get("metadata", {})
d["metadata"] = {k: v for k, v in m.items() if k in ("name", "namespace", "labels")}
d.pop("status", None)
json.dump(d, sys.stdout)
' \
        | kubeseal --format yaml --cert "$CERT_FILE" --scope strict > "$out"

    # The controller refuses to touch a Secret it did not create:
    #   "Resource X already exists and is not managed by SealedSecret"
    # It fails safely — the live Secret is left alone — but the SealedSecret sits
    # at Synced=False forever. This annotation is the documented opt-in that lets
    # the controller adopt an existing Secret instead.
    $K annotate secret "$name" -n "$ns" \
        sealedsecrets.bitnami.com/managed="true" --overwrite >/dev/null

    echo "    sealed $ns/$name -> $dir/${name}.sealed.yaml"
done

echo
echo "==> done. Review the files, then commit them."
echo "    They contain ciphertext only — safe for the public repo."
echo "    Scope is strict: a sealed secret only decrypts under the same name AND namespace."
echo
echo "If a SealedSecret stays at Synced=False after you apply it, the controller"
echo "gave up retrying before the annotation landed. Nudge it once:"
echo "    kubectl -n kube-system rollout restart deploy/sealed-secrets-controller"
