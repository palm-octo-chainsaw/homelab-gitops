#!/usr/bin/env bash
# Create Airflow's six secrets as SealedSecrets, without a plaintext Secret ever
# existing anywhere.
#
# Values are generated here and piped straight into kubeseal; only ciphertext is
# written or applied. `kubectl create --dry-run=client` builds the object locally
# and never contacts the API server, so these never exist unencrypted in etcd, in
# a file, or in shell history. The older secrets predate the controller and are
# converted by seal-secrets.sh instead.
#
# Run on the server, from the repo root, once the controller is up.
set -euo pipefail

K="${K:-sudo -n k3s kubectl}"
NS=mlops
PG_HOST="postgres.default.svc.cluster.local"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$REPO_ROOT/manifests/airflow/sealed"

if [ -f "$OUT_DIR/airflow-metadata.sealed.yaml" ]; then
    echo "sealed airflow secrets already exist in $OUT_DIR"
    echo "delete them first if you really mean to regenerate — the database"
    echo "password would change and Airflow would lose access to its metadata."
    exit 0
fi

if ! kubeseal --controller-namespace kube-system --fetch-cert > /tmp/ss-cert.pem 2>/dev/null; then
    echo "cannot reach the sealed-secrets controller; is it running?" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

# Alphanumeric only — this password is embedded in a URL, where '/' and '+' would
# need percent-encoding in one place and not the other.
gen() { head -c 48 /dev/urandom | base64 | tr -d '/+=' | head -c 32; }

AIRFLOW_PASSWORD="$(gen)"
JWT_SECRET="$(head -c 96 /dev/urandom | base64 | tr -d '/+=' | head -c 64)"
API_SECRET="$(gen)"
WEBSERVER_SECRET="$(gen)"

# A Fernet key is a fixed format (32 url-safe base64 bytes), so it is generated
# with the library Airflow validates it with — borrowing the airflow image if the
# host python lacks cryptography.
FERNET_KEY="$(python3 -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())' 2>/dev/null || true)"
if [ -z "$FERNET_KEY" ]; then
    FERNET_KEY="$($K -n "$NS" run fernet-gen --rm -i --restart=Never --quiet \
        --image=mlops-crypto/airflow:dev --image-pull-policy=Never -- \
        python -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())' | tr -d '\r\n')"
fi
if [ -z "$FERNET_KEY" ]; then
    echo "could not generate a fernet key" >&2
    exit 1
fi

seal() {
    local name="$1"; shift
    $K create secret generic "$name" -n "$NS" "$@" \
        --dry-run=client -o yaml \
        | kubeseal --format yaml --cert /tmp/ss-cert.pem --scope strict \
        > "$OUT_DIR/${name}.sealed.yaml"
    echo "    sealed $name"
}

echo "==> sealing six secrets into manifests/airflow/sealed/"
seal airflow-metadata \
    --from-literal=connection="postgresql://airflow:${AIRFLOW_PASSWORD}@${PG_HOST}:5432/airflow"
seal airflow-db        --from-literal=AIRFLOW_PASSWORD="$AIRFLOW_PASSWORD"
seal airflow-fernet-key --from-literal=fernet-key="$FERNET_KEY"
seal airflow-jwt        --from-literal=jwt-secret="$JWT_SECRET"
seal airflow-api-secret --from-literal=api-secret-key="$API_SECRET"
seal airflow-webserver  --from-literal=webserver-secret-key="$WEBSERVER_SECRET"

unset AIRFLOW_PASSWORD JWT_SECRET API_SECRET WEBSERVER_SECRET FERNET_KEY

echo "==> applying them so the controller creates the real Secrets"
$K apply -f "$OUT_DIR"

sleep 5
echo "==> Secrets now in the cluster:"
$K -n "$NS" get secret -o name | grep airflow- || echo "    none yet — check the controller logs"

echo
echo "The generated values were never printed and are not recoverable from here."
echo "They live in the cluster, and in the sealed files, which are safe to commit."
