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
#     --min-speed KB     download bar, in kB/s. Set by measuring the line
#                        unless you give a number here
#     --min-upload KB    upload bar, in kB/s. Implies --upload
#     --share PCT        how much of the line's own speed an address has to
#                        reach when the bars are set automatically (default 60)
#     --no-auto          do not measure the line, do not set any bar
#     --max-latency MS   drop addresses whose handshake is slower than this,
#                        before the speed test rather than after
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
MIN_SPEED=""
MIN_UPLOAD=""
MAX_LATENCY=0
UPLOAD=0
MEASURE=download
AUTO=1
SHARE=60
PARALLEL=40
OUT="ips.csv"
RANGES=""
HOSTNAME_TEST="speed.cloudflare.com"
DOWNPATH="/__down?bytes="
UPPATH="/__up"
VIA=""
DIRECT=0
CFGPORT=443
OWN=""
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

# ---------- settings file ----------
# Read before the command line so a flag still wins. Parsed rather than
# sourced: a hand-edited file should not be able to run anything, and a
# misspelled name should be pointed out instead of silently ignored.
CONF=""
PREV_ARG=""
for a in "$@"; do [ "$PREV_ARG" = "--conf" ] && CONF="$a"; PREV_ARG="$a"; done
[ -n "$CONF" ] || for c in ./settings.conf ~/fragment-scanner/settings.conf; do
    [ -f "$c" ] && { CONF="$c"; break; }
done

load_conf() {
    local f="$1" line k v
    [ -f "$f" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line=$(printf '%s' "$line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -n "$line" ] || continue
        case "$line" in *=*) : ;; *) continue ;; esac
        k=$(printf '%s' "${line%%=*}" | tr -d '[:space:]')
        v=$(printf '%s' "${line#*=}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//')
        [ -n "$v" ] || continue
        case "$k" in
            label)       LABEL="$v" ;;
            sample)      SAMPLE="$v" ;;
            top)         TOP="$v" ;;
            trials)      TRIALS="$v" ;;
            size)        SIZE="$v" ;;
            parallel)    PARALLEL="$v" ;;
            share)       SHARE="$v" ;;
            min_speed)   MIN_SPEED="$v"; AUTO=0 ;;
            min_upload)  MIN_UPLOAD="$v"; AUTO=0
                         case "$MEASURE" in download) MEASURE=both ;; esac ;;
            max_latency) MAX_LATENCY="$v" ;;
            measure)     MEASURE="$v" ;;
            upload)      case "$v" in yes|true|1) MEASURE=both ;; esac ;;
            auto)        case "$v" in no|false|0) AUTO=0 ;; esac ;;
            host)        HOSTNAME_TEST="$v" ;;
            down_path)   DOWNPATH="$v" ;;
            up_path)     UPPATH="$v" ;;
            ranges_file) [ -f "$v" ] && RANGES="$v" ;;
            config)      [ -f "$v" ] && VIA="$v" ;;
            direct)      case "$v" in yes|true|1) DIRECT=1 ;; esac ;;
            out)         OUT="$v" ;;
            *) echo "note: unknown setting '$k' in $f, ignored" >&2 ;;
        esac
    done < "$f"
}
load_conf "$CONF"

while [ $# -gt 0 ]; do
    case "$1" in
        --conf)        shift ;;
        --label)       LABEL="$2"; shift ;;
        --ranges)      RANGES="$2"; shift ;;
        --sample)      SAMPLE="$2"; shift ;;
        --top)         TOP="$2"; shift ;;
        --trials)      TRIALS="$2"; shift ;;
        --size)        SIZE="$2"; shift ;;
        --min-speed)   MIN_SPEED="$2"; AUTO=0; shift ;;
        --min-upload)  MIN_UPLOAD="$2"; UPLOAD=1; AUTO=0; shift ;;
        --max-latency) MAX_LATENCY="$2"; shift ;;
        --upload)      MEASURE=both ;;
        --measure)     MEASURE="$2"; shift ;;
        --share)       SHARE="$2"; shift ;;
        --no-auto)     AUTO=0 ;;
        --parallel)    PARALLEL="$2"; shift ;;
        --host)        HOSTNAME_TEST="$2"; shift ;;
        --down-path)   DOWNPATH="$2"; shift ;;
        --up-path)     UPPATH="$2"; shift ;;
        --via)         VIA="$2"; DIRECT=0; shift ;;
        --direct)      DIRECT=1 ;;
        --mask)        MASK="$2"; shift ;;
        --out)         OUT="$2"; shift ;;
        -h|--help)     sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown option: $1"; exit 1 ;;
    esac
    shift
done

[ -x "$HOME/fragment-scanner/jq.exe" ] && PATH="$HOME/fragment-scanner:$PATH"
command -v curl > /dev/null || { echo "ABORT: curl is not installed"; exit 1; }

# download | upload | both. Everything downstream keys off these two flags:
# what gets measured, what an address is judged on, and what "carries no
# traffic" means -- in upload-only mode a zero download is expected, not a
# fault, and treating it as one would throw away every good address.
# Only speed.cloudflare.com offers somewhere to POST to. Point --host at an
# ordinary site and upload cannot be measured at all, so say that rather than
# silently returning zeros that would then read as dead addresses.
case "${UPPATH:-}" in
    ""|-|none)
        case "$MEASURE" in
            upload|both)
                echo "ABORT: ${HOSTNAME_TEST} has no upload endpoint, so measure=${MEASURE}"
                echo "  cannot work against it. Either set measure = download, or use a"
                echo "  host that accepts uploads -- speed.cloudflare.com is the usual one."
                exit 1 ;;
        esac ;;
esac

case "$MEASURE" in
    download) DO_DOWN=1; DO_UP=0 ;;
    upload)   DO_DOWN=0; DO_UP=1 ;;
    both)     DO_DOWN=1; DO_UP=1 ;;
    *) echo "ABORT: measure must be download, upload or both -- got '$MEASURE'"; exit 1 ;;
esac
UPLOAD="$DO_UP"

# Defined up here because bash resolves a function only once it has been read,
# and calibration runs long before the body of the script.
nlines() { local n; n=$(grep -c . "$1" 2>/dev/null); echo "${n:-0}"; }

# A pool, not a workload: the speed test walks it from the top and stops as
# soon as it has TOP working addresses, usually long before the pool runs out.
# The margin is for the ones that pass the middle pass and still carry nothing
# through the tunnel, or land under the bar. Measured attrition on these
# networks is 20-30%, so double covers it. Defined here because both earlier
# passes size themselves against it.
NEED=$(( TOP * 2 ))
[ "$NEED" -lt 10 ] && NEED=10

# speed.cloudflare.com takes the size in the path; anything else serves a fixed
# page. Both are fine for ranking addresses against each other, which is all
# this needs -- but only the first can be asked for a particular size.
url_down() {
    case "$DOWNPATH" in
        *bytes=) echo "https://${HOSTNAME_TEST}${DOWNPATH}${1:-$SIZE}" ;;
        *)       echo "https://${HOSTNAME_TEST}${DOWNPATH}" ;;
    esac
}

WORK=$(mktemp -d)
PID=""
# Belt as well as braces. Each helper stops the xray it started, but a kill
# that quietly fails would otherwise leave one running per address scanned,
# and the terminal then refuses to close because processes are alive under it.
# Sweeping by config path catches anything the ordinary path missed without
# touching an xray the user is running for themselves.
cleanup() {
    [ -n "${XPID:-}" ] && kill "$XPID" 2>/dev/null
    [ -n "$PID" ] && kill "$PID" 2>/dev/null
    pkill -f "$WORK" 2>/dev/null
    rm -rf "$WORK"
    return 0
}
trap cleanup EXIT
trap 'echo; echo "interrupted."; cleanup; exit 130' INT TERM

# ---------- through a config ----------
# The address scan runs through its own sample config by default, kept apart
# from the fragment scanner's working.json so the two never interfere. --direct
# drops back to measuring the plain Cloudflare edge with no tunnel at all.
[ "$DIRECT" = "1" ] && VIA=""
if [ -z "$VIA" ] && [ "$DIRECT" != "1" ]; then
    for c in ./ip.json ~/fragment-scanner/ip.json; do
        [ -f "$c" ] && { VIA="$c"; break; }
    done
fi
PROXY=""
ORIG_ADDR=""
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
    ORIG_ADDR=$(echo "$PROXY" | jq -r '.settings.vnext[0].address // .settings.address // ""')
    # The hostname in SNI and Host is what identifies your site to Cloudflare,
    # and the port is whatever the config connects on. The address field is
    # only the door it happens to use today, and replacing it is the whole
    # point -- so nothing is probed or checked against it.
    CFGPORT=$(echo "$PROXY" | jq -r '.settings.vnext[0].port // .settings.port // 443')
    OWN=$(echo "$PROXY" | jq -r '.streamSettings.tlsSettings.serverName
                                 // .streamSettings.wsSettings.headers.Host
                                 // .streamSettings.wsSettings.host // ""')
    [ "$OWN" = "null" ] && OWN=""
    if [ -n "$MASK" ]; then
        MJ=$(printf '%s' "$MASK" | jq -c . 2>/dev/null) || MJ=""
        [ -n "$MJ" ] || { echo "ABORT: --mask is not valid JSON"; exit 1; }
        PROXY=$(echo "$PROXY" | jq -c --argjson fm "$MJ" '.streamSettings.finalmask = $fm')
    fi
fi

[ -n "$RANGES" ] || for r in ./ranges.txt ~/fragment-scanner/ranges.txt; do
    [ -f "$r" ] && { RANGES="$r"; break; }
done
if [ -n "$RANGES" ]; then
    if [ -f "$RANGES" ]; then
        RANGE_LIST=$(sed 's/#.*//' "$RANGES" | tr -d '\r' | grep -oE '[0-9.]+/[0-9]+')
        RANGE_SRC="$RANGES"
    else
        RANGE_LIST=$(printf '%s' "$RANGES" | tr ',' '\n' | tr -d ' ' | grep .)
        RANGE_SRC="the command line"
    fi
else
    RANGE_LIST="$DEFAULT_RANGES"
    RANGE_SRC="built-in defaults"
fi
[ -n "$RANGE_LIST" ] || { echo "ABORT: no usable CIDR found in ${RANGE_SRC}"; exit 1; }

echo "=== clean address scan ==="
echo "  network label : $LABEL"
echo "  test host     : $HOSTNAME_TEST"
if [ -n "$VIA" ]; then
    echo "  measuring     : through the tunnel in $VIA"
    echo "  your hostname : ${OWN:-none}"
    echo "  port          : $CFGPORT"
    echo "  address field : ${ORIG_ADDR:-none}, replaced by every candidate"
else
    echo "  measuring     : the Cloudflare edge directly, no tunnel"
fi
echo "  settings from : ${CONF:-built-in defaults}"
echo "  ranges        : $(printf '%s\n' "$RANGE_LIST" | grep -c .) from ${RANGE_SRC}"
echo "  probing       : $SAMPLE per range, $PARALLEL at a time"
echo "  speed test on : top $TOP, $TRIALS runs of $SIZE bytes"
echo

[ -s "$OUT" ] || echo "when,label,address,connect_ms,down_kbps,up_kbps" > "$OUT"

port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && { exec 3<&- 2>/dev/null; return 0; }; return 1; }
free_port() {
    local p
    while :; do
        p=$(( (RANDOM % 40000) + 20000 ))
        case "$p" in 10808|10809) continue ;; esac
        port_busy "$p" || { echo "$p"; return; }
    done
}

# Sets XPID and XPORT rather than printing the port. Printing meant callers
# used $( ), which runs the whole thing in a subshell -- so the pid was
# recorded there and lost on return, and every kill afterwards had nothing to
# kill. One xray survived per address scanned, and the terminal then refused
# to close because processes were still running under it.
XPID=""
XPORT=""
start_via() {
    local ip="$1" lp i
    XPID=""; XPORT=""
    lp=$(free_port)
    jq -n --argjson proxy "$PROXY" --argjson port "$lp" --arg ip "$ip" '{
        log:{loglevel:"error"},
        inbounds:[{port:$port,listen:"127.0.0.1",protocol:"socks",settings:{auth:"noauth",udp:false}}],
        outbounds:[ ( $proxy | .tag="proxy"
                      | if .settings.vnext then .settings.vnext[0].address=$ip
                        else .settings.address=$ip end ),
                    {protocol:"freedom",tag:"direct"} ]}' > "$WORK/v-${lp}.json" 2>/dev/null
    "$XRAY" run -c "$WORK/v-${lp}.json" > "$WORK/v.log" 2>&1 &
    XPID=$!
    for i in $(seq 1 40); do
        port_busy "$lp" && { XPORT="$lp"; return 0; }
        kill -0 "$XPID" 2>/dev/null || break
        sleep 0.2
    done
    kill "$XPID" 2>/dev/null; wait "$XPID" 2>/dev/null; XPID=""
    return 1
}

stop_via() {
    [ -n "$XPID" ] || return 0
    kill "$XPID" 2>/dev/null
    wait "$XPID" 2>/dev/null
    XPID=""
}

# ---------- calibrate against the line itself ----------
# A fixed threshold is meaningless without knowing what the line can do. On a
# 1 MB/s connection a limit set for a fast one rejects everything and the run
# looks like it found nothing, when really nothing could have qualified. So
# measure the line first, unfiltered and unpinned, and set the bar as a share
# of what it actually manages.
# Always run, even when the bars are set by hand. In that case the numbers are
# not used to set anything -- they are used to catch a bar the line itself
# cannot reach, which otherwise scans every candidate to the end and reports
# nothing, looking like the addresses are at fault.
if true; then
    CAL_PX=""
    # Only calibrate through the tunnel when the bar is being derived from it,
    # where the two have to be measured the same way or the bar is wrong. With
    # a bar of your own the figure is only there to show the line was tested,
    # and going through the config would report whatever edge DNS happened to
    # pick for it -- one sample of one edge, which says little about the line.
    if [ -n "$VIA" ] && [ "$AUTO" = "1" ]; then
        # Measure through the tunnel at its own address. A tunnel never reaches
        # the raw line speed, so calibrating on the bare line sets a bar no
        # address could clear and the run reports nothing.
        echo "--- calibrating through the tunnel, at its own address ---"
        start_via "$ORIG_ADDR" && CAL_PX="--socks5-hostname 127.0.0.1:${XPORT}"
    else
        echo "--- calibrating against this line ---"
    fi
    CAL_D=0; CAL_U=0; CAL_N=0
    if [ "$DO_DOWN" = "1" ]; then
      for i in 1 2; do
        v=$(curl -k -s -o /dev/null --max-time 30 $CAL_PX -w '%{http_code} %{speed_download}' \
                 "$(url_down)" 2>/dev/null)
        case "$(echo "$v" | awk '{print $1}')" in
            2*|3*) CAL_N=$((CAL_N+1))
                   CAL_D=$(awk -v a="$CAL_D" -v b="$(echo "$v" | awk '{print $2}')" 'BEGIN{print a+b}') ;;
        esac
      done
    else
        CAL_N=1
    fi
    if [ "$DO_UP" = "1" ]; then
        v=$(head -c "$SIZE" /dev/zero | curl -k -s -o /dev/null --max-time 30 $CAL_PX \
                -X POST --data-binary @- -w '%{speed_upload}' \
                "https://${HOSTNAME_TEST}${UPPATH}" 2>/dev/null)
        CAL_U=$(awk -v b="${v:-0}" 'BEGIN{printf "%.0f", b/1024}')
    fi
    [ -n "$CAL_PX" ] && stop_via
    if [ "$CAL_N" -gt 0 ]; then
        LINE_D=$(awk -v d="$CAL_D" -v n="$CAL_N" 'BEGIN{printf "%.0f", d/n/1024}')
        LINE_U="$CAL_U"
        if [ "$AUTO" = "1" ]; then
            [ "$DO_DOWN" = "1" ] && {
                MIN_SPEED=$(awk -v l="$LINE_D" -v s="$SHARE" 'BEGIN{printf "%.0f", l*s/100}')
                echo "  this line does about ${LINE_D} kB/s down, so the bar is ${MIN_SPEED}"; }
            [ "$DO_UP" = "1" ] && {
                MIN_UPLOAD=$(awk -v l="$LINE_U" -v s="$SHARE" 'BEGIN{printf "%.0f", l*s/100}')
                echo "  and about ${LINE_U} kB/s up, so the bar is ${MIN_UPLOAD}"; }
            echo "  (${SHARE}% of what this line manages)"
        else
            [ "$DO_DOWN" = "1" ] && echo "  the line managed about ${LINE_D} kB/s down just now, your bar is ${MIN_SPEED}"
            [ "$DO_UP" = "1" ]   && echo "  and about ${LINE_U} kB/s up, your bar is ${MIN_UPLOAD}"
            # Said, not enforced. This is one sample down one path and the bar
            # is your decision: if nothing below it is any use to you, there is
            # no point reporting what is below it either.
            HIGH=""
            [ "$DO_DOWN" = "1" ] && awk -v b="$MIN_SPEED"  -v l="$LINE_D" 'BEGIN{exit !(b>l)}' && HIGH="download"
            [ "$DO_UP" = "1" ]   && awk -v b="$MIN_UPLOAD" -v l="$LINE_U" 'BEGIN{exit !(b>l)}' && HIGH="${HIGH:+$HIGH and }upload"
            # The reading above was taken without the tunnel while the results
            # below go through it, so they are not comparable and a bar set
            # from the first will reject everything the second can produce.
            [ -n "$VIA" ] && {
                echo "  careful: that was measured WITHOUT the tunnel, and the addresses"
                echo "  below are measured THROUGH it, which always comes out lower."
                echo "  Set the bar from a previous run's results, not from this figure."; }
            [ -n "$HIGH" ] && \
                echo "  note: the $HIGH bar is above even that reading, so expect none"
        fi
    else
        echo "  could not reach $HOSTNAME_TEST directly, so no bar is set"
        MIN_SPEED=0
    fi
    echo
fi
MIN_SPEED="${MIN_SPEED:-0}"
MIN_UPLOAD="${MIN_UPLOAD:-0}"


# grep -c prints 0 and exits non-zero when it matches nothing, so the obvious
# "|| echo 0" fallback appends a second zero and the result is two lines. It
# read as a doubled number in the output for a while, and became a hard error
# the moment one was compared as an integer.

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
    if timeout 3 bash -c "exec 3<>/dev/tcp/${ip}/${CFGPORT}" 2>/dev/null; then
        t1=$(date +%s%N)
        echo "$ip $(( (t1 - t0) / 1000000 ))" >> "$PROBED"
    fi
}
# Addresses are drawn a round at a time -- one from each range, then again --
# rather than all of one range before the next. Stopping early then still
# leaves an even spread; the old order would have meant a short run never
# looking past the first range at all.
CAND="$WORK/cand.txt"; : > "$CAND"
i=0
while [ "$i" -lt "$SAMPLE" ]; do
    while IFS= read -r cidr; do
        [ -n "$cidr" ] && rand_ip_in "$cidr" >> "$CAND"
    done <<< "$RANGE_LIST"
    i=$((i+1))
done

# Enough live addresses to feed the next pass, not every address there is.
# Roughly a third of what answers here goes on to serve the host, so five
# times the candidate target is a comfortable margin -- and on a wide sample
# it is the difference between forty batches and four.
ALIVE_TARGET=$(( NEED * 5 ))
[ "$ALIVE_TARGET" -lt 40 ] && ALIVE_TARGET=40

COUNT=0; RUNNING=0
while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    probe_one "$ip" &
    RUNNING=$((RUNNING+1)); COUNT=$((COUNT+1))
    if [ "$RUNNING" -ge "$PARALLEL" ]; then
        wait; RUNNING=0; printf '.'
        [ "$(nlines "$PROBED")" -ge "$ALIVE_TARGET" ] && break
    fi
done < "$CAND"
wait; echo
echo "  $COUNT probed, $(nlines "$PROBED") answered"
[ -s "$PROBED" ] || { echo; echo "  Nothing answered. This network blocks the range on 443, or you are offline."; exit 1; }

if [ "$MAX_LATENCY" != "0" ]; then
    FASTEST=$(sort -k2,2n "$PROBED" | head -1 | awk '{print $2}')
    awk -v m="$MAX_LATENCY" '$2 <= m' "$PROBED" > "$WORK/f" && mv "$WORK/f" "$PROBED"
    KEPT=$(nlines "$PROBED")
    echo "  $KEPT within ${MAX_LATENCY}ms"
    # Without this the run dies two passes later complaining about the test
    # host, which is not what went wrong and sends you looking in the wrong
    # place. The filter is applied here, so it explains itself here.
    if [ "$KEPT" = "0" ]; then
        echo
        echo "  --max-latency ${MAX_LATENCY} removed every address. The quickest"
        echo "  handshake on this network was ${FASTEST}ms, so nothing could qualify."
        echo "  Raise it above that, or drop the option and read the times first."
        exit 1
    fi
fi

# ---------- pass 2: does it front the host at all ----------
# Ten bytes. An address can accept TCP and still serve nothing useful, and
# finding that out here costs a fraction of a full download.
# When there is a config, ask the question the speed test will ask: does this
# edge serve *your* hostname. A stranger's hostname answers a different one,
# and an edge can pass that and fail this.
#
# /cdn-cgi/trace, not the site root. Cloudflare answers that path itself on
# every proxied hostname, so it proves the edge routes your name without
# involving your server at all. Asking for / instead hits the websocket
# endpoint, which receives a request carrying no Upgrade header and simply
# holds the connection until the timeout -- indistinguishable from the name
# being blocked, which is exactly how it was misread.
CHECK_HOST="$HOSTNAME_TEST"
CHECK_URL="$(url_down 10)"
CHECK_ANY=0
if [ -n "$OWN" ]; then
    CHECK_HOST="$OWN"
    CHECK_URL="https://${OWN}/cdn-cgi/trace"
    CHECK_ANY=1
fi

echo "--- checking which of them serve $CHECK_HOST ---"
FRONTS="$WORK/fronts.txt"; : > "$FRONTS"
# Far heavier than a TCP connect -- each one is a full TLS handshake -- so it
# gets its own, much lower concurrency. Run at the probe's rate on a mobile
# line, all of them share the bandwidth, every one runs past the timeout, and
# the pass reports that nothing serves the host at all. Serially the same
# request answers in about two seconds.
FRONT_PAR="$PARALLEL"
[ "$FRONT_PAR" -gt 16 ] && FRONT_PAR=16
sort -k2,2n "$PROBED" > "$WORK/byms.txt"
RUNNING=0
BATCH=0
while read -r ip ms; do
    [ -n "${ip:-}" ] || continue
    ( code=$(curl -k -s --tlsv1.2 --max-time 12 -H "Host: $CHECK_HOST" \
                  --resolve "${CHECK_HOST}:${CFGPORT}:${ip}" -o /dev/null \
                  -w '%{http_code}' "$CHECK_URL" 2>/dev/null)
      case "${code:-000}" in
          000) : ;;
          2*|3*) echo "$ip $ms" >> "$FRONTS" ;;
          *) [ "$CHECK_ANY" = "1" ] && echo "$ip $ms" >> "$FRONTS" ;;
      esac ) &
    RUNNING=$((RUNNING+1))
    if [ "$RUNNING" -ge "$FRONT_PAR" ]; then
        wait; RUNNING=0
        BATCH=$((BATCH+1))
        GOT=$(nlines "$FRONTS")
        # This pass is slow and silent -- a full TLS request each, sixteen at a
        # time -- and without a sign of life it reads as a hang.
        [ -t 1 ] && printf '\r  %d found, %d needed   ' "$GOT" "$NEED"
        [ "$GOT" -ge "$NEED" ] && break
        # Two full batches of your own hostname answering nothing means it is
        # blocked here, not that these particular addresses are bad. Grinding
        # through the rest at twelve seconds apiece only delays the fallback.
        if [ "$CHECK_ANY" = "1" ] && [ "$GOT" = "0" ] && [ "$BATCH" -ge 2 ]; then
            [ -t 1 ] && printf '\r%*s\r' 34 ''
            break
        fi
    fi
done < "$WORK/byms.txt"
wait
[ -t 1 ] && printf '\r%*s\r' 34 ''
echo "  $(nlines "$FRONTS") of them answer for it"
# Your own hostname failing everywhere usually means it is filtered here, not
# that the addresses are bad. The generic host answers a weaker question but it
# still ranks edges, so fall back rather than giving up.
if [ ! -s "$FRONTS" ] && [ "$CHECK_ANY" = "1" ]; then
    echo "  none of them, which does not mean $CHECK_HOST is blocked."
    echo "  This check uses curl, and some networks drop a handshake by its shape"
    echo "  rather than by the name in it -- a config with a browser fingerprint"
    echo "  reaches the same host on the same network where curl cannot. Measured"
    echo "  here: xray with fingerprint=chrome got through, plain curl did not."
    echo "  Falling back to $HOSTNAME_TEST, which ranks edges but cannot tell"
    echo "  whether one serves your hostname in particular."
    CHECK_HOST="$HOSTNAME_TEST"; CHECK_URL="$(url_down 10)"; CHECK_ANY=0
    RUNNING=0
    while read -r ip ms; do
        [ -n "${ip:-}" ] || continue
        ( curl -k -s --tlsv1.2 --max-time 12 -H "Host: $CHECK_HOST" \
               --resolve "${CHECK_HOST}:${CFGPORT}:${ip}" -o /dev/null "$CHECK_URL" \
          && echo "$ip $ms" >> "$FRONTS" ) &
        RUNNING=$((RUNNING+1))
        if [ "$RUNNING" -ge "$FRONT_PAR" ]; then
            wait; RUNNING=0
            [ "$(nlines "$FRONTS")" -ge "$NEED" ] && break
        fi
    done < "$WORK/byms.txt"
    wait
    echo "  $(nlines "$FRONTS") of them answer for it"
fi

if [ ! -s "$FRONTS" ]; then
    echo
    echo "  None served the test host, although $(nlines "$PROBED") answered on 443."
    echo "  A connection that opens but never completes a TLS request usually means"
    echo "  the checks are crowding each other out rather than anything being"
    echo "  blocked. Lower parallel in settings.conf -- 16 or less on a mobile"
    echo "  line -- or try --host with another domain you know sits on Cloudflare."
    exit 1
fi

# Not truncated to $TOP here. Some addresses answer, front the host, and still
# carry nothing through the tunnel, and stopping after a fixed number of
# attempts would leave you with fewer usable results than you asked for. The
# loop below keeps going down the list until it has $TOP that actually work.
sort -k2,2n "$FRONTS" > "$WORK/short.txt"
echo

# speed_of <ip> -> "down_kbps up_kbps"
speed_of() {
    local ip="$1" px="" lp dn=0 up=0 n=0 i v
    if [ -n "$VIA" ]; then
        start_via "$ip" || { echo "0 0"; return; }
        px="--socks5-hostname 127.0.0.1:${XPORT}"
    fi
    for i in $(seq 1 "$TRIALS"); do
        if [ "$DO_DOWN" = "1" ]; then
            v=$(curl -k -s -o /dev/null --max-time 25 $px \
                     --resolve "${HOSTNAME_TEST}:${CFGPORT}:${ip}" \
                     -w '%{http_code} %{speed_download}' \
                     "$(url_down)" 2>/dev/null)
            case "$(echo "$v" | awk '{print $1}')" in
                2*|3*) n=$((n+1)); dn=$(awk -v a="$dn" -v b="$(echo "$v" | awk '{print $2}')" 'BEGIN{print a+b}') ;;
            esac
        else
            n=$((n+1))
        fi
        if [ "$DO_UP" = "1" ]; then
            v=$(head -c "$SIZE" /dev/zero | curl -k -s -o /dev/null --max-time 25 $px \
                    --resolve "${HOSTNAME_TEST}:${CFGPORT}:${ip}" -X POST --data-binary @- \
                    -w '%{speed_upload}' "https://${HOSTNAME_TEST}${UPPATH}" 2>/dev/null)
            up=$(awk -v a="$up" -v b="${v:-0}" 'BEGIN{print a+b}')
        fi
    done
    stop_via
    if [ "$n" -gt 0 ]; then
        awk -v d="$dn" -v u="$up" -v n="$n" -v t="$TRIALS" 'BEGIN{printf "%.0f %.0f", d/n/1024, u/t/1024}'
        echo
    else
        echo "0 0"
    fi
}

echo "--- speed (${MEASURE}) ---"
if [ "$MEASURE" = both ]; then
    printf '  %-17s %-10s %-11s %s\n' "address" "conn(ms)" "down kB/s" "up kB/s"
elif [ "$MEASURE" = upload ]; then
    printf '  %-17s %-10s %s\n' "address" "conn(ms)" "up kB/s"
else
    printf '  %-17s %-10s %s\n' "address" "conn(ms)" "down kB/s"
fi
RESULTS="$WORK/results.txt"; : > "$RESULTS"
FOUND=0
DROPPED=0
SLOW=0
while read -r ip ms; do
    [ -n "${ip:-}" ] || continue
    [ "$FOUND" -ge "$TOP" ] && break
    r=$(speed_of "$ip")
    dn=$(echo "$r" | awk '{print $1}'); up=$(echo "$r" | awk '{print $2}')
    # An address that carries nothing is not a slow address, it is a dead one.
    # Printing it or writing it down only adds noise to a list meant to be
    # picked from, so it is dropped and the next candidate is tried instead.
    # Judged on whatever is being measured. In upload-only mode a zero
    # download is the expected outcome, not a fault.
    if [ "$DO_DOWN" = "1" ]; then KEY="${dn:-0}"; else KEY="${up:-0}"; fi
    # The in-place counter is for a terminal only. Down a pipe the carriage
    # returns are kept literally and every result row ends up buried in them.
    progress() { [ -t 1 ] && printf '\r  ...%d unusable, %d too slow, still looking   ' "$DROPPED" "$SLOW"; return 0; }
    if [ "$KEY" = "0" ]; then
        DROPPED=$((DROPPED+1))
        progress
        continue
    fi
    # The bar is applied here rather than only at the end, so the table is a
    # list of addresses you could actually use rather than a log of everything
    # that was tried.
    BELOW=0
    [ "$DO_DOWN" = "1" ] && awk -v a="$dn" -v b="$MIN_SPEED"  'BEGIN{exit !(a<b)}' && BELOW=1
    [ "$DO_UP" = "1" ]   && awk -v a="$up" -v b="$MIN_UPLOAD" 'BEGIN{exit !(a<b)}' && BELOW=1
    if [ "$BELOW" = "1" ]; then
        SLOW=$((SLOW+1))
        progress
        continue
    fi
    { [ -t 1 ] && { [ "$DROPPED" -gt 0 ] || [ "$SLOW" -gt 0 ]; }; } && printf '\r%*s\r' 52 ''
    FOUND=$((FOUND+1))
    if [ "$MEASURE" = both ]; then
        printf '  %-17s %-10s %-11s %s\n' "$ip" "$ms" "$dn" "$up"
    elif [ "$MEASURE" = upload ]; then
        printf '  %-17s %-10s %s\n' "$ip" "$ms" "$up"
    else
        printf '  %-17s %-10s %s\n' "$ip" "$ms" "$dn"
    fi
    echo "$ip $ms $dn $up" >> "$RESULTS"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ),$LABEL,$ip,$ms,$dn,$up" >> "$OUT"
done < "$WORK/short.txt"
{ [ -t 1 ] && { [ "$DROPPED" -gt 0 ] || [ "$SLOW" -gt 0 ]; }; } && printf '\r%*s\r' 52 ''
[ "$DROPPED" -gt 0 ] && echo "  $DROPPED answered but carried nothing, skipped"
[ "$SLOW" -gt 0 ]    && echo "  $SLOW were under the bar, skipped"
[ "$FOUND" -lt "$TOP" ] && [ "$FOUND" -gt 0 ] && \
    echo "  ran out of candidates at $FOUND of $TOP -- raise sample in settings.conf"

echo
FINAL="$WORK/final.txt"
# Filter on whichever bars apply, and rank on the metric that was asked for.
if [ "$DO_DOWN" = "1" ]; then SORTKEY=3; else SORTKEY=4; fi
awk -v s="$MIN_SPEED" -v u="$MIN_UPLOAD" -v d="$DO_DOWN" -v w="$DO_UP" -v k="$SORTKEY" \
    '(d==0 || ($3 >= s)) && (w==0 || ($4 >= u)) && $k > 0' "$RESULTS" \
    | sort -k${SORTKEY},${SORTKEY}nr > "$FINAL"
if [ ! -s "$FINAL" ]; then
    echo "=== nothing qualified ==="
    BEST_D=$(sort -k3,3nr "$RESULTS" | head -1 | awk '{print $3}')
    BEST_U=$(sort -k4,4nr "$RESULTS" | head -1 | awk '{print $4}')
    if [ "${BEST_D:-0}" = "0" ]; then
        echo "  Addresses served the host but carried no data at all. Raise --trials,"
        echo "  or try a different --host."
    else
        # Name the threshold that actually bit, and the number that would have
        # passed. Otherwise the only way to find out is to guess and re-run.
        [ "$MIN_SPEED" != "0" ] && [ "$BEST_D" -lt "$MIN_SPEED" ] 2>/dev/null && \
            echo "  Best download was ${BEST_D} kB/s, under the ${MIN_SPEED} kB/s bar."
        [ "$MIN_UPLOAD" != "0" ] && [ "${BEST_U:-0}" -lt "$MIN_UPLOAD" ] 2>/dev/null && \
            echo "  Best upload was ${BEST_U:-0} kB/s, under the ${MIN_UPLOAD} kB/s bar."
        if [ "$AUTO" = "1" ]; then
            echo "  Those bars came from measuring this line, at ${SHARE}% of what it"
            echo "  managed. If the line itself was busy during calibration the bar is"
            echo "  too high -- lower it with --share 40, or set --min-speed by hand."
        else
            echo "  Lower the threshold, or raise --top so more addresses are tried."
        fi
    fi
    exit 1
fi

echo "=== best on $LABEL, fastest first ==="
head -8 "$FINAL" | while read -r ip ms dn up; do
    if [ "$MEASURE" = both ]; then
        printf '  %-17s  %s kB/s down   %s kB/s up   connect %sms\n' "$ip" "$dn" "$up" "$ms"
    elif [ "$MEASURE" = upload ]; then
        printf '  %-17s  %s kB/s up   connect %sms\n' "$ip" "$up" "$ms"
    else
        printf '  %-17s  %s kB/s down   connect %sms\n' "$ip" "$dn" "$ms"
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
