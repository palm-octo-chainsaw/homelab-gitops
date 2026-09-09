#!/usr/bin/env bash
# Install the kubeseal CLI, matching the controller version exactly. Skew is
# tolerated in practice, but a mismatch on the SealedSecret API version shows up
# as a resource the controller silently ignores rather than an error.
set -euo pipefail

VERSION="${VERSION:-0.39.1}"
ARCH="${ARCH:-linux-amd64}"
DEST="${DEST:-/usr/local/bin}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

URL="https://github.com/bitnami-labs/sealed-secrets/releases/download/v${VERSION}/kubeseal-${VERSION}-${ARCH}.tar.gz"
echo "==> downloading kubeseal ${VERSION}"
curl -fsSL "$URL" -o "$TMP/kubeseal.tar.gz"

tar xzf "$TMP/kubeseal.tar.gz" -C "$TMP" kubeseal
sudo install -m 0755 "$TMP/kubeseal" "$DEST/kubeseal"

echo "==> installed: $("$DEST/kubeseal" --version)"
