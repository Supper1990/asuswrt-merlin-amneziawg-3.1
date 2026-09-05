#!/bin/sh
# Runtime helpers, sourced after the backend's function definitions.
OP_FILE=/www/user/awg_operation.htm

operation_write(){
    case "$1" in ''|*[!0-9]*) return 1;; esac
    local dest="${OP_FILE%.htm}_$1.htm"
    # Keep bounded receipts; more than fifty completed actions need not persist.
    ls -t "${OP_FILE%.htm}_"*.htm 2>/dev/null | tail -n +51 | while IFS= read -r old; do rm -f "$old"; done
    local tmp="$dest.$$"
    { printf '{"id":"%s","state":' "$1"; printf '%s' "$2" | json_string
      printf ',"message":'; printf '%s' "$3" | json_string
      printf ',"time":%s}\n' "$(date +%s)"; } > "$tmp" && mv "$tmp" "$dest"
}

validate_runtime_settings(){
    local v item file line dev name policy mac seen=" "
    v=$(get_setting awg_default_policy)
    case "$v" in ''|direct|vpn_all|vpn_geo) ;; *) log_msg 'ERROR: invalid default policy'; return 1;; esac
    v=$(get_setting awg_address)
    case "$v" in */*) ;; *) log_msg 'ERROR: IPv4 address/prefix required'; return 1;; esac
    valid_ipv4 "${v%/*}" || return 1
    case "${v##*/}" in ''|*[!0-9]*) return 1;; esac
    [ "${v##*/}" -le 32 ] || return 1
    for item in $(get_setting awg_dns | tr ',' ' '); do valid_ipv4 "$item" || { log_msg 'ERROR: invalid DNS IPv4'; return 1; }; done
    for item in $(get_setting awg_geo_custom_domains | tr ',' ' '); do valid_domain "$item" || { log_msg 'ERROR: invalid custom domain'; return 1; }; done
    for item in $(get_setting awg_geo_v2fly | tr '[:upper:]' '[:lower:]' | tr ',' ' '); do
        valid_geosite_name "$item" || { log_msg 'ERROR: unsupported GeoSite category syntax'; return 1; }
    done
    for item in $(get_setting awg_geo_v2fly_ip | tr '[:upper:]' '[:lower:]' | tr ',' ' '); do
        valid_geo_service_name "$item" || return 1
    done
    for item in $(get_setting awg_vpn_source_nets | tr ',' ' '); do
        case "$item" in */*) ;; *) return 1;; esac
        valid_ipv4 "${item%/*}" || return 1
        case "${item##*/}" in ''|*[!0-9]*) return 1;; esac
        [ "${item##*/}" -le 32 ] || return 1
    done
    file=$(mktemp /tmp/awg_clients_check.XXXXXX) || return 1
    get_setting awg_clients | tr ';' '\n' > "$file"
    while IFS=',' read -r dev name policy mac || [ -n "$dev" ]; do
        [ -z "$dev" ] && continue
        valid_ipv4 "$dev" || { rm -f "$file"; log_msg "ERROR: invalid device IP"; return 1; }
        case "$seen" in *" $dev "*) rm -f "$file"; log_msg 'ERROR: duplicate device IP'; return 1;; esac
        seen="$seen$dev "
        case "$policy" in direct|vpn_all|vpn_geo) ;; *) rm -f "$file"; return 1;; esac
        if [ -n "$mac" ]; then
            printf '%s\n' "$mac" | grep -qE '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$' || { rm -f "$file"; return 1; }
        fi
    done < "$file"
    rm -f "$file"
}

preflight_geo(){
    local svc f custom
    for svc in $(selected_geoip_services); do
        f="$GEO_DIR/geoip/v2fly_${svc}.cidr"
        [ -s "$f" ] || { log_msg "ERROR: missing GeoIP list $svc"; return 1; }
    done
    for f in "$GEO_DIR"/geoip/*.cidr; do
        [ -f "$f" ] || continue
        normalize_cidrs "$f" "$f.checked" || { log_msg "ERROR: invalid GeoIP cache $f"; return 1; }
        mv "$f.checked" "$f" || return 1
    done
    custom=$(get_setting awg_geo_custom_ips)
    if [ -n "$custom" ]; then
        printf '%s\n' "$custom" | tr ',' '\n' > "$GEO_DIR/custom.check"
        normalize_cidrs "$GEO_DIR/custom.check" "$GEO_DIR/custom.valid" || return 1
        rm -f "$GEO_DIR/custom.check" "$GEO_DIR/custom.valid"
    fi
    for svc in $(get_setting awg_geo_v2fly | tr '[:upper:]' '[:lower:]' | tr ',' ' '); do
        awk -v cat="${svc%@*}" '/^[[:space:]]*- name:/{n=$0;sub(/.*name:[[:space:]]*/,"",n);gsub(/"/,"",n);if(n==cat)found=1}END{exit !found}' "$GEO_DIR/v2fly_all.yml" || { log_msg "ERROR: unknown GeoSite category $svc"; return 1; }
    done
}

# Some Merlin BusyBox shells omit the `command` builtin. Resolve the external
# programs before defining same-name wrappers; never recurse into a wrapper.
find_external_program(){
    local name="$1" remaining="$PATH" dir
    case "$name" in ''|*/*) return 1;; esac
    while :; do
        dir=${remaining%%:*}
        [ -n "$dir" ] || dir=.
        case "$dir" in /*) ;; *) dir="$PWD/$dir";; esac
        if [ -f "$dir/$name" ] && [ -x "$dir/$name" ]; then
            printf '%s\n' "$dir/$name"
            return 0
        fi
        case "$remaining" in *:*) remaining=${remaining#*:};; *) break;; esac
    done
    return 1
}

setup_firewall(){
    validate_runtime_settings || return 1
    cancel_prefill || return 1
    local txn original_geo had_set=0 rc awg_ip_exec awg_iptables_exec
    awg_ip_exec=$(find_external_program ip) || { log_msg 'ERROR: ip executable not found'; return 1; }
    awg_iptables_exec=$(find_external_program iptables) || { log_msg 'ERROR: iptables executable not found'; return 1; }
    txn=$(mktemp -d /tmp/awg_apply.XXXXXX) || return 1
    original_geo="$GEO_DIR"
    mkdir -p "$txn/geo/geoip" "$txn/geo/domains"
    cp -a "$GEO_DIR/." "$txn/geo/" || { rm -rf "$txn"; return 1; }
    if ! ( GEO_DIR="$txn/geo"; prune_unselected_geoip_lists "$(selected_geoip_services)"; preflight_geo ); then
        log_msg 'ERROR: list validation failed; active rules retained'
        rm -rf "$txn"; return 1
    fi
    # Save the previous runtime before executing any destructive operation.
    iptables-save > "$txn/firewall" || { rm -rf "$txn"; return 1; }
    ip route show table "$RT_TABLE" > "$txn/routes" || { rm -rf "$txn"; return 1; }
    ip rule show | awk '$0 ~ /lookup 300/ || $0 ~ /fwmark 0x101/ {print}' > "$txn/rules"
    if ipset list "$IPSET_NAME" -t >/dev/null 2>&1; then
        ipset save "$IPSET_NAME" > "$txn/ipset" || { rm -rf "$txn"; return 1; }
        had_set=1
    fi
    [ ! -f "$DNSMASQ_AWG_CONF" ] || cp "$DNSMASQ_AWG_CONF" "$txn/dns"
    [ ! -f "$DNSMASQ_INCLUDE" ] || cp "$DNSMASQ_INCLUDE" "$txn/include"
    [ ! -f "$FIREWALL_EXPECTED" ] || cp "$FIREWALL_EXPECTED" "$txn/expected"
    [ ! -f "$IPSET_MIN_COUNT_FILE" ] || cp "$IPSET_MIN_COUNT_FILE" "$txn/min"
    (
        GEO_DIR="$txn/geo"
        # Expected absence checks/deletions may fail; creation of required
        # rules, addresses and routes must not be converted into success.
        iptables(){
            local code
            "$awg_iptables_exec" "$@"; code=$?
            case " $* " in *' -A '*|*' -I '*) [ "$code" = 0 ] || { log_msg "ERROR: iptables rule failed (exit $code): $*"; exit 42; };; esac
            return "$code"
        }
        ip(){
            local code
            "$awg_ip_exec" "$@"; code=$?
            case "$1 $2" in 'rule add'|'route replace') [ "$code" = 0 ] || { log_msg "ERROR: ip operation failed (exit $code): $*"; exit 42; };; esac
            return "$code"
        }
        setup_firewall_body || { log_msg 'ERROR: firewall setup did not complete'; exit 1; }
        main_firewall_base_healthy || { log_msg 'ERROR: firewall verification did not pass'; exit 1; }
    )
    rc=$?
    if [ "$rc" != 0 ]; then
        log_msg 'ERROR: apply failed; restoring previous runtime'
        cleanup_firewall
        if [ "$had_set" = 1 ]; then ipset restore -exist < "$txn/ipset" || rc=2; fi
        restore_owned_rules "$txn/firewall" || rc=2
        ip route flush table "$RT_TABLE"
        while IFS= read -r line; do [ -z "$line" ] || ip route replace table "$RT_TABLE" $line || rc=2; done < "$txn/routes"
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            pref=${line%%:*}; rest=${line#*:}
            ip rule add priority "$pref" $rest || rc=2
        done < "$txn/rules"
        if [ -f "$txn/dns" ]; then cp "$txn/dns" "$DNSMASQ_AWG_CONF"; else rm -f "$DNSMASQ_AWG_CONF"; fi
        if [ -f "$txn/include" ]; then cp "$txn/include" "$DNSMASQ_INCLUDE"; else rm -f "$DNSMASQ_INCLUDE"; fi
        [ ! -f "$txn/expected" ] || cp "$txn/expected" "$FIREWALL_EXPECTED"
        [ ! -f "$txn/min" ] || cp "$txn/min" "$IPSET_MIN_COUNT_FILE"
        restart_dnsmasq_and_wait 15 || rc=2
        [ "$rc" != 2 ] || log_msg 'ERROR: rollback incomplete; manual recovery required'
        rm -rf "$txn"; return 1
    fi
    prune_unselected_geoip_lists "$(selected_geoip_services)"
    rm -f "$original_geo/domains/v2fly_"*.txt "$original_geo/domains/custom.txt"
    cp -a "$txn/geo/." "$original_geo/" || { log_msg 'ERROR: cannot commit geo cache'; rm -rf "$txn"; return 1; }
    rm -rf "$txn"
    # Store exact static members, rather than a floor that hides partial loss.
    ipset save "$IPSET_NAME" | awk '$1=="add" && /timeout 0([ ]|$)/{v=$3;if(index(v,"/")==0)v=v"/32";print v}' | sort -u > /tmp/.awg_static_members
    cp "$DNSMASQ_AWG_CONF" /tmp/.awg_dns_expected || return 1
    repair_aux_routing || return 1
    ensure_status_loop
    pre_resolve_domains_async
}

pre_resolve_domains_async(){
    # A pending generation is consumed by one independent worker. An old
    # background process never prevents subsequent generations from running.
    touch /tmp/.awg_dns_pending
    "$ADDON_DIR/amneziawg.sh" prefill_worker </dev/null >/dev/null 2>&1 &
}

prefill_worker(){
    local old domain n=0 ok=0 failed=0 domains
    if ! mkdir "$DNS_PREFILL_LOCK" 2>/dev/null; then
        old=$(cat "$DNS_PREFILL_LOCK/pid" 2>/dev/null)
        if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then return 0; fi
        # Empty lock may be in the process of being initialized.
        if [ -z "$old" ]; then
            sleep 2
            old=$(cat "$DNS_PREFILL_LOCK/pid" 2>/dev/null)
            [ -z "$old" ] || return 0
        fi
        rm -rf "$DNS_PREFILL_LOCK"
        mkdir "$DNS_PREFILL_LOCK" || return 1
    fi
    echo $$ > "$DNS_PREFILL_LOCK/pid"
    trap 'rm -rf "$DNS_PREFILL_LOCK"' 0
    trap 'exit 1' 1 2 15
    while [ -f /tmp/.awg_dns_pending ]; do
        rm -f /tmp/.awg_dns_pending
        [ -s "$DNSMASQ_AWG_CONF" ] || continue
        domains="$DNS_PREFILL_LOCK/domains"
        awk -F/ '/^ipset=/{for(i=2;i<NF;i++)if($i!="")print $i}' "$DNSMASQ_AWG_CONF" | sort -u > "$domains"
        ok=0; failed=0
        log_msg 'Domain pre-resolution started'
        while IFS= read -r domain; do
            [ -n "$domain" ] || continue
            if timeout 8 nslookup "$domain" 127.0.0.1 >/dev/null 2>&1; then ok=$((ok+1)); else failed=$((failed+1)); fi
        done < "$domains"
        log_msg "Domain pre-resolution finished: success=$ok failed=$failed"
        update_status
    done
}

ensure_status_loop(){
    local pid
    pid=$(cat /tmp/.awg_status_pid 2>/dev/null)
    [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null || return 0
    "$ADDON_DIR/amneziawg.sh" status_loop </dev/null >/dev/null 2>&1 &
}
status_loop(){
    mkdir /tmp/.awg_status_lock 2>/dev/null || {
        local old
        old=$(cat /tmp/.awg_status_pid 2>/dev/null)
        [ -n "$old" ] && kill -0 "$old" 2>/dev/null && return 0
        rmdir /tmp/.awg_status_lock 2>/dev/null
        mkdir /tmp/.awg_status_lock 2>/dev/null || return 1
    }
    echo $$ > /tmp/.awg_status_pid
    trap 'rm -f /tmp/.awg_status_pid; rmdir /tmp/.awg_status_lock 2>/dev/null' 0
    trap 'exit 1' 1 2 15
    while [ -x "$ADDON_DIR/amneziawg.sh" ]; do
        "$ADDON_DIR/amneziawg.sh" status
        if [ -f /tmp/.awg_dns_pending ]; then
            "$ADDON_DIR/amneziawg.sh" prefill_worker </dev/null >/dev/null 2>&1 &
        fi
        sleep 5
    done
}

update_status(){
    local tmp="$STATUS_FILE.$$" running=false addr="" pub="" port="" dump row handshake=0 now state=stopped count=0 domains=0 af_count=0 af_enabled=false af_active=false version warnings=0
    now=$(date +%s)
    if is_running && pidof amneziawg-go >/dev/null 2>&1; then
        running=true; state=interface_up
        addr=$(ip -4 addr show "$IFACE" | awk '/inet /{print $2;exit}')
        pub=$("$AWG_BIN" show "$IFACE" public-key 2>/dev/null)
        port=$("$AWG_BIN" show "$IFACE" listen-port 2>/dev/null)
        handshake=$("$AWG_BIN" show "$IFACE" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
        case "$handshake" in ''|*[!0-9]*) handshake=0;; esac
        [ "$handshake" -gt 0 ] && [ "$now" -ge "$handshake" ] && [ "$((now-handshake))" -le 180 ] && state=handshake_recent
    fi
    count=$(ipset list "$IPSET_NAME" -t 2>/dev/null | awk '/Number of entries/{print $NF}')
    af_count=$(ipset list MYAWG -t 2>/dev/null | awk '/Number of entries/{print $NF}')
    domains=$(awk -F/ '/^ipset=/{for(i=2;i<NF;i++)print $i}' "$DNSMASQ_AWG_CONF" 2>/dev/null | sort -u | wc -l)
    antifilter_enabled && af_enabled=true
    if [ "$af_enabled" = true ] && [ "${af_count:-0}" -gt 0 ] && iptables -t nat -C POSTROUTING -m mark --mark 0x66/0xffffffff -o awg0 -j MASQUERADE 2>/dev/null && ip route show table 400 | grep -q '^default dev awg0' && iptables -t mangle -C PREROUTING -j MYAWG_CHAIN 2>/dev/null; then af_active=true; fi
    [ ! -f "$GEO_DIR/domains/warnings.txt" ] || warnings=$(wc -l < "$GEO_DIR/domains/warnings.txt")
    version=$(/opt/bin/opkg status amneziawg 2>/dev/null | awk '/^Version:/{print $2;exit}')
    {
        printf '{"running":%s,"state":"%s","measured_at":%s,"handshake_timestamp":%s,' "$running" "$state" "$now" "$handshake"
        printf '"package_version":'; printf '%s' "$version" | json_string
        printf ',"interface_addr":'; printf '%s' "$addr" | json_string
        printf ',"public_key":'; printf '%s' "$pub" | json_string
        printf ',"listen_port":'; printf '%s' "$port" | json_string
        printf ',"go_version":'; cat "$AWG_DIR/amneziawg-go.version" 2>/dev/null | json_string
        printf ',"tools_version":'; cat "$AWG_DIR/amneziawg-tools.version" 2>/dev/null | json_string
        printf ',"default_policy":'; get_setting awg_default_policy | json_string
        printf ',"clients":'; get_setting awg_clients | json_string
        printf ',"ipset_count":%s,"geo_domains":%s,"geo_warnings":%s,"antifilter_count":%s,"antifilter_enabled":%s,"antifilter_active":%s,' "${count:-0}" "${domains:-0}" "$warnings" "${af_count:-0}" "$af_enabled" "$af_active"
        printf '"active_rules":%s,"geo_downloaded":' "$(ip rule show | grep -c 'lookup 300')"
        if geo_available; then printf true; else printf false; fi
        printf ',"peers":['
        "$AWG_BIN" show "$IFACE" dump 2>/dev/null | tail -n +2 | while read -r pkey psk endpoint aips hs rx tx keepalive; do
            [ -n "$pkey" ] || continue
            printf '{"endpoint":'; printf '%s' "$endpoint" | json_string
            printf ',"allowed_ips":'; printf '%s' "$aips" | json_string
            printf ',"transfer_rx":'; human_size "${rx:-0}" | json_string
            printf ',"transfer_tx":'; human_size "${tx:-0}" | json_string
            printf ',"latest_handshake":'; if [ "${hs:-0}" = 0 ]; then printf never; else printf '%ss ago' "$((now-hs))"; fi | json_string
            printf '}'
            break # one peer is supported by this addon
        done
        printf '],"log":'; grep amneziawg /tmp/syslog.log 2>/dev/null | tail -30 | json_string
        printf '}\n'
    } > "$tmp" && mv "$tmp" "$STATUS_FILE"
}

fetch_verified_package(){
    local ver="$1" arch="$2" dir="$3" package base expected actual
    case "$ver" in ''|*[!0-9.-]*) return 1;; esac
    case "$arch" in aarch64-3.10|armv7-2.6|armv7-3.2) ;; *) return 1;; esac
    package="amneziawg_${ver}_${arch}.ipk"
    base="https://github.com/${UPDATE_REPO}/releases/download/v${ver}"
    curl -fLsS --connect-timeout 10 --max-time 180 "$base/$package" -o "$dir/$package" || return 1
    curl -fLsS --connect-timeout 10 --max-time 30 "$base/SHA256SUMS" -o "$dir/sums-$ver" || return 1
    expected=$(awk -v f="$package" '$2==f || $2=="*"f {print $1;exit}' "$dir/sums-$ver")
    actual=$(sha256sum "$dir/$package" | awk '{print $1}')
    [ -n "$expected" ] && [ "$expected" = "$actual" ] || return 1
    tar tzf "$dir/$package" | grep -q 'data.tar.gz' || return 1
}

do_update(){
    (
        local current latest arch dir old_package new_package was_running=0 rc
        LOCKDIR=/tmp/.awg_package_lock
        DISPATCH_LOCK=0
        acquire_lock || exit 1
        # Drain an already running Apply/watchdog before replacing scripts.
        package_lock="$LOCKDIR"
        LOCKDIR=/tmp/.awg_lock
        if ! acquire_lock; then LOCKDIR="$package_lock"; release_lock; exit 1; fi
        release_lock
        LOCKDIR=/tmp/.awg_ipset_update_lock
        if ! acquire_lock; then LOCKDIR="$package_lock"; release_lock; exit 1; fi
        release_lock
        LOCKDIR="$package_lock"
        dir=$(mktemp -d /tmp/awg_package.XXXXXX) || { release_lock; exit 1; }
        trap 'rm -rf "$dir"; rm -f /tmp/.awg_no_autostart; release_lock' 0
        trap 'exit 1' 1 2 15
        current=$(/opt/bin/opkg status amneziawg | awk '/^Version:/{print $2;exit}')
        arch=$(/opt/bin/opkg status amneziawg | awk '/^Architecture:/{print $2;exit}')
        [ -n "$arch" ] || arch=$(/opt/bin/opkg print-architecture | awk '$2=="aarch64-3.10"{print $2;exit}')
        latest=$(curl -fLsS --connect-timeout 10 --max-time 30 "https://api.github.com/repos/${UPDATE_REPO}/releases/latest" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\([0-9.-]*\)".*/\1/p' | head -1)
        [ -n "$latest" ] || exit 1
        [ "$current" != "$latest" ] || { log_msg 'Package already up to date'; exit 0; }
        # Download and verify BOTH versions before stopping anything.
        fetch_verified_package "$latest" "$arch" "$dir" || { log_msg 'ERROR: new package validation failed'; exit 1; }
        fetch_verified_package "$current" "$arch" "$dir" || { log_msg 'ERROR: rollback package unavailable; update cancelled'; exit 1; }
        old_package="$dir/amneziawg_${current}_${arch}.ipk"
        new_package="$dir/amneziawg_${latest}_${arch}.ipk"
        cp "$SETTINGS" "$dir/settings" || exit 1
        is_running && was_running=1
        # Child hooks invoked by opkg are allowed; unrelated user mutations
        # see the package lock and fail with an explicit busy result.
        export AWG_PACKAGE_CHILD=1
        "$ADDON_DIR/amneziawg.sh" stop || exit 1
        touch /tmp/.awg_no_autostart
        rc=0
        /opt/bin/opkg install "$new_package" || rc=1
        [ "$rc" != 0 ] || "$ADDON_DIR/amneziawg.sh" install_page || rc=1
        [ "$(/opt/bin/opkg status amneziawg | awk '/^Version:/{print $2;exit}')" = "$latest" ] || rc=1
        if [ "$rc" = 0 ]; then
            log_msg "Update complete: $latest; start from UI"
            "$ADDON_DIR/amneziawg.sh" status
            exit 0
        fi
        log_msg 'ERROR: package installation failed; restoring previous package'
        if /opt/bin/opkg install --force-downgrade "$old_package" && cp "$dir/settings" "$SETTINGS" && "$ADDON_DIR/amneziawg.sh" install_page; then
            rm -f /tmp/.awg_no_autostart
            [ "$was_running" != 1 ] || "$ADDON_DIR/amneziawg.sh" start
            log_msg "Previous package restored: $current"
        else
            # Preserve the recovery bundle if automatic rollback failed.
            cp -a "$dir" "/opt/awg-recovery-$(date +%s)"
            log_msg 'ERROR: rollback failed; recovery files retained under /opt/awg-recovery-*'
        fi
        exit 1
    )
}

# Exact managed-rule ordering and static membership are checked independently
# of dynamic DNS entries, whose normal expiry must not trigger a rebuild.
main_firewall_healthy(){
    main_firewall_base_healthy || return 1
    [ "$(managed_firewall_rules)" = "$(cat "$FIREWALL_EXPECTED")" ] || return 1
    [ -f /tmp/.awg_static_members ] || return 1
    local actual missing
    actual=$(mktemp /tmp/awg_members.XXXXXX) || return 1
    set_members "$IPSET_NAME" > "$actual" || { rm -f "$actual"; return 1; }
    missing=$(awk 'FILENAME==ARGV[1]{have[$0]=1;next}!($0 in have){bad=1}END{print bad+0}' "$actual" /tmp/.awg_static_members)
    rm -f "$actual"
    [ "$missing" = 0 ] || return 1
    cmp -s /tmp/.awg_dns_expected "$DNSMASQ_AWG_CONF" || return 1
    if grep -q '^ipset=' "$DNSMASQ_AWG_CONF"; then
        grep -qFx "conf-file=$DNSMASQ_AWG_CONF" "$DNSMASQ_INCLUDE" || return 1
    fi
}

package_busy(){
    [ -d /tmp/.awg_package_lock ] || return 1
    local owner
    owner=$(cat /tmp/.awg_package_lock/pid 2>/dev/null)
    case "$owner" in '')
        sleep 2
        [ -s /tmp/.awg_package_lock/pid ] && return 0
        rmdir /tmp/.awg_package_lock 2>/dev/null || return 0
        return 1;;
        *[!0-9]*) return 0;;
    esac
    if kill -0 "$owner" 2>/dev/null; then return 0; fi
    rm -rf /tmp/.awg_package_lock
    return 1
}

ensure_base_firewall(){
    local lan
    lan=$(get_lan_net)
    iptables -C INPUT -i "$IFACE" -j ACCEPT 2>/dev/null || iptables -I INPUT -i "$IFACE" -j ACCEPT || return 1
    iptables -C FORWARD -i "$IFACE" -j ACCEPT 2>/dev/null || iptables -I FORWARD -i "$IFACE" -j ACCEPT || return 1
    iptables -C FORWARD -o "$IFACE" -j ACCEPT 2>/dev/null || iptables -I FORWARD -o "$IFACE" -j ACCEPT || return 1
    iptables -t mangle -C FORWARD -o "$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -o "$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || return 1
    iptables -t mangle -C FORWARD -i "$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -i "$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu || return 1
    if [ -n "$lan" ]; then
        iptables -t nat -C POSTROUTING -s "$lan" -o "$IFACE" -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING -s "$lan" -o "$IFACE" -j MASQUERADE || return 1
    else
        iptables -t nat -C POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING -o "$IFACE" -j MASQUERADE || return 1
    fi
}

# Restore addon-owned chain and DNS rules without overwriting other addons'
# tables or concurrent AntiFilter changes. cleanup_firewall has removed ours.
restore_owned_rules(){
    local snapshot="$1" table rules
    rules=$(mktemp /tmp/awg_rules_restore.XXXXXX) || return 1
    for table in mangle nat filter; do
        {
            printf '*%s\n' "$table"
            if [ "$table" = mangle ] && grep -q '^:AWG ' "$snapshot"; then
                printf ':AWG - [0:0]\n'
            fi
            awk -v wanted="$table" '
                /^\*/{table=substr($0,2);delete index_by_chain;next}
                table!=wanted{next}
                /^-A /{
                    chain=$2; index_by_chain[chain]++
                    own=(wanted=="mangle" && ($2=="AWG" || ($2=="PREROUTING" && /-j AWG$/))) ||
                        (wanted=="nat" && $2=="PREROUTING" && /-i br0 / && /--dport 53 / && /-j DNAT/) ||
                        (wanted=="filter" && $2=="FORWARD" && /-i br0 / && /--dport (443|853) / && /-j REJECT/)
                    if(own){
                        if(chain=="AWG")print
                        else {sub(/^-A [^ ]+ /, "");print "-I " chain " " index_by_chain[chain] " " $0}
                    }
                }' "$snapshot"
            printf 'COMMIT\n'
        } > "$rules"
        iptables-restore --noflush < "$rules" || { rm -f "$rules"; return 1; }
    done
    rm -f "$rules"
}

cancel_prefill(){
    local pid n=0
    rm -f /tmp/.awg_dns_pending
    pid=$(cat "$DNS_PREFILL_LOCK/pid" 2>/dev/null)
    case "$pid" in ''|*[!0-9]*) return 0;; esac
    kill -0 "$pid" 2>/dev/null || return 0
    # Verify ownership before signalling a PID retained across an interrupted run.
    tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q 'amneziawg.sh prefill_worker' || return 0
    kill "$pid" 2>/dev/null
    while kill -0 "$pid" 2>/dev/null; do
        [ "$n" -lt 10 ] || { log_msg 'ERROR: DNS worker did not stop; Apply deferred'; return 1; }
        n=$((n+1)); sleep 1
    done
}
