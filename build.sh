#!/bin/bash
# Build AWG 3.1 userspace binaries for aarch64 Asuswrt-Merlin routers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

AWG_GO_TAG="${AWG_GO_TAG:-v3.1.20260828}"
AWG_TOOLS_TAG="${AWG_TOOLS_TAG:-v3.1.20260812}"

mkdir -p output

echo "Building ${AWG_GO_TAG} + tools ${AWG_TOOLS_TAG} for linux/arm64..."
DOCKER_BUILDKIT=1 docker build \
    --build-arg "AWG_GO_TAG=${AWG_GO_TAG}" \
    --build-arg "AWG_TOOLS_TAG=${AWG_TOOLS_TAG}" \
    --output=./output .

chmod 755 output/amneziawg-go output/awg

echo "Build complete:"
ls -lh output/amneziawg-go output/awg
sha256sum output/amneziawg-go output/awg
echo
echo "Next: ./build-ipk.sh"
