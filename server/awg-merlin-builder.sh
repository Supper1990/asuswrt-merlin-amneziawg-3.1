#!/usr/bin/env bash
set -Eeuo pipefail
if [ -z "${HOME:-}" ] && [ "$(id -u)" -eq 0 ]; then
    export HOME=/root
fi
export GH_CONFIG_DIR="${GH_CONFIG_DIR:-${HOME}/.config/gh}"


ROOT_DIR="${AWG_BUILDER_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
PUBLISH_REPO="${AWG_PUBLISH_REPO:-Supper1990/asuswrt-merlin-amneziawg-3.1}"
RELEASE_DIR="${AWG_RELEASE_DIR:-/opt/awg-merlin-releases}"
TAG_PREFIX="${AWG_TAG_PREFIX:-v3.1.}"
FORCE=false
[ "${1:-}" = "--force" ] && FORCE=true

exec 9>"/tmp/awg-merlin-builder.lock"
flock -n 9 || { echo "Another AWG builder instance is running"; exit 0; }

for cmd in docker git gh jq curl sha256sum file flock python3; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: missing command: $cmd"; exit 1; }
done
gh auth status >/dev/null 2>&1 || { echo "ERROR: run 'gh auth login' first"; exit 1; }

cd "$ROOT_DIR"
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "ERROR: tracked files have uncommitted changes"
    exit 1
fi
git pull --ff-only origin main

latest_tag(){
    local repo="$1"
    curl -fsSL --connect-timeout 10 --max-time 30 \
        "https://api.github.com/repos/${repo}/tags?per_page=30" | \
        jq -r --arg prefix "$TAG_PREFIX" '[.[].name | select(startswith($prefix))][0] // empty'
}

latest_go=$(latest_tag "amnezia-vpn/amneziawg-go")
latest_tools=$(latest_tag "amnezia-vpn/amneziawg-tools")
[ -n "$latest_go" ] || { echo "ERROR: no amneziawg-go ${TAG_PREFIX} tag found"; exit 1; }
[ -n "$latest_tools" ] || { echo "ERROR: no amneziawg-tools ${TAG_PREFIX} tag found"; exit 1; }

current_go=$(sed -n 's/^ARG AWG_GO_TAG=//p' Dockerfile | head -1)
current_tools=$(sed -n 's/^ARG AWG_TOOLS_TAG=//p' Dockerfile | head -1)
changed=false

if [ "$latest_go" != "$current_go" ] || [ "$latest_tools" != "$current_tools" ]; then
    old_pkg=$(sed -n 's/^PKG_VERSION="\([^"]*\)"/\1/p' build-ipk.sh | head -1)
    base_version=${old_pkg%-*}
    revision=${old_pkg##*-}
    case "$revision" in *[!0-9]*|'') echo "ERROR: invalid package revision: $old_pkg"; exit 1 ;; esac
    new_pkg="${base_version}-$((revision + 1))"

    sed -i "s/^ARG AWG_GO_TAG=.*/ARG AWG_GO_TAG=${latest_go}/" Dockerfile
    sed -i "s/^ARG AWG_TOOLS_TAG=.*/ARG AWG_TOOLS_TAG=${latest_tools}/" Dockerfile
    sed -i "s/^AWG_GO_TAG=.*/AWG_GO_TAG=\"\${AWG_GO_TAG:-${latest_go}}\"/" build.sh
    sed -i "s/^AWG_TOOLS_TAG=.*/AWG_TOOLS_TAG=\"\${AWG_TOOLS_TAG:-${latest_tools}}\"/" build.sh
    sed -i "s/^PKG_VERSION=.*/PKG_VERSION=\"${new_pkg}\"/" build-ipk.sh
    changed=true
    echo "Upstream update: go ${current_go} -> ${latest_go}; tools ${current_tools} -> ${latest_tools}"
else
    new_pkg=$(sed -n 's/^PKG_VERSION="\([^"]*\)"/\1/p' build-ipk.sh | head -1)
    if [ "$FORCE" != true ]; then
        echo "No upstream update. Installed source pins are current."
        exit 0
    fi
    echo "Forced build of ${new_pkg}"
fi

rm -rf output
bash tests/run.sh
AWG_GO_TAG="$latest_go" AWG_TOOLS_TAG="$latest_tools" ./build.sh
./build-ipk.sh

ipk="output/amneziawg_${new_pkg}_aarch64-3.10.ipk"
[ -s "$ipk" ] || { echo "ERROR: package not created: $ipk"; exit 1; }
file output/amneziawg-go output/awg "$ipk"

publish_dir="${RELEASE_DIR}/${new_pkg}"
mkdir -p "$publish_dir"
install -m 0644 "$ipk" "$publish_dir/"
(
    cd "$publish_dir"
    sha256sum "$(basename "$ipk")" > SHA256SUMS
)

if [ "$changed" = true ]; then
    git add Dockerfile build.sh build-ipk.sh
    git commit -m "Update AmneziaWG core to ${latest_go} / ${latest_tools}"
    git push origin main
fi

release_tag="v${new_pkg}"
release_notes="AmneziaWG package for Asuswrt-Merlin ARM64.

- amneziawg-go: ${latest_go}
- amneziawg-tools: ${latest_tools}
- package: ${new_pkg}

The router updater verifies SHA256SUMS before installation."

if gh release view "$release_tag" --repo "$PUBLISH_REPO" >/dev/null 2>&1; then
    gh release upload "$release_tag" "$publish_dir/$(basename "$ipk")" "$publish_dir/SHA256SUMS" \
        --repo "$PUBLISH_REPO" --clobber
else
    gh release create "$release_tag" "$publish_dir/$(basename "$ipk")" "$publish_dir/SHA256SUMS" \
        --repo "$PUBLISH_REPO" --title "AmneziaWG Merlin ${new_pkg}" --notes "$release_notes"
fi

echo "Published ${PUBLISH_REPO} release ${release_tag}"
sha256sum "$publish_dir/$(basename "$ipk")"
