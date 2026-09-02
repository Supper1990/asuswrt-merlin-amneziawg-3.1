#!/bin/sh
# Manual userspace-only installer for Asuswrt-Merlin.
set -e

AWG_DIR="/opt/amneziawg"
ADDON_DIR="/jffs/addons/amneziawg"
SRC_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

for required in amneziawg-go awg amneziawg.sh amneziawg_page.asp; do
    [ -f "$SRC_DIR/$required" ] || {
        echo "ERROR: $SRC_DIR/$required not found"
        exit 1
    }
done

[ -d /opt ] || { echo "ERROR: Entware (/opt) not found"; exit 1; }

if [ -x /opt/etc/init.d/S99amneziawg ]; then
    /opt/etc/init.d/S99amneziawg stop 2>/dev/null || true
fi

mkdir -p "$AWG_DIR" "$ADDON_DIR" /opt/etc/init.d /opt/bin
cp "$SRC_DIR/amneziawg-go" "$AWG_DIR/amneziawg-go"
cp "$SRC_DIR/awg" "$AWG_DIR/awg"
cp "$SRC_DIR/amneziawg.sh" "$ADDON_DIR/amneziawg.sh"
cp "$SRC_DIR/amneziawg_page.asp" "$ADDON_DIR/amneziawg_page.asp"
chmod 755 "$AWG_DIR/amneziawg-go" "$AWG_DIR/awg" "$ADDON_DIR/amneziawg.sh"
chmod 644 "$ADDON_DIR/amneziawg_page.asp"
ln -sf "$AWG_DIR/awg" /opt/bin/awg

cat > /opt/etc/init.d/S99amneziawg << 'INITEOF'
#!/bin/sh
case "$1" in
    start)   /jffs/addons/amneziawg/amneziawg.sh start ;;
    stop)    /jffs/addons/amneziawg/amneziawg.sh stop ;;
    restart) /jffs/addons/amneziawg/amneziawg.sh restart ;;
    *) echo "Usage: $0 {start|stop|restart}"; exit 1 ;;
esac
INITEOF
chmod 755 /opt/etc/init.d/S99amneziawg

mkdir -p -m 700 /var/run/amneziawg
mkdir -p /dev/net "$AWG_DIR/geo/geoip" "$AWG_DIR/geo/domains"
mknod -m 600 /dev/net/tun c 10 200 2>/dev/null || true
chmod 600 /dev/net/tun 2>/dev/null || true

"$ADDON_DIR/amneziawg.sh" install_page || true
if grep -q '^awg_privatekey ' /jffs/addons/custom_settings.txt 2>/dev/null; then
    "$ADDON_DIR/amneziawg.sh" service_event manual awgsaveconf || true
fi

echo "AmneziaWG userspace addon installed. Open VPN > AmneziaWG."
