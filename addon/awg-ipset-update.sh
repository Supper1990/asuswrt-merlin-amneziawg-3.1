#!/bin/sh
# Secondary selective-routing list for AmneziaWG.
# Keeps MYAWG/mark 0x66/table 400 separate from the web UI's
# awg_dst/mark 0x100/table 300.

URL="https://antifilter.download/list/allyouneed.lst"

SET="MYAWG"
TMP_SET="MYAWG_tmp"
CHAIN="MYAWG_CHAIN"
IFACE="awg0"

TABLE="400"
MARK="0x66"
PRIO="10"

# Incoming VPN clients that may override an existing firmware/service mark.
VPN_SRC_NETS="10.8.0.0/24 10.10.10.0/24"

BASE="/jffs/addons/awg-ipset"
TMP="/tmp/allyouneed.lst"
HDR="/tmp/allyouneed.headers"
CURL_CONF="/tmp/allyouneed.curl.conf"
RESTORE="/tmp/myawg_ipset.restore"
LOG="/tmp/awg-ipset-update.log"
LOCKDIR="/tmp/.awg_ipset_update_lock"

ETAG_FILE="$BASE/etag"
LM_FILE="$BASE/last_modified"
HASH_FILE="$BASE/hash"
OLD_LIST="$BASE/current.lst"
NEW_LIST="$BASE/new.lst"

HASH_SIZE="262144"
MAX_ELEM="2000000"
MIN_NETS="1000"

PATH="/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

mkdir -p "$BASE"

log(){
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
    logger -t amneziawg-antifilter "$*" 2>/dev/null
}

ipset_count(){
    ipset list "$SET" 2>/dev/null | awk '/Number of entries:/ {print $4}'
}

add_rule_once(){
    table="$1"
    chain="$2"
    shift 2
    iptables -t "$table" -C "$chain" "$@" 2>/dev/null || \
        iptables -t "$table" -A "$chain" "$@"
}

delete_rule_all(){
    table="$1"
    chain="$2"
    shift 2
    count=0
    while [ "$count" -lt 100 ] && iptables -t "$table" -C "$chain" "$@" 2>/dev/null; do
        iptables -t "$table" -D "$chain" "$@" 2>/dev/null || break
        count=$((count + 1))
    done
}

get_lan_net(){
    ip -4 route show dev br0 2>/dev/null | awk '$1 ~ /^[0-9]/ && $1 ~ /\// {print $1; exit}'
}

get_endpoint_ip(){
    endpoint=$(/opt/amneziawg/awg show "$IFACE" endpoints 2>/dev/null | awk 'NR==1 {print $2}')
    endpoint=${endpoint%:*}
    case "$endpoint" in
        *[!0-9.]*|"") return 1 ;;
        *) echo "$endpoint" ;;
    esac
}

routing_is_active(){
    ip rule show 2>/dev/null | grep -q "fwmark $MARK.*lookup $TABLE" || return 1
    ip route show table "$TABLE" 2>/dev/null | grep -q "^default dev $IFACE" || return 1
    iptables -t mangle -C PREROUTING -j "$CHAIN" 2>/dev/null || return 1
    iptables -t mangle -C OUTPUT -j "$CHAIN" 2>/dev/null || return 1
    iptables -t nat -C POSTROUTING \
        -m mark --mark "$MARK"/0xffffffff -o "$IFACE" -j MASQUERADE 2>/dev/null
}

attach_chain_after_awg(){
    base_chain="$1"

    awg_line=$(iptables -t mangle -L "$base_chain" --line-numbers 2>/dev/null | \
        awk '$2=="AWG" {n=$1} END {print n}')
    myawg_line=$(iptables -t mangle -L "$base_chain" --line-numbers 2>/dev/null | \
        awk -v chain="$CHAIN" '$2==chain {n=$1} END {print n}')

    if [ -n "$awg_line" ] && [ "$myawg_line" = "$((awg_line + 1))" ]; then
        return 0
    fi
    if [ -z "$awg_line" ] && [ -n "$myawg_line" ]; then
        return 0
    fi

    # Firmware/addon firewall rebuilds can change ordering, so reposition only
    # when needed. The UI-managed AWG chain must remain immediately before us.
    delete_rule_all mangle "$base_chain" -j "$CHAIN"
    if [ -n "$awg_line" ]; then
        iptables -t mangle -I "$base_chain" $((awg_line + 1)) -j "$CHAIN"
    else
        iptables -t mangle -A "$base_chain" -j "$CHAIN"
    fi
}

ensure_routing(){
    antifilter_allowed || { disable_routing; return 1; }
    ip link show "$IFACE" >/dev/null 2>&1 || {
        log "ERROR: interface $IFACE not found"
        return 1
    }

    ipset create "$SET" hash:net family inet hashsize "$HASH_SIZE" maxelem "$MAX_ELEM" -exist

    if ! ip rule show 2>/dev/null | grep -q "fwmark $MARK.*lookup $TABLE"; then
        ip rule add fwmark "$MARK" table "$TABLE" priority "$PRIO"
    fi
    ip route replace default dev "$IFACE" table "$TABLE"
    ip route flush cache 2>/dev/null

    iptables -t mangle -N "$CHAIN" 2>/dev/null
    # Explicit Direct devices must bypass AntiFilter, including VPN clients.
    if ! iptables -t mangle -C "$CHAIN" -m mark --mark 0x101/0xffffffff -j RETURN 2>/dev/null; then
        iptables -t mangle -I "$CHAIN" 1 -m mark --mark 0x101/0xffffffff -j RETURN
    fi

    lan_net=$(get_lan_net)
    endpoint_ip=$(get_endpoint_ip 2>/dev/null)

    add_rule_once mangle "$CHAIN" -m addrtype --dst-type LOCAL -j RETURN
    [ -n "$lan_net" ] && add_rule_once mangle "$CHAIN" -d "$lan_net" -j RETURN
    add_rule_once mangle "$CHAIN" -p udp -m multiport --dports 67,68,123 -j RETURN
    add_rule_once mangle "$CHAIN" -d 224.0.0.0/4 -j RETURN
    [ -n "$endpoint_ip" ] && add_rule_once mangle "$CHAIN" -d "$endpoint_ip"/32 -j RETURN

    # These source-specific rules intentionally precede the mark guards.
    for vpn_net in $VPN_SRC_NETS; do
        add_rule_once mangle "$CHAIN" -s "$vpn_net" \
            -m set --match-set "$SET" dst -j MARK --set-mark "$MARK"
    done

    # Preserve the UI-managed mark and all other non-zero service marks.
    add_rule_once mangle "$CHAIN" -m mark --mark 0x100/0xffffffff -j RETURN
    add_rule_once mangle "$CHAIN" -m mark ! --mark 0x0/0xffffffff -j RETURN
    add_rule_once mangle "$CHAIN" -m set --match-set "$SET" dst -j MARK --set-mark "$MARK"

    attach_chain_after_awg PREROUTING
    attach_chain_after_awg OUTPUT

    add_rule_once nat POSTROUTING \
        -m mark --mark "$MARK"/0xffffffff -o "$IFACE" -j MASQUERADE
}

disable_routing(){
    was_active=false
    if routing_is_active || ipset list "$SET" >/dev/null 2>&1; then
        was_active=true
    fi

    delete_rule_all mangle PREROUTING -j "$CHAIN"
    delete_rule_all mangle OUTPUT -j "$CHAIN"
    iptables -t mangle -F "$CHAIN" 2>/dev/null
    iptables -t mangle -X "$CHAIN" 2>/dev/null
    delete_rule_all nat POSTROUTING \
        -m mark --mark "$MARK"/0xffffffff -o "$IFACE" -j MASQUERADE

    count=0
    while [ "$count" -lt 100 ] && ip rule del fwmark "$MARK" table "$TABLE" 2>/dev/null; do
        count=$((count + 1))
    done
    ip route flush table "$TABLE" 2>/dev/null
    ip route flush cache 2>/dev/null
    ipset destroy "$TMP_SET" 2>/dev/null
    ipset destroy "$SET" 2>/dev/null
    [ "$was_active" = true ] && log "AntiFilter disabled"
}

full_rebuild_from_new_list(){
    [ -s "$NEW_LIST" ] || { log "ERROR: new list is empty"; return 1; }
    log "Full rebuild started"
    {
        echo "create $TMP_SET hash:net family inet hashsize $HASH_SIZE maxelem $MAX_ELEM -exist"
        echo "flush $TMP_SET"
        while IFS= read -r net; do
            [ -n "$net" ] && echo "add $TMP_SET $net -exist"
        done < "$NEW_LIST"
    } > "$RESTORE"

    if ! ipset restore < "$RESTORE" 2>>"$LOG"; then
        log "ERROR: ipset restore failed"
        ipset destroy "$TMP_SET" 2>/dev/null
        return 1
    fi
    if ! ipset swap "$TMP_SET" "$SET"; then
        log "ERROR: ipset swap failed; cache unchanged"
        return 1
    fi
    ipset destroy "$TMP_SET" 2>/dev/null
    if ! cp "$NEW_LIST" "$OLD_LIST.tmp" || ! mv "$OLD_LIST.tmp" "$OLD_LIST"; then
        log "ERROR: cannot commit AntiFilter cache"
        return 1
    fi
    log "Full rebuild done"
}

restore_from_cache_if_needed(){
    count=$(ipset_count)
    [ -n "$count" ] || count=0
    [ "$count" -ge "$MIN_NETS" ] 2>/dev/null && return 0
    [ -s "$OLD_LIST" ] || { log "ipset empty and no cached list"; return 1; }
    log "Restoring depleted ipset from cache (entries: $count)"
    cp "$OLD_LIST" "$NEW_LIST"
    full_rebuild_from_new_list
}

repair_runtime(){
    was_active=false
    routing_is_active && was_active=true
    ipset create "$SET" hash:net family inet hashsize "$HASH_SIZE" maxelem "$MAX_ELEM" -exist
    if ! restore_from_cache_if_needed; then
        log "No usable cached list; downloading AntiFilter"
        update_list
        return $?
    fi
    ensure_routing || return 1
    if [ "$was_active" != true ]; then
        log "AntiFilter enabled; routing active with $(ipset_count) entries"
    fi
}

update_list(){
    log "===== UPDATE START ====="
    ip link show "$IFACE" >/dev/null 2>&1 || {
        log "ERROR: interface $IFACE not found"
        return 1
    }
    ipset create "$SET" hash:net family inet hashsize "$HASH_SIZE" maxelem "$MAX_ELEM" -exist
    # A reboot recreates an empty ipset. Populate it before applying a small
    # incremental diff, otherwise unchanged cached entries would be missing.
    restore_from_cache_if_needed || true
    rm -f "$TMP" "$HDR" "$CURL_CONF"

    {
        echo "ipv4"
        echo "fail"
        echo "location"
        echo "show-error"
        echo "connect-timeout = 15"
        echo "max-time = 60"
        echo "retry-max-time = 180"
        echo "retry = 3"
        echo "dump-header = \"$HDR\""
        echo "output = \"$TMP\""
        if [ -s "$ETAG_FILE" ]; then
            etag=$(head -n 1 "$ETAG_FILE" | tr -d '\r')
            [ -n "$etag" ] && echo "header = \"If-None-Match: $etag\""
        fi
        if [ -s "$LM_FILE" ]; then
            modified=$(head -n 1 "$LM_FILE" | tr -d '\r')
            [ -n "$modified" ] && echo "header = \"If-Modified-Since: $modified\""
        fi
    } > "$CURL_CONF"

    http_code=$(curl -K "$CURL_CONF" -w "%{http_code}" "$URL" 2>>"$LOG")
    if [ "$http_code" = "304" ]; then
        log "AntiFilter list not modified"
        restore_from_cache_if_needed || return 1
        ensure_routing || return 1
        log "===== UPDATE DONE ====="
        return 0
    fi
    if [ "$http_code" != "200" ] || [ ! -s "$TMP" ]; then
        log "ERROR: download failed or empty, HTTP=$http_code"
        restore_from_cache_if_needed || true
        ensure_routing
        return 1
    fi

    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$' "$TMP" | sort -u > "$NEW_LIST"
    new_count=$(wc -l < "$NEW_LIST" | tr -d ' ')
    log "Valid networks: $new_count"
    if [ "$new_count" -lt "$MIN_NETS" ]; then
        log "ERROR: too few networks, refusing update"
        restore_from_cache_if_needed || true
        ensure_routing
        return 1
    fi

    new_hash=$(md5sum "$NEW_LIST" | awk '{print $1}')
    old_hash=""
    [ -s "$HASH_FILE" ] && old_hash=$(head -n 1 "$HASH_FILE" | tr -d '\r')
    new_etag=$(grep -i '^ETag:' "$HDR" | tail -n 1 | sed 's/^[Ee][Tt][Aa][Gg]:[[:space:]]*//' | tr -d '\r')
    new_modified=$(grep -i '^Last-Modified:' "$HDR" | tail -n 1 | \
        sed 's/^[Ll][Aa][Ss][Tt]-[Mm][Oo][Dd][Ii][Ff][Ii][Ee][Dd]:[[:space:]]*//' | tr -d '\r')

    if [ "$new_hash" = "$old_hash" ]; then
        log "AntiFilter list unchanged"
        restore_from_cache_if_needed || return 1
        ensure_routing || return 1
        log "===== UPDATE DONE ====="
        return 0
    fi

    # Stage the complete changed list: failures never commit a partial live set.
    if ! full_rebuild_from_new_list; then
        log "ERROR: AntiFilter update not committed"
        return 1
    fi
    echo "$new_hash" > "$HASH_FILE.tmp" && mv "$HASH_FILE.tmp" "$HASH_FILE" || return 1
    [ -n "$new_etag" ] && printf '%s\n' "$new_etag" > "$ETAG_FILE"
    [ -n "$new_modified" ] && printf '%s\n' "$new_modified" > "$LM_FILE"

    ensure_routing || return 1
    log "AntiFilter list updated: $(ipset_count) entries"
    log "===== UPDATE DONE ====="
}

antifilter_allowed(){
    [ "$(awk '$1=="awg_antifilter_enabled" {print $2; exit}' /jffs/addons/custom_settings.txt 2>/dev/null)" != "0" ]
}

acquire_aux_lock(){
    local tries=0 old_pid
    while ! mkdir "$LOCKDIR" 2>/dev/null; do
        if [ -s "$LOCKDIR/pid" ]; then
            old_pid=$(cat "$LOCKDIR/pid")
            case "$old_pid" in
                ''|*[!0-9]*) log "ERROR: invalid lock owner"; return 1 ;;
            esac
            if ! kill -0 "$old_pid" 2>/dev/null; then
                rm -rf "$LOCKDIR"
                continue
            fi
        elif [ "$tries" -ge 2 ]; then
            rmdir "$LOCKDIR" 2>/dev/null && continue
        fi
        tries=$((tries + 1))
        [ "$tries" -ge 240 ] && { log "ERROR: AntiFilter lock timeout"; return 1; }
        sleep 1
    done
    echo $$ > "$LOCKDIR/pid"
}

acquire_aux_lock || exit 1
trap 'rm -rf "$LOCKDIR"' 0
trap 'exit 1' 1 2 15
case "${1:---update}" in
    --repair|--update)
        if ! antifilter_allowed; then
            disable_routing
            exit 0
        fi
        ;;
esac

case "${1:---update}" in
    --repair)  repair_runtime ;;
    --update)  update_list ;;
    --disable) disable_routing ;;
    --cleanup)
        disable_routing
        ipset destroy "$TMP_SET" 2>/dev/null
        ipset destroy "$SET" 2>/dev/null
        rm -rf "$BASE"
        ;;
    *)
        echo "Usage: $0 {--repair|--update|--disable|--cleanup}" >&2
        exit 2
        ;;
esac
