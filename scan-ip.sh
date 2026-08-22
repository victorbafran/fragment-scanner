#!/bin/bash
# Find Cloudflare edge addresses that are fast from THIS network.
#
#   scan-ip.sh [options]
#
#     --label NAME       what network this is, e.g. irancell, mci
#     --ranges LIST      comma-separated CIDRs, or a file with one per line
#     --sample N         random addresses probed per range (default 40)
#     --top N            how many survivors get the speed test (default 15)
#     --trials N         repeats per survivor (default 2)
#     --size BYTES       download size per trial (default 200000)
#     --min-speed KB     only report addresses at or above this, in kB/s
#     --max-latency MS   only report addresses at or below this connect time
#     --upload           measure upload as well as download
#     --parallel N       concurrent probes in the first pass (default 40)
#     --host NAME        the Cloudflare-fronted host used for the test
#     --via CONFIG       measure through this xray config instead of directly
#     --mask JSON        fragment mask to use with --via
#     --out FILE         append results as CSV (default ips.csv)
#
# HOW IT MEASURES, AND WHY
#
# The address is pinned with curl's --resolve while the hostname stays put, so
# the TLS handshake and the Host header still name the real site and only the
# edge changes. That is what "clean address" means: same site, different door.
#
# By default it measures against a plain Cloudflare-hosted host that nobody
# filters. Testing through a *filtered* domain cannot work -- every address
# fails identically because the block is on the name, not the address, and the
# scan separates nothing. Find the address first, apply it to your real config
# afterwards.
#
# --via runs the whole thing through your own config instead, which is worth
# doing when your domain is not filtered and you want the number your users
# will actually see. On a filtered domain it needs --mask as well, and even
# then it measures two things at once.
#
# Ping is not used. ICMP is deprioritised or dropped on many Iranian paths, and
# Cloudflare is anycast, so a ping time describes distance to some edge rather
# than throughput. The first pass times the TCP handshake to 443 instead.
#
# Three passes, because a single /13 holds half a million addresses: a cheap
# parallel connect probe, then a ten-byte fetch to drop addresses that do not
# front the host at all, then the real download on what survives.
#
# Results belong to the network they were taken on. An address that is
# excellent on one carrier can be throttled on another, so always --label.
#
# The method here follows MortezaBashsiz/CFScanner, which is the tool this
# community already trusts for it.

set -uo pipefail

LABEL="unlabelled"
SAMPLE=40
TOP=15
TRIALS=2
SIZE=200000
MIN_SPEED=0
MAX_LATENCY=0
UPLOAD=0
PARALLEL=40
OUT="ips.csv"
RANGES=""
HOSTNAME_TEST="speed.cloudflare.com"
DOWNPATH="/__down?bytes="
UPPATH="/__up"
VIA=""
MASK='{"tcp":[{"type":"fragment","settings":{"packets":"tlshello","lengths":["1-2"],"delays":["0"]}}]}'

# Cloudflare ranges that carry the bulk of its edge and are the ones that turn
# out usable from Iran. A deliberate subset of the published list: the rest are
# either tiny or consistently dead, and probing them only spends the budget.
DEFAULT_RANGES="104.16.0.0/13
104.24.0.0/14
172.64.0.0/13
162.159.0.0/16
188.114.96.0/20
190.93.240.0/20
198.41.128.0/17
197.234.240.0/22"

while [ $# -gt 0 ]; do
    case "$1" in
        --label)       LABEL="$2"; shift ;;
        --ranges)      RANGES="$2"; shift ;;
        --sample)      SAMPLE="$2"; shift ;;
        --top)         TOP="$2"; shift ;;
        --trials)      TRIALS="$2"; shift ;;
        --size)        SIZE="$2"; shift ;;
        --min-speed)   MIN_SPEED="$2"; shift ;;
        --max-latency) MAX_LATENCY="$2"; shift ;;
        --upload)      UPLOAD=1 ;;
        --parallel)    PARALLEL="$2"; shift ;;
        --host)        HOSTNAME_TEST="$2"; shift ;;
        --via)         VIA="$2"; shift ;;
        --mask)        MASK="$2"; shift ;;
        --out)         OUT="$2"; shift ;;
        -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown option: $1"; exit 1 ;;
    esac
    shift
done

[ -x "$HOME/fragment-scanner/jq.exe" ] && PATH="$HOME/fragment-scanner:$PATH"
command -v curl > /dev/null || { echo "ABORT: curl is not installed"; exit 1; }

WORK=$(mktemp -d)
PID=""
cleanup() { [ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
trap 'echo; echo "interrupted."; cleanup; exit 130' INT TERM

# ---------- through a config, if asked ----------
PROXY=""
if [ -n "$VIA" ]; then
    command -v jq > /dev/null || { echo "ABORT: jq is needed for --via"; exit 1; }
    [ -s "$VIA" ] || { echo "ABORT: no such config: $VIA"; exit 1; }
    XRAY="${XRAY_BIN:-}"
    if [ -z "$XRAY" ]; then
        for c in ./xray.exe ~/fragment-scanner/xray.exe "${PREFIX:-/usr}/bin/xray" \
                 ./xray ~/fragment-scanner/xray /usr/local/bin/xray /usr/bin/xray; do
            [ -x "$c" ] && { XRAY="$c"; break; }
        done
    fi
    [ -n "$XRAY" ] || { echo "ABORT: no xray binary for --via"; exit 1; }
    # sockopt goes because a classic config reaches its fragment through
    # dialerProxy, and that outbound is not carried over here.
    PROXY=$(jq -c '[.outbounds[] | select(.tag=="proxy" or .protocol=="vless"
                   or .protocol=="vmess" or .protocol=="trojan")][0]
                   | del(.streamSettings.sockopt, .streamSettings.finalmask)' "$VIA")
    [ -n "$PROXY" ] && [ "$PROXY" != "null" ] || { echo "ABORT: no proxy outbound in $VIA"; exit 1; }
    if [ -n "$MASK" ]; then
        MJ=$(printf '%s' "$MASK" | jq -c . 2>/dev/null) || MJ=""
        [ -n "$MJ" ] || { echo "ABORT: --mask is not valid JSON"; exit 1; }
        PROXY=$(echo "$PROXY" | jq -c --argjson fm "$MJ" '.streamSettings.finalmask = $fm')
    fi
fi

if [ -n "$RANGES" ]; then
    if [ -f "$RANGES" ]; then RANGE_LIST=$(grep -vE '^\s*(#|$)' "$RANGES")
    else RANGE_LIST=$(printf '%s' "$RANGES" | tr ',' '\n' | tr -d ' ' | grep .); fi
else
    RANGE_LIST="$DEFAULT_RANGES"
fi

echo "=== clean address scan ==="
echo "  network label : $LABEL"
echo "  test host     : $HOSTNAME_TEST"
echo "  measuring     : $([ -n "$VIA" ] && echo "through $VIA" || echo "directly")"
echo "  ranges        : $(printf '%s\n' "$RANGE_LIST" | grep -c .)"
echo "  probing       : $SAMPLE per range, $PARALLEL at a time"
echo "  speed test on : top $TOP, $TRIALS runs of $SIZE bytes"
echo

[ -s "$OUT" ] || echo "when,label,address,connect_ms,down_kbps,up_kbps" > "$OUT"

rand_ip_in() {
    local cidr="$1" ip bits a b c d base size off n
    ip=${cidr%/*}; bits=${cidr#*/}
    IFS=. read -r a b c d <<< "$ip"
    base=$(( (a<<24) + (b<<16) + (c<<8) + d ))
    size=$(( 1 << (32 - bits) ))
    off=$(( (RANDOM * 32768 + RANDOM) % size ))
    n=$(( base + off ))
    echo "$(( (n>>24)&255 )).$(( (n>>16)&255 )).$(( (n>>8)&255 )).$(( n&255 ))"
}

# ---------- pass 1: connect probe ----------
echo "--- probing ---"
PROBED="$WORK/probed.txt"; : > "$PROBED"
probe_one() {
    local ip="$1" t0 t1
    t0=$(date +%s%N 2>/dev/null) || return
    if timeout 3 bash -c "exec 3<>/dev/tcp/${ip}/443" 2>/dev/null; then
        t1=$(date +%s%N)
        echo "$ip $(( (t1 - t0) / 1000000 ))" >> "$PROBED"
    fi
}
COUNT=0; RUNNING=0
while IFS= read -r cidr; do
    [ -n "$cidr" ] || continue
    for _ in $(seq 1 "$SAMPLE"); do
        probe_one "$(rand_ip_in "$cidr")" &
        RUNNING=$((RUNNING+1)); COUNT=$((COUNT+1))
        [ "$RUNNING" -ge "$PARALLEL" ] && { wait; RUNNING=0; printf '.'; }
    done
done <<< "$RANGE_LIST"
wait; echo
echo "  $COUNT probed, $(grep -c . "$PROBED" 2>/dev/null || echo 0) answered"
[ -s "$PROBED" ] || { echo; echo "  Nothing answered. This network blocks the range on 443, or you are offline."; exit 1; }

if [ "$MAX_LATENCY" != "0" ]; then
    awk -v m="$MAX_LATENCY" '$2 <= m' "$PROBED" > "$WORK/f" && mv "$WORK/f" "$PROBED"
    echo "  $(grep -c . "$PROBED") within ${MAX_LATENCY}ms"
fi

# ---------- pass 2: does it front the host at all ----------
# Ten bytes. An address can accept TCP and still serve nothing useful, and
# finding that out here costs a fraction of a full download.
echo "--- checking which of them serve $HOSTNAME_TEST ---"
FRONTS="$WORK/fronts.txt"; : > "$FRONTS"
RUNNING=0
while read -r ip ms; do
    [ -n "${ip:-}" ] || continue
    ( curl -k -s --tlsv1.2 --max-time 4 -H "Host: $HOSTNAME_TEST" \
           --resolve "${HOSTNAME_TEST}:443:${ip}" \
           "https://${HOSTNAME_TEST}${DOWNPATH}10" -o /dev/null \
      && echo "$ip $ms" >> "$FRONTS" ) &
    RUNNING=$((RUNNING+1))
    [ "$RUNNING" -ge "$PARALLEL" ] && { wait; RUNNING=0; }
done < "$PROBED"
wait
echo "  $(grep -c . "$FRONTS" 2>/dev/null || echo 0) of them answer for it"
[ -s "$FRONTS" ] || { echo; echo "  None served the test host. Try --host with a domain you know is on Cloudflare."; exit 1; }

sort -k2,2n "$FRONTS" | head -"$TOP" > "$WORK/short.txt"
echo

# ---------- pass 3: speed ----------
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && { exec 3<&- 2>/dev/null; return 0; }; return 1; }
free_port() {
    local p
    while :; do
        p=$(( (RANDOM % 40000) + 20000 ))
        case "$p" in 10808|10809) continue ;; esac
        port_busy "$p" || { echo "$p"; return; }
    done
}

start_via() {
    local ip="$1" lp; lp=$(free_port)
    jq -n --argjson proxy "$PROXY" --argjson port "$lp" --arg ip "$ip" '{
        log:{loglevel:"error"},
        inbounds:[{port:$port,listen:"127.0.0.1",protocol:"socks",settings:{auth:"noauth",udp:false}}],
        outbounds:[ ( $proxy | .tag="proxy"
                      | if .settings.vnext then .settings.vnext[0].address=$ip
                        else .settings.address=$ip end ),
                    {protocol:"freedom",tag:"direct"} ]}' > "$WORK/v.json" 2>/dev/null
    "$XRAY" run -c "$WORK/v.json" > "$WORK/v.log" 2>&1 &
    PID=$!
    local i
    for i in $(seq 1 40); do
        port_busy "$lp" && { echo "$lp"; return; }
        kill -0 "$PID" 2>/dev/null || break
        sleep 0.2
    done
    echo ""
}

# speed_of <ip> -> "down_kbps up_kbps"
speed_of() {
    local ip="$1" px="" lp dn=0 up=0 n=0 i v
    if [ -n "$VIA" ]; then
        lp=$(start_via "$ip")
        [ -n "$lp" ] || { PID=""; echo "0 0"; return; }
        px="--socks5-hostname 127.0.0.1:${lp}"
    fi
    for i in $(seq 1 "$TRIALS"); do
        v=$(curl -k -s -o /dev/null --max-time 25 $px \
                 --resolve "${HOSTNAME_TEST}:443:${ip}" \
                 -w '%{http_code} %{speed_download}' \
                 "https://${HOSTNAME_TEST}${DOWNPATH}${SIZE}" 2>/dev/null)
        case "$(echo "$v" | awk '{print $1}')" in
            2*|3*) n=$((n+1)); dn=$(awk -v a="$dn" -v b="$(echo "$v" | awk '{print $2}')" 'BEGIN{print a+b}') ;;
        esac
        if [ "$UPLOAD" = "1" ]; then
            v=$(head -c "$SIZE" /dev/zero | curl -k -s -o /dev/null --max-time 25 $px \
                    --resolve "${HOSTNAME_TEST}:443:${ip}" -X POST --data-binary @- \
                    -w '%{speed_upload}' "https://${HOSTNAME_TEST}${UPPATH}" 2>/dev/null)
            up=$(awk -v a="$up" -v b="${v:-0}" 'BEGIN{print a+b}')
        fi
    done
    [ -n "$VIA" ] && { kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; PID=""; }
    if [ "$n" -gt 0 ]; then
        awk -v d="$dn" -v u="$up" -v n="$n" -v t="$TRIALS" 'BEGIN{printf "%.0f %.0f", d/n/1024, u/t/1024}'
        echo
    else
        echo "0 0"
    fi
}

echo "--- speed ---"
if [ "$UPLOAD" = "1" ]; then
    printf '  %-17s %-10s %-11s %s\n' "address" "conn(ms)" "down kB/s" "up kB/s"
else
    printf '  %-17s %-10s %s\n' "address" "conn(ms)" "down kB/s"
fi
RESULTS="$WORK/results.txt"; : > "$RESULTS"
while read -r ip ms; do
    [ -n "${ip:-}" ] || continue
    r=$(speed_of "$ip")
    dn=$(echo "$r" | awk '{print $1}'); up=$(echo "$r" | awk '{print $2}')
    if [ "$UPLOAD" = "1" ]; then
        printf '  %-17s %-10s %-11s %s\n' "$ip" "$ms" "$dn" "$up"
    else
        printf '  %-17s %-10s %s\n' "$ip" "$ms" "$dn"
    fi
    echo "$ip $ms $dn $up" >> "$RESULTS"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ),$LABEL,$ip,$ms,$dn,$up" >> "$OUT"
done < "$WORK/short.txt"

echo
FINAL="$WORK/final.txt"
awk -v s="$MIN_SPEED" '$3 >= s && $3 > 0' "$RESULTS" | sort -k3,3nr > "$FINAL"
if [ ! -s "$FINAL" ]; then
    echo "=== nothing qualified ==="
    if [ "$MIN_SPEED" != "0" ]; then
        echo "  Nothing reached ${MIN_SPEED} kB/s. Fastest was $(sort -k3,3nr "$RESULTS" | head -1 | awk '{print $3" kB/s at "$1}')."
        echo "  Lower --min-speed, or raise --top so more addresses are tried."
    else
        echo "  Addresses served the host but carried no data. Raise --trials, or"
        echo "  try a different --host."
    fi
    exit 1
fi

echo "=== best on $LABEL, fastest first ==="
head -8 "$FINAL" | while read -r ip ms dn up; do
    if [ "$UPLOAD" = "1" ]; then
        printf '  %-17s  %s kB/s down   %s kB/s up   connect %sms\n' "$ip" "$dn" "$up" "$ms"
    else
        printf '  %-17s  %s kB/s   connect %sms\n' "$ip" "$dn" "$ms"
    fi
done
echo
echo "  put one of these in your config's address field and leave the SNI and"
echo "  host header on your own domain. That pairing is the point; changing"
echo "  either of them undoes it."
echo
echo "  Cloudflare moves what sits behind these, and a carrier can throttle one"
echo "  at any time, so re-run when things slow down rather than trusting an"
echo "  old winner. Each network needs its own scan and its own --label."
echo "IPSCAN_DONE"
