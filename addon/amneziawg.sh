#!/bin/sh
# =============================================================
# AmneziaWG addon backend for Asuswrt-Merlin
# Userspace amneziawg-go, per-device policy routing, GeoIP/GeoSite
# =============================================================

AWG_VERSION="2.2.0"
ADDON_DIR="/jffs/addons/amneziawg"
AWG_DIR="/opt/amneziawg"
CONF="$AWG_DIR/awg0.conf"
AWG_GO="$AWG_DIR/amneziawg-go"
AWG_BIN="$AWG_DIR/awg"
IFACE="awg0"
STATUS_FILE="/www/user/awg_status.htm"
SETTINGS="/jffs/addons/custom_settings.txt"
CLIENTS_FILE="$AWG_DIR/clients.list"
GEO_DIR="$AWG_DIR/geo"
IPSET_NAME="awg_dst"
IPSET_MIN_COUNT_FILE="/tmp/.awg_ipset_min_count"
FWMARK="0x100"
DNSMASQ_AWG_CONF="$AWG_DIR/dnsmasq_awg.conf"
DNSMASQ_INCLUDE="/jffs/configs/dnsmasq.conf.add"
SCRIPT_NAME="amneziawg"
RT_TABLE=300
AWG_CHAIN="AWG"
LOCKDIR="/tmp/.awg_lock"
AUX_IPSET_SCRIPT="$ADDON_DIR/awg-ipset-update.sh"
UPDATE_REPO="Supper1990/asuswrt-merlin-amneziawg-3.1"
V2FLY_GEOIP_BASE="https://raw.githubusercontent.com/Loyalsoldier/geoip/release/text"

# Ensure Entware binaries are in PATH (not set when called from httpd/service-event)
export PATH="/opt/bin:/opt/sbin:$PATH"

# --- Helpers ---

log_msg(){
    logger -t "$SCRIPT_NAME" "$1"
}

remove_managed_cron(){
    cru d awg_geo_update 2>/dev/null
    cru d awg_watchdog 2>/dev/null
    cru d awg_myawg_update 2>/dev/null

    # Names used by the legacy standalone script.
    cru d AWG_CHECK 2>/dev/null
    cru d AWG_IPSET 2>/dev/null
    cru d AWG_DAILY_UPDATE 2>/dev/null
}

antifilter_enabled(){
    # Backward-compatible default: enabled when the setting does not exist.
    [ "$(get_setting awg_antifilter_enabled)" != "0" ]
}

register_managed_cron(){
    remove_managed_cron
    cru a awg_watchdog "*/5 * * * * '$ADDON_DIR/amneziawg.sh' watchdog"
    # Offset from the built-in GeoIP update to avoid two heavy jobs at 04:00.
    if antifilter_enabled; then
        cru a awg_myawg_update "10 4 * * * '$AUX_IPSET_SCRIPT' --update"
    fi
    if [ "$(get_setting awg_geo_autoupdate)" = "1" ]; then
        cru a awg_geo_update "0 4 * * * '$ADDON_DIR/amneziawg.sh' update_geo"
    fi
}

repair_aux_routing(){
    [ -x "$AUX_IPSET_SCRIPT" ] || return 0
    if ! antifilter_enabled; then
        "$AUX_IPSET_SCRIPT" --disable 2>/dev/null
        return 0
    fi
    "$AUX_IPSET_SCRIPT" --repair || {
        log_msg "WARNING: MYAWG table 400 repair failed"
        return 1
    }
}

update_antifilter(){
    [ -x "$AUX_IPSET_SCRIPT" ] || {
        log_msg "ERROR: AntiFilter updater not found"
        return 1
    }
    if ! antifilter_enabled; then
        log_msg "AntiFilter update skipped: disabled"
        return 1
    fi
    "$AUX_IPSET_SCRIPT" --update
}

ensure_ui_mark_nat(){
    # Match the UI routing mark instead of a source subnet/interface. This
    # covers LAN clients as well as OpenVPN, IPsec and other VPN-server clients.
    iptables -t nat -C POSTROUTING \
        -m mark --mark "$FWMARK"/0xffffffff -o "$IFACE" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING \
        -m mark --mark "$FWMARK"/0xffffffff -o "$IFACE" -j MASQUERADE
}

remove_ui_mark_nat(){
    local _i=0
    while [ $_i -lt 100 ] && iptables -t nat -C POSTROUTING \
        -m mark --mark "$FWMARK"/0xffffffff -o "$IFACE" -j MASQUERADE 2>/dev/null; do
        iptables -t nat -D POSTROUTING \
            -m mark --mark "$FWMARK"/0xffffffff -o "$IFACE" -j MASQUERADE 2>/dev/null || break
        _i=$((_i + 1))
    done
}

disable_aux_routing(){
    [ -x "$AUX_IPSET_SCRIPT" ] && "$AUX_IPSET_SCRIPT" --disable 2>/dev/null
}

migrate_legacy_ipset(){
    remove_managed_cron

    # Disable the old boot hook, but keep a recoverable copy of the user's script.
    if [ -f /jffs/scripts/awg-ipset-update.sh ] && \
       [ ! -f /jffs/scripts/awg-ipset-update.sh.pre-amneziawg-addon ]; then
        cp /jffs/scripts/awg-ipset-update.sh \
            /jffs/scripts/awg-ipset-update.sh.pre-amneziawg-addon
    fi
    [ -f /jffs/scripts/services-start ] && \
        sed -i '\|/jffs/scripts/awg-ipset-update.sh|d' /jffs/scripts/services-start
}

get_setting(){
    awk -v key="$1" '$1==key{sub(/^[^ ]+ /,"");print;exit}' "$SETTINGS" 2>/dev/null
}

is_running(){
    ip link show "$IFACE" >/dev/null 2>&1
}

get_lan_net(){
    ip -4 route show dev br0 2>/dev/null | awk '$1 ~ /^[0-9]/ && $1 ~ /\// {print $1; exit}'
}

get_router_ip(){
    ip -4 addr show br0 2>/dev/null | awk '/inet /{sub(/\/.*/, "", $2); print $2; exit}'
}

get_endpoint(){
    awk -F'[ =:]+' '/^Endpoint/{print $2}' "$CONF" 2>/dev/null
}

ensure_main_routes(){
    local lan_net
    lan_net=$(get_lan_net)
    ip route replace 0.0.0.0/1 dev "$IFACE" table $RT_TABLE
    ip route replace 128.0.0.0/1 dev "$IFACE" table $RT_TABLE
    [ -n "$lan_net" ] && ip route replace "$lan_net" dev br0 table $RT_TABLE
    ip route flush cache 2>/dev/null
}

flush_conntrack(){
    if command -v conntrack >/dev/null 2>&1 && conntrack -D --mark "$FWMARK"/"$FWMARK" 2>/dev/null; then
        return 0
    fi
    conntrack -F 2>/dev/null
}

save_and_set_rp_filter(){
    local f iface saved
    for f in \
        /proc/sys/net/ipv4/conf/all/rp_filter \
        /proc/sys/net/ipv4/conf/awg0/rp_filter \
        /proc/sys/net/ipv4/conf/br0/rp_filter \
        /proc/sys/net/ipv4/conf/tun*/rp_filter \
        /proc/sys/net/ipv4/conf/tap*/rp_filter \
        /proc/sys/net/ipv4/conf/vti*/rp_filter \
        /proc/sys/net/ipv4/conf/ipsec*/rp_filter; do
        [ -f "$f" ] || continue
        iface=${f%/rp_filter}
        iface=${iface##*/}
        saved="/tmp/.awg_rp_$iface"
        # Do not overwrite the original value during watchdog repairs.
        [ -f "$saved" ] || cat "$f" > "$saved" 2>/dev/null
        [ "$(cat "$f" 2>/dev/null)" = "2" ] || echo 2 > "$f" 2>/dev/null
    done
}

restore_rp_filter(){
    local saved iface f
    for saved in /tmp/.awg_rp_*; do
        [ -f "$saved" ] || continue
        iface=${saved##*/.awg_rp_}
        f="/proc/sys/net/ipv4/conf/$iface/rp_filter"
        [ -f "$f" ] && cat "$saved" > "$f" 2>/dev/null
        rm -f "$saved"
    done
}

main_firewall_healthy(){
    local lan_net min_ipset_count current_ipset_count

    lan_net=$(get_lan_net)

    iptables -C INPUT -i "$IFACE" -j ACCEPT 2>/dev/null || return 1
    iptables -C FORWARD -i "$IFACE" -j ACCEPT 2>/dev/null || return 1
    iptables -C FORWARD -o "$IFACE" -j ACCEPT 2>/dev/null || return 1
    iptables -t mangle -C FORWARD -o "$IFACE" -p tcp \
        --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || return 1
    iptables -t mangle -C FORWARD -i "$IFACE" -p tcp \
        --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || return 1
    iptables -t mangle -C PREROUTING -j "$AWG_CHAIN" 2>/dev/null || return 1
    iptables -t mangle -C "$AWG_CHAIN" -m addrtype \
        --dst-type LOCAL -j RETURN 2>/dev/null || return 1
    iptables -t nat -C POSTROUTING -m mark \
        --mark "$FWMARK"/0xffffffff -o "$IFACE" -j MASQUERADE 2>/dev/null || return 1
    if [ -n "$lan_net" ]; then
        iptables -t nat -C POSTROUTING -s "$lan_net" \
            -o "$IFACE" -j MASQUERADE 2>/dev/null || return 1
    else
        iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null || return 1
    fi
    ipset list "$IPSET_NAME" >/dev/null 2>&1 || return 1
    [ -f "$IPSET_MIN_COUNT_FILE" ] || return 1
    min_ipset_count=$(cat "$IPSET_MIN_COUNT_FILE" 2>/dev/null)
    case "$min_ipset_count" in ""|*[!0-9]*) return 1 ;; esac
    current_ipset_count=$(ipset list "$IPSET_NAME" -t 2>/dev/null | \
        awk '/Number of entries/{print $NF}')
    [ -n "$current_ipset_count" ] || return 1
    [ "$current_ipset_count" -ge "$min_ipset_count" ] 2>/dev/null || return 1
    ip rule show 2>/dev/null | grep -q "fwmark $FWMARK.*lookup $RT_TABLE" || return 1
    ip route show table $RT_TABLE 2>/dev/null | \
        grep -q "^0.0.0.0/1 dev $IFACE" || return 1
    ip route show table $RT_TABLE 2>/dev/null | \
        grep -q "^128.0.0.0/1 dev $IFACE" || return 1

    if [ -n "$lan_net" ]; then
        ip route show table $RT_TABLE 2>/dev/null | \
            grep -q "^$lan_net dev br0" || return 1
    fi
    return 0
}

# Wait for process to exit. Usage: wait_for_pid_exit <name> <timeout>
wait_for_pid_exit(){
    local pname="$1" max="${2:-10}" i=0
    while [ $i -lt $max ]; do
        pidof "$pname" >/dev/null 2>&1 || return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# Wait for DNS resolver. Usage: wait_for_dns <timeout>
wait_for_dns(){
    local max="${1:-10}" i=0
    while [ $i -lt $max ]; do
        nslookup localhost 127.0.0.1 >/dev/null 2>&1 && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# Restart dnsmasq and wait until the replacement daemon has loaded its config.
restart_dnsmasq_and_wait(){
    local old_pid current_pid i=0 max="${1:-15}"
    old_pid=$(pidof dnsmasq 2>/dev/null)
    service restart_dnsmasq >/dev/null 2>&1
    while [ $i -lt "$max" ]; do
        current_pid=$(pidof dnsmasq 2>/dev/null)
        if [ -n "$current_pid" ] && nslookup localhost 127.0.0.1 >/dev/null 2>&1; then
            if [ -z "$old_pid" ] || [ "$current_pid" != "$old_pid" ] || [ $i -ge 3 ]; then
                return 0
            fi
        fi
        sleep 1
        i=$((i + 1))
    done
    log_msg "WARNING: dnsmasq restart timeout"
    return 1
}

# Wait for network interface IP. Usage: wait_for_iface_ip <iface> <timeout>
wait_for_iface_ip(){
    local iface="$1" max="${2:-10}" i=0
    while [ $i -lt $max ]; do
        ip -4 addr show "$iface" 2>/dev/null | grep -q "inet " && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# Wait for interface to appear. Usage: wait_for_iface <iface> <timeout>
wait_for_iface(){
    local iface="$1" max="${2:-10}" i=0
    while [ $i -lt $max ]; do
        ip link show "$iface" >/dev/null 2>&1 && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

acquire_lock(){
    local tries=0
    while ! mkdir "$LOCKDIR" 2>/dev/null; do
        if [ -f "$LOCKDIR/pid" ]; then
            local old_pid
            old_pid=$(cat "$LOCKDIR/pid" 2>/dev/null)
            if [ -n "$old_pid" ] && ! kill -0 "$old_pid" 2>/dev/null; then
                rm -rf "$LOCKDIR"
                continue
            fi
        fi
        tries=$((tries + 1))
        [ $tries -ge 30 ] && { log_msg "ERROR: lock timeout"; return 1; }
        sleep 1
    done
    echo $$ > "$LOCKDIR/pid"
}

release_lock(){
    rm -rf "$LOCKDIR"
}

human_size(){
    local bytes=${1:-0}
    if [ "$bytes" -ge 1073741824 ] 2>/dev/null; then
        echo "$bytes" | awk '{printf "%.1f GiB", $1/1073741824}'
    elif [ "$bytes" -ge 1048576 ] 2>/dev/null; then
        echo "$bytes" | awk '{printf "%.1f MiB", $1/1048576}'
    elif [ "$bytes" -ge 1024 ] 2>/dev/null; then
        echo "$bytes" | awk '{printf "%.1f KiB", $1/1024}'
    else
        echo "${bytes} B"
    fi
}

valid_geo_service_name(){
    case "$1" in
        ""|.*|*..*|*[!a-z0-9._-]*) return 1 ;;
        *) return 0 ;;
    esac
}

selected_geoip_services(){
    local raw svc selected=""
    raw=$(get_setting awg_geo_v2fly_ip)
    for svc in $(echo "$raw" | tr ',' ' '); do
        svc=$(echo "$svc" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
        valid_geo_service_name "$svc" || continue
        case " $selected " in
            *" $svc "*) ;;
            *) selected="$selected $svc" ;;
        esac
    done
    echo "$selected"
}

prune_unselected_geoip_lists(){
    local selected_services old_file file_name old_svc selected_svc keep
    selected_services="$1"
    for old_file in "$GEO_DIR"/geoip/v2fly_*.cidr; do
        [ -f "$old_file" ] || continue

        # Extract the service from the basename in two simple steps.  This is
        # reliable on the BusyBox ash used by Asuswrt-Merlin and avoids a
        # pathname-pattern expansion that did not remove stale lists on some
        # routers.
        file_name=${old_file##*/}
        old_svc=${file_name#v2fly_}
        old_svc=${old_svc%.cidr}

        keep=0
        for selected_svc in $selected_services; do
            if [ "$old_svc" = "$selected_svc" ]; then
                keep=1
                break
            fi
        done

        [ "$keep" -eq 1 ] && continue
        if rm -f "$old_file" && [ ! -e "$old_file" ]; then
            log_msg "GeoIP: removed unselected $old_svc"
        else
            log_msg "WARNING: GeoIP failed to remove unselected $old_svc"
        fi
    done
}

# Download a single selected GeoIP service list (IPv4 only)
download_geoip_service(){
    local svc="$1"
    svc=$(echo "$svc" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
    valid_geo_service_name "$svc" || return 1
    local tmp="$GEO_DIR/geoip/.dl_${svc}.tmp"
    if curl -sfL --connect-timeout 10 --max-time 30 "${V2FLY_GEOIP_BASE}/${svc}.txt" -o "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        grep -v ":" "$tmp" > "$GEO_DIR/geoip/v2fly_${svc}.cidr"
        rm -f "$tmp"
        [ -s "$GEO_DIR/geoip/v2fly_${svc}.cidr" ] || { rm -f "$GEO_DIR/geoip/v2fly_${svc}.cidr"; return 1; }
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# Download all geo databases (called at install and update)
download_all_geo(){
    mkdir -p "$GEO_DIR/geoip" "$GEO_DIR/domains"
    log_msg "Downloading all geo databases..."

    # Download only GeoIP service lists selected in the web interface.
    local selected_services
    selected_services=$(selected_geoip_services)
    local count=0 total=0 ok=0
    for svc in $selected_services; do
        total=$((total + 1))
    done
    for svc in $selected_services; do
        count=$((count + 1))
        log_msg "GeoIP: downloading $svc ($count/$total)..."
        if download_geoip_service "$svc"; then
            ok=$((ok + 1))
        else
            log_msg "WARNING: GeoIP $svc failed"
        fi
        update_status
    done
    log_msg "GeoIP: $ok/$total service lists downloaded"

    # Remove generated lists that are no longer selected. Files without the
    # v2fly_ prefix are treated as locally managed lists and are preserved.
    prune_unselected_geoip_lists "$selected_services"

    # Download v2fly domain database
    log_msg "Downloading v2fly domain database..."
    update_status
    local tmp_yml="$GEO_DIR/v2fly_all.yml.tmp"
    if curl -sfL --connect-timeout 10 --max-time 120 "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat_plain.yml" \
        -o "$tmp_yml" 2>/dev/null; then
        if [ -s "$tmp_yml" ]; then
            mv "$tmp_yml" "$GEO_DIR/v2fly_all.yml"
            grep -E '^[[:space:]]*- name:' "$GEO_DIR/v2fly_all.yml" | \
                sed 's/.*- name:[[:space:]]*//;s/^"//;s/"$//' | \
                sort > "$GEO_DIR/v2fly_categories.txt"
            cp "$GEO_DIR/v2fly_categories.txt" /www/user/v2fly_categories.htm 2>/dev/null
            log_msg "GeoSite: $(wc -l < "$GEO_DIR/v2fly_categories.txt") categories downloaded"
        else
            rm -f "$tmp_yml"
            log_msg "WARNING: v2fly domain download empty"
        fi
    else
        rm -f "$tmp_yml"
        log_msg "WARNING: v2fly domain download failed"
    fi

    # Save timestamp
    date +%s > "$GEO_DIR/.last_update"
    update_status
    log_msg "Geo databases updated"
}

# Mount AmneziaWG tab into Merlin menu
mount_menu_tree(){
    local page="$1"
    [ ! -f /tmp/menuTree.js ] && cp /www/require/modules/menuTree.js /tmp/
    sed -i '/AmneziaWG/d' /tmp/menuTree.js
    sed -i "/url: \"Advanced_VPN_OpenVPN.asp\"/a {url: \"$page\", tabName: \"AmneziaWG\"}," /tmp/menuTree.js
    umount /www/require/modules/menuTree.js 2>/dev/null
    mount -o bind /tmp/menuTree.js /www/require/modules/menuTree.js
}

# Bulk-load CIDR file into ipset using restore (much faster than individual adds)
ipset_load_file(){
    local file="$1"
    local setname="$2"
    [ ! -f "$file" ] && return
    awk -v s="$setname" '
        /^[0-9]/ && !/^#/ {
            gsub(/[[:space:]\r]/, "")
            if ($0 != "") print "add " s " " $0 " timeout 0"
        }
    ' "$file" | ipset restore -! 2>/dev/null
}

# --- Unified firewall setup ---

setup_dns_interception(){
    local router_ip
    router_ip=$(get_router_ip)
    [ -z "$router_ip" ] && router_ip="192.168.1.1"
    iptables -t nat -I PREROUTING -i br0 -p udp --dport 53 -j DNAT --to "$router_ip"
    iptables -t nat -I PREROUTING -i br0 -p tcp --dport 53 -j DNAT --to "$router_ip"
    iptables -I FORWARD -i br0 -p tcp --dport 853 -j REJECT
    local doh_ip
    for doh_ip in 8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1 9.9.9.9 149.112.112.112; do
        iptables -I FORWARD -i br0 -d "$doh_ip" -p tcp --dport 443 -j REJECT
        iptables -I FORWARD -i br0 -d "$doh_ip" -p udp --dport 443 -j REJECT
    done
    log_msg "DNS interception enabled"
}

setup_ipv6_block(){
    local ipv6_svc
    ipv6_svc=$(nvram get ipv6_service 2>/dev/null)
    [ "$ipv6_svc" = "disabled" ] || [ -z "$ipv6_svc" ] && return 0
    ip6tables -I FORWARD -i br0 -o "$IFACE" -j REJECT --reject-with icmp6-adm-prohibited 2>/dev/null
    ip6tables -I FORWARD -i "$IFACE" -o br0 -j REJECT --reject-with icmp6-adm-prohibited 2>/dev/null
    log_msg "IPv6 leak protection enabled"
}

cleanup_ipv6_block(){
    ip6tables -D FORWARD -i br0 -o "$IFACE" -j REJECT --reject-with icmp6-adm-prohibited 2>/dev/null
    ip6tables -D FORWARD -i "$IFACE" -o br0 -j REJECT --reject-with icmp6-adm-prohibited 2>/dev/null
}

cleanup_firewall(){
    # Unhook from PREROUTING, flush and delete custom chain
    iptables -t mangle -D PREROUTING -j "$AWG_CHAIN" 2>/dev/null
    iptables -t mangle -F "$AWG_CHAIN" 2>/dev/null
    iptables -t mangle -X "$AWG_CHAIN" 2>/dev/null

    # Remove all ip rules for our table/fwmark
    local _i=0; while [ $_i -lt 100 ] && ip rule del lookup $RT_TABLE 2>/dev/null; do _i=$((_i+1)); done
    _i=0; while [ $_i -lt 100 ] && ip rule del fwmark "$FWMARK" 2>/dev/null; do _i=$((_i+1)); done

    # Remove DNS interception rules
    local router_ip
    router_ip=$(get_router_ip)
    [ -z "$router_ip" ] && router_ip="192.168.1.1"
    iptables -t nat -D PREROUTING -i br0 -p udp --dport 53 -j DNAT --to "$router_ip" 2>/dev/null
    iptables -t nat -D PREROUTING -i br0 -p tcp --dport 53 -j DNAT --to "$router_ip" 2>/dev/null
    iptables -D FORWARD -i br0 -p tcp --dport 853 -j REJECT 2>/dev/null
    local doh_ip
    for doh_ip in 8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1 9.9.9.9 149.112.112.112; do
        iptables -D FORWARD -i br0 -d "$doh_ip" -p tcp --dport 443 -j REJECT 2>/dev/null
        iptables -D FORWARD -i br0 -d "$doh_ip" -p udp --dport 443 -j REJECT 2>/dev/null
    done

    # Destroy ipset
    ipset flush "$IPSET_NAME" 2>/dev/null
    ipset destroy "$IPSET_NAME" 2>/dev/null
    rm -f "$IPSET_MIN_COUNT_FILE"

    # Remove dnsmasq config
    rm -f "$DNSMASQ_AWG_CONF"
    [ -f "$DNSMASQ_INCLUDE" ] && sed -i "\|${DNSMASQ_AWG_CONF}|d" "$DNSMASQ_INCLUDE"

    cleanup_ipv6_block

    log_msg "Firewall rules cleaned"
}

setup_firewall(){
    cleanup_firewall

    local default_policy=$(get_setting awg_default_policy)
    [ -z "$default_policy" ] && default_policy="direct"
    local has_geo=false

    # --- Create ipset ---
    ipset create "$IPSET_NAME" hash:net family inet hashsize 4096 maxelem 131072 timeout 86400 2>/dev/null
    if ! ipset list "$IPSET_NAME" >/dev/null 2>&1; then
        log_msg "ERROR: ipset $IPSET_NAME creation failed, geo routing disabled"
        has_geo=false
    fi

    # --- Load selected GeoIP subnets into ipset (bulk) ---
    local ip_count=0 f svc
    local selected_services
    selected_services=$(selected_geoip_services)
    prune_unselected_geoip_lists "$selected_services"
    for svc in $selected_services; do
        f="$GEO_DIR/geoip/v2fly_${svc}.cidr"
        [ ! -f "$f" ] && continue
        ipset_load_file "$f" "$IPSET_NAME"
        ip_count=$((ip_count + $(wc -l < "$f")))
    done

    # Preserve support for explicitly installed local CIDR files.
    for f in "$GEO_DIR"/geoip/*.cidr; do
        [ ! -f "$f" ] && continue
        case "${f##*/}" in v2fly_*.cidr) continue ;; esac
        ipset_load_file "$f" "$IPSET_NAME"
        ip_count=$((ip_count + $(wc -l < "$f")))
    done

    # Check ipset fill level
    local ipset_entries
    ipset_entries=$(ipset list "$IPSET_NAME" -t 2>/dev/null | awk '/Number of entries/{print $NF}')
    [ -n "$ipset_entries" ] && [ "$ipset_entries" -ge 131072 ] 2>/dev/null && \
        log_msg "WARNING: ipset $IPSET_NAME full ($ipset_entries/131072), some geo routes may be missing"

    # --- Extract v2fly domains from downloaded database ---
    local geo_v2fly=$(get_setting awg_geo_v2fly)
    rm -f "$GEO_DIR/domains/v2fly_"*.txt
    if [ -n "$geo_v2fly" ] && [ -f "$GEO_DIR/v2fly_all.yml" ]; then
        for svc in $(echo "$geo_v2fly" | tr ',' ' '); do
            svc=$(echo "$svc" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
            valid_geo_service_name "$svc" || {
                log_msg "WARNING: Invalid GeoSite category: $svc"
                continue
            }
            awk -v cat="$svc" '
                /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
                    name=$0
                    sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", name)
                    sub(/^"/, "", name); sub(/"[[:space:]]*$/, "", name)
                    found=(name==cat)
                    next
                }
                found && /^[[:space:]]*-[[:space:]]*/ {
                    rule=$0
                    sub(/^[[:space:]]*-[[:space:]]*/, "", rule)
                    sub(/^"/, "", rule); sub(/"[[:space:]]*$/, "", rule)
                    if (rule ~ /^(domain|full):/) {
                        sub(/^[^:]*:/, "", rule)
                        sub(/:@[^:]*$/, "", rule)
                        if (rule != "") print rule
                    }
                }
            ' "$GEO_DIR/v2fly_all.yml" > "$GEO_DIR/domains/v2fly_${svc}.txt"
            if [ ! -s "$GEO_DIR/domains/v2fly_${svc}.txt" ]; then
                rm -f "$GEO_DIR/domains/v2fly_${svc}.txt"
                log_msg "WARNING: GeoSite category empty or not found: $svc"
            fi
        done
    fi

    # --- Save custom domains/IPs ---
    local custom_domains=$(get_setting awg_geo_custom_domains)
    if [ -n "$custom_domains" ]; then
        mkdir -p "$GEO_DIR/domains"
        echo "$custom_domains" | tr ',' '\n' > "$GEO_DIR/domains/custom.txt"
    else
        rm -f "$GEO_DIR/domains/custom.txt"
    fi
    local custom_ips=$(get_setting awg_geo_custom_ips)
    if [ -n "$custom_ips" ]; then
        mkdir -p "$GEO_DIR/geoip"
        echo "$custom_ips" | tr ',' '\n' | while read -r cidr; do
            cidr=$(echo "$cidr" | tr -d ' \r')
            [ -n "$cidr" ] && ipset add "$IPSET_NAME" "$cidr" timeout 0 2>/dev/null
        done
    fi

    # Save a conservative floor for static GeoIP/Custom IP entries. Dynamic
    # DNS-derived entries may expire normally and are intentionally excluded
    # from deciding whether an empty set is valid.
    local min_ipset_count=0
    if [ "$ip_count" -gt 0 ] 2>/dev/null || [ -n "$custom_ips" ]; then
        ipset_entries=$(ipset list "$IPSET_NAME" -t 2>/dev/null | \
            awk '/Number of entries/{print $NF}')
        [ -n "$ipset_entries" ] || ipset_entries=0
        min_ipset_count=$((ipset_entries * 9 / 10))
        [ "$ipset_entries" -gt 0 ] 2>/dev/null && \
            [ "$min_ipset_count" -lt 1 ] && min_ipset_count=1
    fi
    echo "$min_ipset_count" > "$IPSET_MIN_COUNT_FILE"

    # --- Build dnsmasq config for domain-based routing ---
    local domain_count=0
    echo "# AmneziaWG domain routing - auto-generated" > "$DNSMASQ_AWG_CONF"
    for f in "$GEO_DIR/domains/custom.txt" "$GEO_DIR"/domains/v2fly_*.txt; do
        [ ! -f "$f" ] && continue
        local chunk_line="ipset=/"
        local chunk_count=0
        while read -r domain; do
            domain=$(echo "$domain" | tr -d ' \r')
            [ -z "$domain" ] && continue
            echo "$domain" | grep -q '^#' && continue
            domain=$(echo "$domain" | sed 's/^\.//;s/:@[^ ]*$//')
            echo "$domain" | grep -q '[^a-zA-Z0-9._-]' && continue
            chunk_line="${chunk_line}${domain}/"
            chunk_count=$((chunk_count + 1))
            domain_count=$((domain_count + 1))
            if [ $chunk_count -ge 20 ]; then
                echo "${chunk_line}${IPSET_NAME}" >> "$DNSMASQ_AWG_CONF"
                chunk_line="ipset=/"
                chunk_count=0
            fi
        done < "$f"
        [ $chunk_count -gt 0 ] && echo "${chunk_line}${IPSET_NAME}" >> "$DNSMASQ_AWG_CONF"
    done

    # Add conf-file include to dnsmasq (idempotent)
    if [ $domain_count -gt 0 ]; then
        if ! grep -qF "conf-file=$DNSMASQ_AWG_CONF" "$DNSMASQ_INCLUDE" 2>/dev/null; then
            echo "conf-file=$DNSMASQ_AWG_CONF" >> "$DNSMASQ_INCLUDE"
        fi
    fi

    # --- Create custom chain in mangle table ---
    iptables -t mangle -N "$AWG_CHAIN" 2>/dev/null || iptables -t mangle -F "$AWG_CHAIN"

    # --- Exclusion rules (evaluated first) ---
    local lan_net
    lan_net=$(get_lan_net)
    local endpoint
    endpoint=$(get_endpoint)

    iptables -t mangle -A "$AWG_CHAIN" -m addrtype --dst-type LOCAL -j RETURN
    [ -n "$lan_net" ] && iptables -t mangle -A "$AWG_CHAIN" -d "$lan_net" -j RETURN
    iptables -t mangle -A "$AWG_CHAIN" -p udp -m multiport --dports 67,68,123 -j RETURN
    iptables -t mangle -A "$AWG_CHAIN" -d 224.0.0.0/4 -j RETURN
    [ -n "$endpoint" ] && iptables -t mangle -A "$AWG_CHAIN" -d "$endpoint" -j RETURN

    # --- Per-device rules (two passes for correct ordering) ---
    save_clients
    if [ -f "$CLIENTS_FILE" ] && [ -s "$CLIENTS_FILE" ]; then

        # Pass 1: "direct" exclusions (RETURN rules must come before MARK rules)
        while IFS=',' read -r dev_id name policy mac || [ -n "$dev_id" ]; do
            dev_id=$(echo "$dev_id" | tr -d ' ')
            policy=$(echo "$policy" | tr -d ' ')
            mac=$(echo "$mac" | tr -d ' ')
            [ -z "$dev_id" ] && continue
            [ "$policy" != "direct" ] && continue

            if [ "$default_policy" != "direct" ]; then
                if [ -n "$mac" ]; then
                    iptables -t mangle -A "$AWG_CHAIN" -m mac --mac-source "$mac" -j RETURN
                else
                    ip rule add from "$dev_id" lookup main prio 97
                fi
                log_msg "Route: $dev_id ($name) -> Direct (excluded)"
            else
                log_msg "Route: $dev_id ($name) -> Direct"
            fi
        done < "$CLIENTS_FILE"

        # Pass 2: vpn_all and vpn_geo rules
        while IFS=',' read -r dev_id name policy mac || [ -n "$dev_id" ]; do
            dev_id=$(echo "$dev_id" | tr -d ' ')
            policy=$(echo "$policy" | tr -d ' ')
            mac=$(echo "$mac" | tr -d ' ')
            [ -z "$dev_id" ] && continue

            case "$policy" in
                vpn_all)
                    if [ -n "$mac" ]; then
                        iptables -t mangle -A "$AWG_CHAIN" -m mac --mac-source "$mac" -j MARK --set-mark "$FWMARK"
                    else
                        ip rule add from "$dev_id" lookup $RT_TABLE prio 99
                    fi
                    log_msg "Route: $dev_id ($name) -> VPN (all)"
                    ;;
                vpn_geo)
                    if ipset list "$IPSET_NAME" >/dev/null 2>&1; then
                        if [ -n "$mac" ]; then
                            iptables -t mangle -A "$AWG_CHAIN" -m mac --mac-source "$mac" \
                                -m set --match-set "$IPSET_NAME" dst -j MARK --set-mark "$FWMARK"
                        else
                            iptables -t mangle -A "$AWG_CHAIN" -s "$dev_id" \
                                -m set --match-set "$IPSET_NAME" dst -j MARK --set-mark "$FWMARK"
                        fi
                        has_geo=true
                        log_msg "Route: $dev_id ($name) -> VPN (geo)"
                    else
                        log_msg "WARNING: ipset missing, skipping geo for $dev_id ($name)"
                    fi
                    ;;
            esac
        done < "$CLIENTS_FILE"
    fi

    # --- Default policy (last rules in chain) ---
    case "$default_policy" in
        vpn_all)
            iptables -t mangle -A "$AWG_CHAIN" -j MARK --set-mark "$FWMARK"
            log_msg "Default: all -> VPN"
            ;;
        vpn_geo)
            if ipset list "$IPSET_NAME" >/dev/null 2>&1; then
                iptables -t mangle -A "$AWG_CHAIN" \
                    -m set --match-set "$IPSET_NAME" dst -j MARK --set-mark "$FWMARK"
                has_geo=true
                log_msg "Default: geo -> VPN"
            else
                log_msg "WARNING: ipset missing, geo default policy not applied"
            fi
            ;;
        direct|*)
            log_msg "Default: direct"
            ;;
    esac

    # --- Hook chain into PREROUTING ---
    iptables -t mangle -C PREROUTING -j "$AWG_CHAIN" 2>/dev/null || \
        iptables -t mangle -A PREROUTING -j "$AWG_CHAIN"

    # --- Single fwmark rule for all marked traffic ---
    ip rule add fwmark "$FWMARK" lookup $RT_TABLE prio 98

    # --- Force DNS through dnsmasq whenever VPN is active ---
    if [ "$default_policy" != "direct" ] || [ "$has_geo" = true ]; then
        setup_dns_interception
    fi

    # --- Restart dnsmasq if geo active ---
    if [ $domain_count -gt 0 ] || [ "$has_geo" = true ]; then
        restart_dnsmasq_and_wait 15
        # Pre-resolve domains to populate ipset
        if [ -f "$DNSMASQ_AWG_CONF" ]; then
            local bg_count=0
            awk -F/ '/^ipset=/{for(i=2;i<NF;i++)print $i}' "$DNSMASQ_AWG_CONF" | while read -r domain; do
                [ -z "$domain" ] && continue
                nslookup "$domain" 127.0.0.1 >/dev/null 2>&1 &
                bg_count=$((bg_count + 1))
                [ $bg_count -ge 10 ] && { wait; bg_count=0; }
            done
            wait
        fi
    fi

    # --- Always flush conntrack so devices reconnect through VPN ---
    flush_conntrack

    # Keep both independent routing systems healthy after every firewall rebuild.
    save_and_set_rp_filter
    ensure_ui_mark_nat
    repair_aux_routing
    register_managed_cron

    log_msg "Firewall configured: $ip_count IPs, $domain_count domains"
}

save_clients(){
    local clients=$(get_setting awg_clients)
    if [ -n "$clients" ]; then
        echo "$clients" | tr ';' '\n' > "$CLIENTS_FILE"
    else
        > "$CLIENTS_FILE"
    fi
}

# Check if geo databases exist locally
geo_available(){
    local svc
    for svc in $(selected_geoip_services); do
        [ -s "$GEO_DIR/geoip/v2fly_${svc}.cidr" ] || return 1
    done
    [ -n "$(get_setting awg_geo_v2fly)" ] && [ ! -s "$GEO_DIR/v2fly_all.yml" ] && return 1
    return 0
}

update_geo_if_needed(){
    local svc selected_services
    mkdir -p "$GEO_DIR/geoip" "$GEO_DIR/domains"
    selected_services=$(selected_geoip_services)

    # Apply must be sufficient when a category is deselected.  Prune before
    # downloading missing selections and before setup_firewall runs.
    prune_unselected_geoip_lists "$selected_services"

    for svc in $selected_services; do
        [ -s "$GEO_DIR/geoip/v2fly_${svc}.cidr" ] && continue
        log_msg "GeoIP: downloading newly selected $svc..."
        download_geoip_service "$svc" || log_msg "WARNING: GeoIP $svc download failed"
    done
    if [ -n "$(get_setting awg_geo_v2fly)" ] && [ ! -s "$GEO_DIR/v2fly_all.yml" ]; then
        log_msg "WARNING: GeoSite database not downloaded. Use Update Now in web UI."
    fi
}

# Force re-download all geo databases
update_geo_lists(){
    download_all_geo
}

# --- Validation helpers ---

validate_wgkey(){
    echo "$1" | grep -qE '^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$' && return 0
    log_msg "ERROR: Invalid WireGuard key"
    return 1
}

validate_endpoint(){
    local host port
    port="${1##*:}"
    host="${1%:*}"
    echo "$port" | grep -qE '^[0-9]+$' || { log_msg "ERROR: Invalid endpoint port: $1"; return 1; }
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] 2>/dev/null || { log_msg "ERROR: Endpoint port out of range: $port"; return 1; }
    [ -n "$host" ] || { log_msg "ERROR: Empty endpoint host"; return 1; }
    return 0
}

validate_port(){
    echo "$1" | grep -qE '^[0-9]+$' || return 1
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ] 2>/dev/null || return 1
    return 0
}

validate_uint(){
    echo "$1" | grep -qE '^[0-9]+$' || return 1
    return 0
}

validate_uint_or_range() {
    echo "$1" | grep -qE '^[0-9]+(-[0-9]+)?$' || return 1

    case "$1" in
        *-*)
            start=${1%-*}
            end=${1#*-}
            [ "$start" -le "$end" ] || return 1
            ;;
    esac

    return 0
}

validate_ip(){
    echo "$1" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' || return 1
    return 0
}

# --- Generate awg0.conf ---

generate_config(){
    mkdir -p "$AWG_DIR"

    local privkey=$(get_setting awg_privatekey)
    local listenport=$(get_setting awg_listenport)
    local jc=$(get_setting awg_jc)
    local jmin=$(get_setting awg_jmin)
    local jmax=$(get_setting awg_jmax)
    local s1=$(get_setting awg_s1)
    local s2=$(get_setting awg_s2)
    local s3=$(get_setting awg_s3)
    local s4=$(get_setting awg_s4)
    local h1=$(get_setting awg_h1)
    local h2=$(get_setting awg_h2)
    local h3=$(get_setting awg_h3)
    local h4=$(get_setting awg_h4)
    local header_protection_key=$(get_setting awg_header_protection_key)
    local content_padding_addition=$(get_setting awg_content_padding_addition)
    local rekey_after_time=$(get_setting awg_rekey_after_time)
    local rekey_timeout=$(get_setting awg_rekey_timeout)
    local reject_after_time=$(get_setting awg_reject_after_time)
    local keepalive_timeout=$(get_setting awg_keepalive_timeout)
    local max_handshake_attempts=$(get_setting awg_max_handshake_attempts)
    local random_trailers=$(get_setting awg_random_trailers)
    local disable_cookies=$(get_setting awg_disable_cookies)

    # I1-I5 from base64-encoded setting
    local i1="" i2="" i3="" i4="" i5=""
    local initdata=$(get_setting awg_initdata)
    if [ -n "$initdata" ]; then
        local decoded
        decoded=$(echo "$initdata" | base64 -d 2>/dev/null)
        i1=$(echo "$decoded" | awk '/^I1 /{sub(/^[^=]+=[ ]?/,"");print;exit}')
        i2=$(echo "$decoded" | awk '/^I2 /{sub(/^[^=]+=[ ]?/,"");print;exit}')
        i3=$(echo "$decoded" | awk '/^I3 /{sub(/^[^=]+=[ ]?/,"");print;exit}')
        i4=$(echo "$decoded" | awk '/^I4 /{sub(/^[^=]+=[ ]?/,"");print;exit}')
        i5=$(echo "$decoded" | awk '/^I5 /{sub(/^[^=]+=[ ]?/,"");print;exit}')
    fi

    local peer_pubkey=$(get_setting awg_peer_pubkey)
    local peer_psk=$(get_setting awg_peer_psk)
    local peer_endpoint=$(get_setting awg_peer_endpoint)
    local peer_allowedips=$(get_setting awg_peer_allowedips | sed 's/,[[:space:]]*$//;s/,/, /g')
    local peer_keepalive=$(get_setting awg_peer_keepalive)

    if [ -z "$privkey" ] || [ -z "$peer_pubkey" ] || [ -z "$peer_endpoint" ]; then
        log_msg "ERROR: Missing required config"
        return 1
    fi
    validate_wgkey "$privkey" || return 1
    validate_wgkey "$peer_pubkey" || return 1
    [ -n "$peer_psk" ] && { validate_wgkey "$peer_psk" || return 1; }
    validate_endpoint "$peer_endpoint" || return 1
    [ -n "$listenport" ] && { validate_port "$listenport" || { log_msg "ERROR: Invalid listen port: $listenport"; return 1; }; }
    [ -n "$jc" ] && { validate_uint "$jc" || { log_msg "ERROR: Invalid Jc: $jc"; return 1; }; }
    [ -n "$jmin" ] && { validate_uint "$jmin" || { log_msg "ERROR: Invalid Jmin: $jmin"; return 1; }; }
    [ -n "$jmax" ] && { validate_uint "$jmax" || { log_msg "ERROR: Invalid Jmax: $jmax"; return 1; }; }
    [ -n "$s1" ] && { validate_uint "$s1" || { log_msg "ERROR: Invalid S1: $s1"; return 1; }; }
    [ -n "$s2" ] && { validate_uint "$s2" || { log_msg "ERROR: Invalid S2: $s2"; return 1; }; }
    [ -n "$s3" ] && { validate_uint "$s3" || { log_msg "ERROR: Invalid S3: $s3"; return 1; }; }
    [ -n "$s4" ] && { validate_uint "$s4" || { log_msg "ERROR: Invalid S4: $s4"; return 1; }; }
    [ -n "$h1" ] && { validate_uint_or_range "$h1" || { log_msg "ERROR: Invalid H1: $h1"; return 1; }; }
    [ -n "$h2" ] && { validate_uint_or_range "$h2" || { log_msg "ERROR: Invalid H2: $h2"; return 1; }; }
    [ -n "$h3" ] && { validate_uint_or_range "$h3" || { log_msg "ERROR: Invalid H3: $h3"; return 1; }; }
    [ -n "$h4" ] && { validate_uint_or_range "$h4" || { log_msg "ERROR: Invalid H4: $h4"; return 1; }; }
    [ -n "$header_protection_key" ] && { validate_wgkey "$header_protection_key" || { log_msg "ERROR: Invalid HeaderProtectionKey"; return 1; }; }
    if [ -n "$header_protection_key" ]; then
        for padding in "$s1" "$s2" "$s3" "$s4"; do
            [ -n "$padding" ] && [ "$padding" -ge 12 ] 2>/dev/null || { log_msg "ERROR: HeaderProtectionKey requires S1-S4 >= 12"; return 1; }
        done
    fi
    for range_setting in "$content_padding_addition" "$rekey_after_time" "$rekey_timeout" "$reject_after_time" "$keepalive_timeout" "$max_handshake_attempts"; do
        [ -z "$range_setting" ] || validate_uint_or_range "$range_setting" || { log_msg "ERROR: Invalid AWG 3.x range: $range_setting"; return 1; }
    done
    case "$random_trailers" in ""|on|off) ;; *) log_msg "ERROR: RandomTrailers must be on or off"; return 1 ;; esac
    case "$disable_cookies" in ""|on|off) ;; *) log_msg "ERROR: DisableCookies must be on or off"; return 1 ;; esac

    {
        echo "[Interface]"
        echo "PrivateKey = $privkey"
        [ -n "$listenport" ] && echo "ListenPort = $listenport"
        [ -n "$jc" ] && echo "Jc = $jc"
        [ -n "$jmin" ] && echo "Jmin = $jmin"
        [ -n "$jmax" ] && echo "Jmax = $jmax"
        [ -n "$s1" ] && echo "S1 = $s1"
        [ -n "$s2" ] && echo "S2 = $s2"
        [ -n "$s3" ] && echo "S3 = $s3"
        [ -n "$s4" ] && echo "S4 = $s4"
        [ -n "$h1" ] && echo "H1 = $h1"
        [ -n "$h2" ] && echo "H2 = $h2"
        [ -n "$h3" ] && echo "H3 = $h3"
        [ -n "$h4" ] && echo "H4 = $h4"
        [ -n "$header_protection_key" ] && echo "HeaderProtectionKey = $header_protection_key"
        [ -n "$content_padding_addition" ] && echo "ContentPaddingAddition = $content_padding_addition"
        [ -n "$rekey_after_time" ] && echo "RekeyAfterTime = $rekey_after_time"
        [ -n "$rekey_timeout" ] && echo "RekeyTimeout = $rekey_timeout"
        [ -n "$reject_after_time" ] && echo "RejectAfterTime = $reject_after_time"
        [ -n "$keepalive_timeout" ] && echo "KeepaliveTimeout = $keepalive_timeout"
        [ -n "$max_handshake_attempts" ] && echo "MaxHandshakeAttempts = $max_handshake_attempts"
        [ -n "$random_trailers" ] && echo "RandomTrailers = $random_trailers"
        [ -n "$disable_cookies" ] && echo "DisableCookies = $disable_cookies"
        [ -n "$i1" ] && echo "I1 = $i1"
        [ -n "$i2" ] && echo "I2 = $i2"
        [ -n "$i3" ] && echo "I3 = $i3"
        [ -n "$i4" ] && echo "I4 = $i4"
        [ -n "$i5" ] && echo "I5 = $i5"
        echo ""
        echo "[Peer]"
        echo "PublicKey = $peer_pubkey"
        [ -n "$peer_psk" ] && echo "PresharedKey = $peer_psk"
        [ -n "$peer_endpoint" ] && echo "Endpoint = $peer_endpoint"
        echo "AllowedIPs = ${peer_allowedips:-0.0.0.0/0}"
        [ -n "$peer_keepalive" ] && echo "PersistentKeepalive = $peer_keepalive"
    } > "$CONF"

    chmod 600 "$CONF"

    local address=$(get_setting awg_address)
    [ -n "$address" ] && echo "$address" > "$AWG_DIR/awg0.addr"
    local dns=$(get_setting awg_dns)
    [ -n "$dns" ] && echo "$dns" > "$AWG_DIR/awg0.dns"

    log_msg "Config saved"
    return 0
}

# --- Start ---

do_start(){
    # Skip if update in progress (opkg triggers S99amneziawg start)
    [ -f /tmp/.awg_no_autostart ] && { log_msg "Start blocked: update in progress"; return 0; }

    if is_running; then
        log_msg "Already running"
        ensure_ui_mark_nat
        repair_aux_routing
        register_managed_cron
        update_status
        return 0
    fi

    # Wait for network to be ready (br0 up with IP), important on boot
    if ! ip -4 addr show br0 2>/dev/null | grep -q "inet "; then
        log_msg "Waiting for network (br0)..."
        wait_for_iface_ip br0 30
        if ! ip -4 addr show br0 2>/dev/null | grep -q "inet "; then
            log_msg "ERROR: Network not ready (br0 has no IP after 30s)"
            return 1
        fi
    fi

    acquire_lock || { log_msg "Cannot acquire lock, aborting start"; update_status; return 1; }

    generate_config || { update_status; release_lock; return 1; }
    [ ! -f "$CONF" ] && { log_msg "ERROR: No config"; update_status; release_lock; return 1; }
    [ ! -f "$AWG_GO" ] && { log_msg "ERROR: amneziawg-go not found"; update_status; release_lock; return 1; }

    # Ensure TUN device exists
    modprobe tun 2>/dev/null
    mkdir -p /dev/net
    [ ! -c /dev/net/tun ] && mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun

    # Start userspace daemon
    mkdir -p /var/run/amneziawg
    "$AWG_GO" "$IFACE" > /tmp/awg_daemon.log 2>&1 &
    if ! wait_for_iface "$IFACE" 10; then
        log_msg "ERROR: amneziawg-go failed to create interface"
        [ -f /tmp/awg_daemon.log ] && log_msg "Daemon output: $(cat /tmp/awg_daemon.log)"
        update_status; release_lock; return 1
    fi
    log_msg "Userspace daemon started"

    # Configure interface
    "$AWG_BIN" setconf "$IFACE" "$CONF" || { log_msg "ERROR: setconf failed"; ip link del "$IFACE" 2>/dev/null; update_status; release_lock; return 1; }

    [ -f "$AWG_DIR/awg0.addr" ] && ip addr add "$(cat "$AWG_DIR/awg0.addr")" dev "$IFACE"
    ip link set "$IFACE" mtu 1280
    ip link set "$IFACE" up

    # Routing table
    local lan_net gw endpoint
    lan_net=$(get_lan_net)
    gw=$(ip route | awk '/^default/{print $3; exit}')
    endpoint=$(get_endpoint)
    [ -n "$endpoint" ] && [ -n "$gw" ] && ip route add "$endpoint" via "$gw" 2>/dev/null
    ensure_main_routes

    save_and_set_rp_filter

    # Base iptables
    iptables -I INPUT -i "$IFACE" -j ACCEPT
    iptables -I FORWARD -i "$IFACE" -j ACCEPT
    iptables -I FORWARD -o "$IFACE" -j ACCEPT
    setup_ipv6_block
    iptables -t mangle -A FORWARD -o "$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -t mangle -A FORWARD -i "$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    if [ -n "$lan_net" ]; then
        iptables -t nat -I POSTROUTING -s "$lan_net" -o "$IFACE" -j MASQUERADE
    else
        iptables -t nat -I POSTROUTING -o "$IFACE" -j MASQUERADE
    fi

    setup_firewall

    # Route for router-originated traffic (after setup_firewall which cleans ip rules)
    local awg_addr
    awg_addr=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{sub(/\/.*/, "", $2); print $2; exit}')
    [ -n "$awg_addr" ] && ip rule add from "$awg_addr" lookup $RT_TABLE prio 100

    log_msg "Started, verifying tunnel connectivity..."
    update_status
    release_lock

    # Health check: verify tunnel passes traffic, rollback if not
    local hc_ok=false
    local hc_try=0
    while [ $hc_try -lt 30 ]; do
        if ping -c 1 -W 2 -I "$IFACE" 8.8.8.8 >/dev/null 2>&1; then
            hc_ok=true
            break
        fi
        hc_try=$((hc_try + 1))
        sleep 2
    done
    if [ "$hc_ok" = true ]; then
        log_msg "Tunnel verified: traffic passing"
        update_status
    else
        log_msg "ERROR: Tunnel not passing traffic after 60s, rolling back to prevent lockout"
        do_stop 2>/dev/null
        log_msg "VPN stopped automatically. Check server config and endpoint reachability."
        update_status
    fi
}

# --- Stop ---

do_stop(){
    acquire_lock || { log_msg "Cannot acquire lock, aborting stop"; return 1; }

    remove_managed_cron

    iptables -D INPUT -i "$IFACE" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i "$IFACE" -j ACCEPT 2>/dev/null
    iptables -D FORWARD -o "$IFACE" -j ACCEPT 2>/dev/null
    cleanup_ipv6_block
    iptables -t mangle -D FORWARD -o "$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
    iptables -t mangle -D FORWARD -i "$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
    local lan_net
    lan_net=$(get_lan_net)
    [ -n "$lan_net" ] && iptables -t nat -D POSTROUTING -s "$lan_net" -o "$IFACE" -j MASQUERADE 2>/dev/null
    iptables -t nat -D POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null

    cleanup_firewall
    remove_ui_mark_nat
    disable_aux_routing

    ip route flush table $RT_TABLE 2>/dev/null
    local endpoint
    endpoint=$(get_endpoint)
    [ -n "$endpoint" ] && ip route del "$endpoint" 2>/dev/null

    restore_rp_filter

    # Stop daemon
    ip link set "$IFACE" down 2>/dev/null
    ip link del "$IFACE" 2>/dev/null
    local awg_pid
    awg_pid=$(pidof amneziawg-go 2>/dev/null)
    if [ -n "$awg_pid" ]; then
        kill "$awg_pid" 2>/dev/null
        wait_for_pid_exit amneziawg-go 5
        # Force kill if still alive (crashed/stuck process)
        pidof amneziawg-go >/dev/null 2>&1 && kill -9 "$(pidof amneziawg-go)" 2>/dev/null
    fi
    rm -f /var/run/amneziawg/"$IFACE".sock

    restart_dnsmasq_and_wait 15

    log_msg "Stopped"
    update_status
    release_lock
}

# --- Status JSON for web UI ---

update_status(){
    local running=false
    local pub_key=""
    local listen_port=""
    local iface_addr=""
    local peers_json="[]"
    local log_text=""

    if is_running; then
        running=true
        iface_addr=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2; exit}')
        listen_port=$("$AWG_BIN" show "$IFACE" listen-port 2>/dev/null)
        pub_key=$("$AWG_BIN" show "$IFACE" public-key 2>/dev/null)

        local dump=$("$AWG_BIN" show "$IFACE" dump 2>/dev/null | tail -n +2)
        if [ -n "$dump" ]; then
            local p_items=""
            while IFS='	' read -r pkey psk endpoint aips handshake rx tx keepalive; do
                local hs_text="never"
                if [ "$handshake" != "0" ] && [ -n "$handshake" ]; then
                    local ago=$(( $(date +%s) - handshake ))
                    if [ $ago -lt 60 ]; then hs_text="${ago}s ago"
                    elif [ $ago -lt 3600 ]; then hs_text="$(( ago / 60 ))m ago"
                    else hs_text="$(( ago / 3600 ))h ago"; fi
                fi
                local rx_h=$(human_size "${rx:-0}")
                local tx_h=$(human_size "${tx:-0}")
                local item="{\"endpoint\":\"${endpoint}\",\"allowed_ips\":\"${aips}\",\"transfer_rx\":\"${rx_h}\",\"transfer_tx\":\"${tx_h}\",\"latest_handshake\":\"${hs_text}\"}"
                [ -n "$p_items" ] && p_items="${p_items},${item}" || p_items="$item"
            done <<EOF
$dump
EOF
            peers_json="[${p_items}]"
        fi
    fi

    log_text=$(grep "amneziawg" /tmp/syslog.log 2>/dev/null | tail -20 | sed 's/"/\\"/g' | tr '\n' '|' | sed 's/|/\\n/g')

    local default_policy=$(get_setting awg_default_policy)
    [ -z "$default_policy" ] && default_policy="direct"
    local clients_data=$(get_setting awg_clients | sed 's/"/\\"/g')
    local active_rules=$(ip rule show 2>/dev/null | grep -c "lookup $RT_TABLE\|fwmark $FWMARK")

    local ipset_count=0
    ipset list "$IPSET_NAME" -t 2>/dev/null | grep -q "Number of entries" && \
        ipset_count=$(ipset list "$IPSET_NAME" -t 2>/dev/null | awk '/Number of entries/{print $NF}')

    local antifilter_active=false
    local antifilter_count=0
    antifilter_enabled && antifilter_active=true
    ipset list MYAWG -t 2>/dev/null | grep -q "Number of entries" && \
        antifilter_count=$(ipset list MYAWG -t 2>/dev/null | awk '/Number of entries/{print $NF}')

    local geo_domains=0
    [ -f "$DNSMASQ_AWG_CONF" ] && geo_domains=$(grep -c "^ipset=" "$DNSMASQ_AWG_CONF" 2>/dev/null)
    [ -z "$geo_domains" ] && geo_domains=0

    local geo_downloaded=false
    geo_available && geo_downloaded=true

    local package_version go_version tools_version
    package_version=$(/opt/bin/opkg status amneziawg 2>/dev/null | awk '/^Version:/{print $2; exit}')
    [ -z "$package_version" ] && package_version="$AWG_VERSION"
    go_version=$(cat /opt/amneziawg/amneziawg-go.version 2>/dev/null)
    tools_version=$(cat /opt/amneziawg/amneziawg-tools.version 2>/dev/null)
    [ -n "$go_version" ] || go_version=$("$AWG_GO" --version 2>/dev/null | awk 'NR==1{print $2}')
    [ -n "$tools_version" ] || tools_version=$("$AWG_BIN" --version 2>/dev/null | awk 'NR==1{print $2}')

    cat > "$STATUS_FILE" << STATUSEOF
{"running":${running},"version":"${AWG_VERSION}","package_version":"${package_version}","go_version":"${go_version}","tools_version":"${tools_version}","public_key":"${pub_key}","listen_port":"${listen_port}","interface_addr":"${iface_addr}","peers":${peers_json},"default_policy":"${default_policy}","clients":"${clients_data}","active_rules":${active_rules},"ipset_count":${ipset_count},"geo_domains":${geo_domains},"geo_downloaded":${geo_downloaded},"antifilter_enabled":${antifilter_active},"antifilter_count":${antifilter_count},"log":"${log_text}"}
STATUSEOF
}

# --- Install/Mount/Uninstall ---

do_install_page(){
    source /usr/sbin/helper.sh
    nvram get rc_support | grep -q am_addons || { log_msg "ERROR: Addons not supported"; return 1; }

    mkdir -p "$ADDON_DIR"
    [ "$(readlink -f "$0")" != "$(readlink -f "$ADDON_DIR/amneziawg.sh")" ] && cp "$0" "$ADDON_DIR/amneziawg.sh"
    chmod +x "$ADDON_DIR/amneziawg.sh"
    [ -f "$AUX_IPSET_SCRIPT" ] && chmod +x "$AUX_IPSET_SCRIPT"

    migrate_legacy_ipset

    [ -f "/tmp/amneziawg_page.asp" ] && cp /tmp/amneziawg_page.asp "$ADDON_DIR/amneziawg_page.asp"

    # Clean old page slots before requesting a new one
    for f in /www/user/user*.asp; do
        grep -q "AmneziaWG" "$f" 2>/dev/null && rm -f "$f"
    done

    am_get_webui_page "$ADDON_DIR/amneziawg_page.asp"
    [ "$am_webui_page" = "none" ] && { log_msg "ERROR: No page slot"; return 1; }

    cp "$ADDON_DIR/amneziawg_page.asp" "/www/user/$am_webui_page"
    mount_menu_tree "$am_webui_page"

    echo '{"running":false,"peers":[],"log":"Installed."}' > "$STATUS_FILE"

    [ ! -f /jffs/scripts/service-event ] && echo "#!/bin/sh" > /jffs/scripts/service-event && chmod +x /jffs/scripts/service-event
    if ! grep -q "amneziawg" /jffs/scripts/service-event; then
        echo 'echo "$2" | grep -q "^awg" && /jffs/addons/amneziawg/amneziawg.sh "service_event" "$1" "$2"' >> /jffs/scripts/service-event
    fi

    # WAN event hook
    [ ! -f /jffs/scripts/wan-event ] && echo "#!/bin/sh" > /jffs/scripts/wan-event && chmod +x /jffs/scripts/wan-event
    if ! grep -q "amneziawg" /jffs/scripts/wan-event; then
        echo '/jffs/addons/amneziawg/amneziawg.sh wan_event "$1" "$2"  # AmneziaWG' >> /jffs/scripts/wan-event
    fi

    # Firewall restart hook
    [ ! -f /jffs/scripts/firewall-start ] && echo "#!/bin/sh" > /jffs/scripts/firewall-start && chmod +x /jffs/scripts/firewall-start
    if ! grep -q "amneziawg" /jffs/scripts/firewall-start; then
        echo '/jffs/addons/amneziawg/amneziawg.sh firewall_restart  # AmneziaWG' >> /jffs/scripts/firewall-start
    fi

    [ ! -f /jffs/scripts/services-start ] && echo "#!/bin/sh" > /jffs/scripts/services-start && chmod +x /jffs/scripts/services-start
    grep -q "amneziawg" /jffs/scripts/services-start || echo "/jffs/addons/amneziawg/amneziawg.sh mount_ui &" >> /jffs/scripts/services-start

    [ -f "$GEO_DIR/v2fly_categories.txt" ] && cp "$GEO_DIR/v2fly_categories.txt" /www/user/v2fly_categories.htm 2>/dev/null

    if is_running; then
        repair_aux_routing
        register_managed_cron
    fi

    log_msg "Page installed: $am_webui_page"
    echo "Installed. Access: VPN > AmneziaWG"
}

do_mount_ui(){
    source /usr/sbin/helper.sh
    # Clean old slots
    for f in /www/user/user*.asp; do
        grep -q "AmneziaWG" "$f" 2>/dev/null && rm -f "$f"
    done
    am_get_webui_page "$ADDON_DIR/amneziawg_page.asp"
    if [ "$am_webui_page" != "none" ]; then
        cp "$ADDON_DIR/amneziawg_page.asp" "/www/user/$am_webui_page"
        mount_menu_tree "$am_webui_page"
    fi

    [ -f "$GEO_DIR/v2fly_categories.txt" ] && cp "$GEO_DIR/v2fly_categories.txt" /www/user/v2fly_categories.htm 2>/dev/null
    update_status

    if [ "$(get_setting awg_autostart)" = "1" ]; then
        sleep 10
        do_start
    fi
}

do_uninstall(){
    do_stop

    [ -x "$AUX_IPSET_SCRIPT" ] && "$AUX_IPSET_SCRIPT" --cleanup 2>/dev/null
    remove_managed_cron

    [ -f /jffs/scripts/service-event ] && sed -i '/amneziawg/d' /jffs/scripts/service-event
    [ -f /jffs/scripts/services-start ] && sed -i '/amneziawg/d' /jffs/scripts/services-start
    [ -f /jffs/scripts/wan-event ] && sed -i '/amneziawg/d' /jffs/scripts/wan-event
    [ -f /jffs/scripts/firewall-start ] && sed -i '/amneziawg/d' /jffs/scripts/firewall-start

    local page=$(ls /www/user/ 2>/dev/null | while read f; do grep -l "AmneziaWG" "/www/user/$f" 2>/dev/null; done | head -1)
    [ -n "$page" ] && rm -f "$page"
    rm -f "$STATUS_FILE" /www/user/v2fly_categories.htm

    rm -rf "$ADDON_DIR"

    if [ -f /tmp/menuTree.js ]; then
        sed -i '/AmneziaWG/d' /tmp/menuTree.js
        umount /www/require/modules/menuTree.js 2>/dev/null
        mount -o bind /tmp/menuTree.js /www/require/modules/menuTree.js
    fi

    log_msg "Uninstalled"
}

# --- Watchdog (called by cron every 5 min) ---

do_watchdog(){
    # Skip if lock held (another operation in progress)
    [ -d "$LOCKDIR" ] && return 0

    local reason=""
    if ! ip link show "$IFACE" >/dev/null 2>&1; then
        reason="interface $IFACE missing"
    elif ! pidof amneziawg-go >/dev/null 2>&1; then
        reason="amneziawg-go process dead"
    elif ! ping -c 1 -W 5 -I "$IFACE" 8.8.8.8 >/dev/null 2>&1; then
        reason="tunnel not passing traffic"
    fi

    if [ -n "$reason" ]; then
        log_msg "WATCHDOG: $reason, restarting"
        do_stop 2>/dev/null
        wait_for_pid_exit amneziawg-go 10
        do_start
        return $?
    fi

    # Rebuild only when a core table-300/firewall component is missing.
    if ! main_firewall_healthy; then
        log_msg "WATCHDOG: firewall or table 300 incomplete, repairing"
        do_firewall_restart
        if ! main_firewall_healthy; then
            log_msg "ERROR: WATCHDOG firewall repair failed"
            return 1
        fi
    fi

    # Firmware can reset rp_filter and awg0 recreation removes table 400.
    save_and_set_rp_filter
    ensure_ui_mark_nat
    repair_aux_routing
}

# --- Update check ---

latest_upstream_tag(){
    local repo="$1" prefix="$2"
    curl -sfL --connect-timeout 10 --max-time 15 \
        "https://api.github.com/repos/${repo}/tags?per_page=30" 2>/dev/null | \
        grep '"name"' | sed 's/.*"name"[[:space:]]*:[[:space:]]*"//;s/".*//' | \
        grep "^${prefix}" | head -1
}

check_update(){
    local current latest installed_go installed_tools latest_go latest_tools
    current=$(/opt/bin/opkg status amneziawg 2>/dev/null | awk '/^Version:/{print $2; exit}')
    [ -z "$current" ] && current="$AWG_VERSION"
    latest=$(curl -sfL --connect-timeout 10 --max-time 15 \
        "https://api.github.com/repos/${UPDATE_REPO}/releases/latest" 2>/dev/null | \
        grep '"tag_name"' | head -1 | sed 's/.*"v//;s/".*//')
    installed_go=$(cat /opt/amneziawg/amneziawg-go.version 2>/dev/null)
    installed_tools=$(cat /opt/amneziawg/amneziawg-tools.version 2>/dev/null)
    [ -n "$installed_go" ] || installed_go=$("$AWG_GO" --version 2>/dev/null | awk 'NR==1{print $2}')
    [ -n "$installed_tools" ] || installed_tools=$("$AWG_BIN" --version 2>/dev/null | awk 'NR==1{print $2}')
    latest_go=$(latest_upstream_tag "amnezia-vpn/amneziawg-go" "v3.1.")
    latest_tools=$(latest_upstream_tag "amnezia-vpn/amneziawg-tools" "v3.1.")
    local update=false
    [ -n "$latest" ] && [ "$latest" != "$current" ] && update=true
    local error=""
    [ -z "$latest_go" ] || [ -z "$latest_tools" ] && error="Cannot reach one or more GitHub repositories"
    echo "{\"current\":\"$current\",\"latest\":\"$latest\",\"update\":$update,\"installed_go\":\"$installed_go\",\"latest_go\":\"$latest_go\",\"installed_tools\":\"$installed_tools\",\"latest_tools\":\"$latest_tools\",\"error\":\"$error\"}"
}

do_update(){
    log_msg "Updating AmneziaWG..."
    local pkg_arch
    pkg_arch=$(opkg print-architecture 2>/dev/null | awk '$1=="arch" && $2!="all" {print $2}' | head -1)
    if [ -z "$pkg_arch" ]; then
        local arch=$(uname -m)
        case "$arch" in
            aarch64) pkg_arch="aarch64-3.10" ;;
            armv7l)  pkg_arch="armv7-2.6" ;;
            *) log_msg "ERROR: Unsupported arch: $arch"; return 1 ;;
        esac
    fi

    local release_json
    release_json=$(curl -sfL --connect-timeout 10 --max-time 15 "https://api.github.com/repos/${UPDATE_REPO}/releases/latest" 2>/dev/null)
    local ipk_url sums_url latest
    latest=$(echo "$release_json" | grep '"tag_name"' | head -1 | sed 's/.*"v//;s/".*//')
    ipk_url=$(echo "$release_json" | grep '"browser_download_url"' | grep "$pkg_arch" | grep '.ipk"' | head -1 | sed 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"//;s/".*//')
    if [ -z "$ipk_url" ]; then
        local base_arch=$(echo "$pkg_arch" | sed 's/-.*//')
        ipk_url=$(echo "$release_json" | grep '"browser_download_url"' | grep "${base_arch}" | grep '.ipk"' | head -1 | sed 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"//;s/".*//')
    fi
    if [ -z "$ipk_url" ]; then
        log_msg "ERROR: No package found for $pkg_arch"
        return 1
    fi
    sums_url=$(echo "$release_json" | grep '"browser_download_url"' | grep '/SHA256SUMS"' | head -1 | sed 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"//;s/".*//')
    if [ -z "$sums_url" ]; then
        log_msg "ERROR: SHA256SUMS not found in release"
        return 1
    fi

    local tmp="/tmp/amneziawg_update.ipk"
    local sums="/tmp/amneziawg_SHA256SUMS"
    if ! curl -sfL --connect-timeout 10 --max-time 120 "$ipk_url" -o "$tmp"; then
        log_msg "ERROR: Download failed"
        return 1
    fi
    if ! curl -sfL --connect-timeout 10 --max-time 30 "$sums_url" -o "$sums"; then
        rm -f "$tmp"
        log_msg "ERROR: SHA256SUMS download failed"
        return 1
    fi
    local expected actual package_name
    package_name=$(basename "$ipk_url")
    expected=$(awk -v f="$package_name" '$2==f || $2=="*"f {print $1; exit}' "$sums")
    actual=$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}')
    rm -f "$sums"
    if [ -z "$expected" ] || [ "$actual" != "$expected" ]; then
        rm -f "$tmp"
        log_msg "ERROR: Package SHA256 mismatch"
        return 1
    fi

    local backup_dir="/opt/backup-amneziawg-before-${latest:-update}-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    cp -a "$SETTINGS" "$backup_dir/" 2>/dev/null || true
    cp -a "$CONF" "$AWG_DIR/awg0.addr" "$CLIENTS_FILE" "$backup_dir/" 2>/dev/null || true
    log_msg "Backup saved: $backup_dir"

    do_stop 2>/dev/null
    wait_for_pid_exit amneziawg-go 10
    # Block auto-start during opkg install (S99amneziawg is triggered by opkg)
    touch /tmp/.awg_no_autostart
    if ! /opt/bin/opkg install "$tmp" && ! /opt/bin/opkg install --force-architecture "$tmp"; then
        rm -f "$tmp" /tmp/.awg_no_autostart
        log_msg "ERROR: Package installation failed"
        return 1
    fi
    rm -f "$tmp"
    # Stop VPN if opkg's init script started it
    do_stop 2>/dev/null
    wait_for_pid_exit amneziawg-go 10
    rm -f /tmp/.awg_no_autostart
    # Install page from new version
    /jffs/addons/amneziawg/amneziawg.sh install_page
    log_msg "Update complete. Start VPN from UI."
    update_status
}

do_wan_event(){
    local wan_if="$1" wan_state="$2"
    [ "$wan_state" != "connected" ] && return 0
    if is_running; then
        log_msg "WAN event: $wan_state on $wan_if, updating endpoint route"
        local gw endpoint
        gw=$(ip route | awk '/^default/{print $3; exit}')
        endpoint=$(get_endpoint)
        if [ -n "$endpoint" ] && [ -n "$gw" ]; then
            ip route del "$endpoint" 2>/dev/null
            ip route add "$endpoint" via "$gw" 2>/dev/null
            log_msg "Endpoint route updated: $endpoint via $gw"
        fi
    fi
}

do_firewall_restart(){
    if is_running; then
        log_msg "Firewall restart detected, re-applying rules"
        # Clean base rules first to prevent duplicates
        iptables -D INPUT -i "$IFACE" -j ACCEPT 2>/dev/null
        iptables -D FORWARD -i "$IFACE" -j ACCEPT 2>/dev/null
        iptables -D FORWARD -o "$IFACE" -j ACCEPT 2>/dev/null
        iptables -t mangle -D FORWARD -o "$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
        iptables -t mangle -D FORWARD -i "$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
        local lan_net_old
        lan_net_old=$(get_lan_net)
        [ -n "$lan_net_old" ] && iptables -t nat -D POSTROUTING -s "$lan_net_old" -o "$IFACE" -j MASQUERADE 2>/dev/null
        iptables -t nat -D POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null
        cleanup_ipv6_block
        iptables -I INPUT -i "$IFACE" -j ACCEPT
        iptables -I FORWARD -i "$IFACE" -j ACCEPT
        iptables -I FORWARD -o "$IFACE" -j ACCEPT
        iptables -t mangle -A FORWARD -o "$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        iptables -t mangle -A FORWARD -i "$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        local lan_net
        lan_net=$(get_lan_net)
        if [ -n "$lan_net" ]; then
            iptables -t nat -I POSTROUTING -s "$lan_net" -o "$IFACE" -j MASQUERADE
        else
            iptables -t nat -I POSTROUTING -o "$IFACE" -j MASQUERADE
        fi
        setup_ipv6_block
        setup_firewall
        ensure_main_routes
        local awg_addr
        awg_addr=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{sub(/\/.*/, "", $2); print $2; exit}')
        [ -n "$awg_addr" ] && ip rule add from "$awg_addr" lookup $RT_TABLE prio 100
    fi
}

# --- Service event dispatcher ---

do_service_event(){
    local event="$2"
    case "$event" in
        awgstart)       do_start ;;
        awgstop)        do_stop ;;
        awgrestart)     do_stop; wait_for_pid_exit amneziawg-go 10; do_start ;;
        awgsaveconf)
            local _wt=0; while [ $_wt -lt 5 ] && [ -z "$(get_setting awg_privatekey)" ]; do sleep 1; _wt=$((_wt+1)); done
            generate_config
            update_geo_if_needed
            if is_running; then
                setup_firewall
            elif ! antifilter_enabled; then
                disable_aux_routing
            fi
            update_status
            ;;
        awgupdategeo)
            update_geo_lists
            is_running && setup_firewall
            update_status
            ;;
        awgupdateantifilter)
            update_antifilter
            update_status
            ;;
        awgcheckupdate)
            check_update > /www/user/awg_update.htm
            ;;
        awgdoupdate)
            do_update
            update_status
            ;;
    esac
}

# --- Main ---

case "$1" in
    start)          do_start ;;
    stop)           do_stop ;;
    restart)        do_stop; wait_for_pid_exit amneziawg-go 10; do_start ;;
    status)         update_status ;;
    update_geo)     update_geo_lists; is_running && setup_firewall; update_status ;;
    update_ipset)   update_antifilter ;;
    check_update)   check_update ;;
    update)         do_update ;;
    watchdog)       do_watchdog ;;
    install_page)   do_install_page ;;
    mount_ui)       do_mount_ui ;;
    uninstall)      do_uninstall ;;
    service_event)  do_service_event "$2" "$3" ;;
    wan_event)      do_wan_event "$2" "$3" ;;
    firewall_restart) do_firewall_restart ;;
    download_geo)   download_all_geo ;;
    *)              echo "Usage: $0 {start|stop|restart|status|update_geo|update_ipset|download_geo|install_page|uninstall}" ;;
esac
