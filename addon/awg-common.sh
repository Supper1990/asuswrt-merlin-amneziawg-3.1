#!/bin/sh
# Shared, side-effect-free helpers. BusyBox ash compatible.
json_string(){
    LC_ALL=C awk 'BEGIN{printf "\""} {if(NR>1)printf "\\n"; for(i=1;i<=length($0);i++){c=substr($0,i,1); if(c=="\\")printf "\\\\"; else if(c=="\"")printf "\\\""; else if(c=="\t")printf "\\t"; else if(c=="\r")printf "\\r"; else if(c ~ /[[:cntrl:]]/)printf "?"; else printf "%s",c}} END{printf "\""}'
}
valid_ipv4(){
    printf '%s\n' "$1" | awk -F. 'NF!=4{exit 1} {for(i=1;i<=4;i++)if($i!~/^[0-9]+$/ || length($i)>3 || $i+0>255)exit 1}'
}
# Validate all records before producing a canonical set. Optional IPv6 exclusion
# is explicit; unknown input is an error, never silently a partial IPv4 list.
normalize_cidrs(){
    awk -v skip6="${3:-0}" '
    {gsub(/\r/,""); sub(/#.*/,""); gsub(/^[ \t]+|[ \t]+$/,""); if($0=="")next
     if(index($0,":")){if(skip6==1 && $0 ~ /^[0-9a-fA-F:.\/]+$/)next; bad=1;next}
     n=split($0,p,"/"); if(n>2 || (n==2 && (p[2]!~/^[0-9]+$/ || p[2]+0>32))){bad=1;next}
     if(split(p[1],o,".")!=4){bad=1;next}
     ok=1;for(i=1;i<=4;i++)if(o[i]!~/^[0-9]+$/ || length(o[i])>3 || o[i]+0>255)ok=0
     if(!ok){bad=1;next}
     bits=(n==1?32:p[2]+0); out=""
     for(i=1;i<=4;i++){b=bits>=8?8:bits; if(b<0)b=0; unit=2^(8-b); v=int((o[i]+0)/unit)*unit; out=out (i==1?"":".") v; bits-=8}
     print out "/" (n==1?32:p[2]+0); count++
    } END{if(bad || !count)exit 1}' "$1" > "$2.raw" || { rm -f "$2.raw"; return 1; }
    LC_ALL=C sort -u "$2.raw" > "$2" || return 1
    rm -f "$2.raw"
}
valid_domain(){
    [ -n "$1" ] && [ ${#1} -le 253 ] || return 1
    printf '%s\n' "$1" | awk -F. '{for(i=1;i<=NF;i++)if(length($i)<1 || length($i)>63 || $i!~/^[a-zA-Z0-9_-]+$/ || $i~/^-/ || $i~/-$/)exit 1}'
}
# Kernel canonical output permits exact cache/runtime comparison (no count floor).
set_members(){
    local snapshot
    snapshot=$(mktemp /tmp/awg_set.XXXXXX) || return 1
    ipset save "$1" > "$snapshot" 2>/dev/null || { rm -f "$snapshot"; return 1; }
    awk '$1=="add"{v=$3;if(index(v,"/")==0)v=v"/32";print v}' "$snapshot" | LC_ALL=C sort -u
    rm -f "$snapshot"
}

valid_geosite_name(){
    # Upstream list names and attributes can contain a literal !, for example
    # category-ai-!cn, geolocation-!cn and jd@!cn.  Keep path separators and
    # shell metacharacters outside the upstream character set rejected.
    printf '%s\n' "$1" | grep -qE '^[a-z0-9][a-z0-9._!-]*(@[a-z0-9!][a-z0-9._!-]*)?$'
}

country_policy_enabled(){
    case "$(get_setting awg_default_policy)" in vpn_non_ru|vpn_non_ru_vpn) return 0;; *) return 1;; esac
}

# Optional server selectors: exact virtual interface (or inbound XFRM policy)
# plus an explicit client pool. Never accept a raw source-only or wildcard rule.
valid_country_ingress(){
    local entry="$1" iface pool prefix
    case "$entry" in *@*/*) ;; *) return 1;; esac
    iface=${entry%%@*}; pool=${entry#*@}; prefix=${pool##*/}
    case "$iface" in ''|*[!A-Za-z0-9_.-]*|awg0|wgc*|tun1[1-5]|tap1[1-5]) return 1;; esac
    [ "${#iface}" -le 15 ] || return 1
    case "$iface" in ipsec|tun*|tap*|ppp*|wg*|awgs*|tailscale*|zt*|vti*|xfrm*|ipsec*|ovpn*) ;; *) return 1;; esac
    case "$prefix" in ''|0*|*[!0-9]*) return 1;; esac
    [ "$prefix" -le 32 ] && valid_ipv4 "${pool%/*}"
}
