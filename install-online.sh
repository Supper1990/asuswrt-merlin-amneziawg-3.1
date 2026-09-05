#!/bin/sh
# AmneziaWG online installer for Asuswrt-Merlin ARM64.

REPO="Supper1990/asuswrt-merlin-amneziawg-3.1"
SUPPORTED_ARCH="aarch64-3.10"
TMP_DIR=""

cleanup(){
    [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
    if [ "${INSTALL_LOCKED:-0}" = 1 ]; then rm -f /tmp/.awg_no_autostart; rm -rf /tmp/.awg_package_lock; fi
}
trap cleanup 0
trap 'exit 1' 1 2 15

echo "============================================"
echo "  AmneziaWG Installer"
echo "============================================"

export PATH="/opt/bin:/opt/sbin:$PATH"

if [ ! -x /opt/bin/opkg ]; then
    echo "ERROR: Entware is not installed"
    exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is not installed"
    exit 1
fi

CPU_ARCH=$(uname -m)
PKG_ARCH=$(/opt/bin/opkg print-architecture 2>/dev/null | \
    awk -v wanted="$SUPPORTED_ARCH" '$1=="arch" && $2==wanted {print $2; exit}')

echo "CPU architecture: $CPU_ARCH"
echo "Entware architecture: ${PKG_ARCH:-not compatible}"

if [ "$CPU_ARCH" != "aarch64" ] || [ "$PKG_ARCH" != "$SUPPORTED_ARCH" ]; then
    echo "ERROR: This release supports only ARM64/AArch64 with Entware $SUPPORTED_ARCH"
    exit 1
fi

if [ -f /jffs/addons/amneziawg/awg-runtime.sh ]; then
    exec /jffs/addons/amneziawg/amneziawg.sh update
fi
mkdir /tmp/.awg_package_lock 2>/dev/null || { echo 'ERROR: another package installation is active'; exit 1; }
INSTALL_LOCKED=1
echo $$ > /tmp/.awg_package_lock/pid
export AWG_PACKAGE_CHILD=1

echo "Fetching latest release..."
RELEASE_JSON=$(curl -sfL --connect-timeout 10 --max-time 30 \
    "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null)
if [ -z "$RELEASE_JSON" ]; then
    echo "ERROR: Cannot reach the GitHub API"
    exit 1
fi

VERSION=$(echo "$RELEASE_JSON" | grep '"tag_name"' | head -1 | \
    sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"//;s/^v//;s/".*//')
case "$VERSION" in
    ""|*[!0-9.-]*) echo "ERROR: Invalid release version: $VERSION"; exit 1 ;;
esac

IPK_URL=$(echo "$RELEASE_JSON" | grep '"browser_download_url"' | \
    grep "_${SUPPORTED_ARCH}\.ipk\"" | head -1 | \
    sed 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"//;s/".*//')
SUMS_URL=$(echo "$RELEASE_JSON" | grep '"browser_download_url"' | \
    grep '/SHA256SUMS"' | head -1 | \
    sed 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"//;s/".*//')

case "$IPK_URL" in
    https://github.com/${REPO}/releases/download/*) ;;
    *) echo "ERROR: ARM64 package not found in release $VERSION"; exit 1 ;;
esac
case "$SUMS_URL" in
    https://github.com/${REPO}/releases/download/*/SHA256SUMS) ;;
    *) echo "ERROR: SHA256SUMS not found in release $VERSION"; exit 1 ;;
esac

IPK_FILE=$(basename "$IPK_URL")
TMP_DIR=$(mktemp -d /tmp/amneziawg_install.XXXXXX) || exit 1

echo "Latest version: $VERSION"
echo "Package: $IPK_FILE"
echo "Downloading package and SHA256SUMS..."

curl -sfL --connect-timeout 10 --max-time 180 \
    "$IPK_URL" -o "$TMP_DIR/$IPK_FILE" || { echo "ERROR: Package download failed"; exit 1; }
curl -sfL --connect-timeout 10 --max-time 60 \
    "$SUMS_URL" -o "$TMP_DIR/SHA256SUMS" || { echo "ERROR: SHA256SUMS download failed"; exit 1; }

EXPECTED=$(awk -v f="$IPK_FILE" '$2==f || $2=="*" f {print $1; exit}' "$TMP_DIR/SHA256SUMS")
ACTUAL=$(sha256sum "$TMP_DIR/$IPK_FILE" 2>/dev/null | awk '{print $1}')
if [ -z "$EXPECTED" ] || [ "$ACTUAL" != "$EXPECTED" ]; then
    echo "ERROR: Package SHA256 mismatch"
    exit 1
fi
echo "SHA256: OK"

echo "Installing..."
touch /tmp/.awg_no_autostart
/opt/bin/opkg install "$TMP_DIR/$IPK_FILE"
RC=$?
rm -f /tmp/.awg_no_autostart

if [ "$RC" -ne 0 ]; then
    echo "ERROR: Installation failed (exit code $RC)"
    exit "$RC"
fi

echo "============================================"
echo "  AmneziaWG $VERSION installed"
echo "============================================"
echo "Web UI: VPN > AmneziaWG"
echo "Start:  /opt/etc/init.d/S99amneziawg start"
