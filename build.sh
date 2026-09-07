#!/bin/bash
# Build AWG 3.1 userspace binaries for Asuswrt-Merlin ARM64 and ARMv7.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

AWG_GO_TAG="${AWG_GO_TAG:-v3.1.20260828}"
AWG_TOOLS_TAG="${AWG_TOOLS_TAG:-v3.1.20260812}"

mkdir -p output

echo "Building ${AWG_GO_TAG} + tools ${AWG_TOOLS_TAG} for linux/arm64..."
DOCKER_BUILDKIT=1 docker build \
    -f Dockerfile \
    --build-arg "AWG_GO_TAG=${AWG_GO_TAG}" \
    --build-arg "AWG_TOOLS_TAG=${AWG_TOOLS_TAG}" \
    --output=./output .

echo "Building ${AWG_GO_TAG} + tools ${AWG_TOOLS_TAG} for linux/armv7..."
DOCKER_BUILDKIT=1 docker build \
    -f Dockerfile.armv7 \
    --build-arg "AWG_GO_TAG=${AWG_GO_TAG}" \
    --build-arg "AWG_TOOLS_TAG=${AWG_TOOLS_TAG}" \
    --output=./output .

chmod 755 \
    output/amneziawg-go \
    output/awg \
    output/amneziawg-go-arm \
    output/awg-arm

{
    printf 'source_commit=%s\n' "$(git rev-parse HEAD)"
    printf 'go_tag=%s\ntools_tag=%s\n' "$AWG_GO_TAG" "$AWG_TOOLS_TAG"
    docker version --format '{{.Server.Version}}'
    sha256sum \
        Dockerfile \
        Dockerfile.armv7 \
        output/amneziawg-go \
        output/awg \
        output/amneziawg-go-arm \
        output/awg-arm
} > output/build-manifest.txt

echo "Build complete:"
ls -lh \
    output/amneziawg-go \
    output/awg \
    output/amneziawg-go-arm \
    output/awg-arm

sha256sum \
    output/amneziawg-go \
    output/awg \
    output/amneziawg-go-arm \
    output/awg-arm

echo
echo "Next: ./build-ipk.sh"
