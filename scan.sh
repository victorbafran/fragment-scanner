#!/bin/bash
# Measure which TLS fragment parameters survive the DPI on THIS network.
#
#   scan.sh <working-config.json> [options]
#
#     --label NAME     what network this is, e.g. irancell, mci, datacenter
#     --trials N       repeats per candidate (default 5)
#     --target URL     what to fetch through the proxy
#     --out FILE       append results as CSV (default results.csv)
#     --full           also test length/delay pairs after the staged sweep
#
# WHERE TO RUN IT
#
# Inside the filtered network. Nowhere else. Run this abroad and there is no
# DPI on the path, so every candidate succeeds, and the table it prints is
# noise dressed up as a measurement. The script checks for this and says so.
#
# The same is true across networks: a datacenter, a home line and a mobile
# carrier do not get the same treatment. Run it once per network with --label
# and compare the CSV afterwards rather than assuming one answer fits all.
# On Android, Termux runs this as-is.
#
# HOW IT WORKS
#
# Takes a config that already works, strips the fragmentation out of it, and
# for each candidate starts a throwaway xray with a SOCKS inbound on a random
# high port. It then makes several requests through that proxy and records
# whether it connected, how long the TLS handshake took, and how fast the
# transfer ran.
#
# Three decisions behind that:
#
#   Repeats, because blocking is probabilistic. A single success proves
#   nothing, so candidates are ranked on success rate first.
#
#   Speed as well as reachability. Tiny fragments usually get through but
#   cost handshake time. The best setting is a trade-off, so both are shown.
#
#   A staged sweep -- packets, then lengths, then delays -- because the full
#   cross product is hundreds of runs. Use --full if you suspect two
#   parameters interact.
#
# It never binds 10808 or 10809. Those belong to whatever client is already
# running on the machine, and taking them cuts the network out from under you.

set -uo pipefail

CFG="${1:-}"
case "$CFG" in
    ""|-h|--help) sed -n '2,12p' "$0"; exit 1 ;;
esac
shift

LABEL="unlabelled"
TRIALS=5
# Something with a body, because a 204 with no content makes every throughput
# reading 0 and removes the tie-breaker exactly when candidates all connect.
# Kept small on purpose: a large payload over a slow path runs past the curl
# timeout and gets scored as blocked, which invents failures that are really
# just bandwidth.
TARGET="https://speed.cloudflare.com/__down?bytes=50000"
TIMEOUT=25
OUT="results.csv"
MODE=quick

while [ $# -gt 0 ]; do
    case "$1" in
        --label)  LABEL="$2"; shift ;;
        --trials) TRIALS="$2"; shift ;;
        --target) TARGET="$2"; shift ;;
        --out)    OUT="$2"; shift ;;
        --full)   MODE=full ;;
        *) echo "unknown option: $1"; exit 1 ;;
    esac
    shift
done

[ -s "$CFG" ] || { echo "ABORT: no such config: $CFG"; exit 1; }
# install.sh drops a jq.exe here on Windows, where there is no package manager
# to put one on PATH.
[ -x "$HOME/fragment-scanner/jq.exe" ] && PATH="$HOME/fragment-scanner:$PATH"
for t in jq curl; do
    command -v "$t" > /dev/null || { echo "ABORT: $t is not installed"; exit 1; }
done

HOST=$(hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown)

# ---------- the xray binary ----------
# Termux installs into $PREFIX, which is why that path is checked too.
XRAY="${XRAY_BIN:-}"
if [ -z "$XRAY" ]; then
    for c in ./xray.exe ~/fragment-scanner/xray.exe \
             "${PREFIX:-/usr}/bin/xray" ./xray ~/fragment-scanner/xray \
             /usr/local/x-ui/bin/xray-linux-amd64 /usr/local/bin/xray /usr/bin/xray; do
        [ -x "$c" ] && { XRAY="$c"; break; }
    done
fi
[ -n "$XRAY" ] || { echo "ABORT: no xray binary. Run install.sh first, or set XRAY_BIN."; exit 1; }

WORK=$(mktemp -d)
PID=""
cleanup() { [ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$WORK"; }
# Interrupt has to exit, not just tidy up. A handler that only cleans leaves
# the script running with its working directory deleted, and every candidate
# after that point records as blocked -- a full table of zeroes that reads
# exactly like total DPI blocking and is really just a stray Ctrl-C.
trap cleanup EXIT
trap 'echo; echo "interrupted."; cleanup; exit 130' INT TERM

# ---------- pull the proxy outbound out of the working config ----------
# Both fragment styles are accepted. The classic one keeps its fragment in a
# separate freedom outbound and reaches it through sockopt.dialerProxy; the
# newer one keeps it in streamSettings.finalmask. Either way what gets reused
# is the proxy outbound with every trace of fragmentation removed, so the only
# thing varying between runs is the candidate under test.
PROXY=$(jq -c '[.outbounds[]
        | select(.tag=="proxy" or .protocol=="vless" or .protocol=="vmess" or .protocol=="trojan")][0]
        | del(.streamSettings.sockopt, .streamSettings.finalmask)' "$CFG" 2>/dev/null)
[ -n "$PROXY" ] && [ "$PROXY" != "null" ] || { echo "ABORT: no proxy outbound found in $CFG"; exit 1; }

SNI=$(echo  "$PROXY" | jq -r '.streamSettings.tlsSettings.serverName // "-"')
NET=$(echo  "$PROXY" | jq -r '.streamSettings.network // "-"')
ADDR=$(echo "$PROXY" | jq -r '.settings.vnext[0].address // .settings.address // .settings.servers[0].address // "-"')

echo "=== fragment scan ==="
echo "  network label : $LABEL"
echo "  running on    : $HOST"
echo "  server        : $ADDR"
echo "  sni           : $SNI"
echo "  transport     : $NET"
echo "  target        : $TARGET"
echo "  trials        : $TRIALS per candidate"
echo "  results       : $OUT"
echo

[ -s "$OUT" ] || echo "when,label,host,stage,packets,lengths,delays,ok,trials,handshake_s,kbps" > "$OUT"

# ---------- candidates ----------
# Ranges rather than fixed numbers, so xray picks randomly inside them and no
# two connections look identical.
PACKETS_LIST="tlshello 1-1 1-2 1-3 1-5"
LENGTHS_LIST="1-2 2-5 5-10 10-20 30-50 100-200"
DELAYS_LIST="0 1 1-2 5-10 10-20"

BEST_PACKETS=tlshello
BEST_LENGTHS=1-2
BEST_DELAYS=0

# A port check that works without ss or netstat, so this runs under Termux
# exactly as it does on a server.
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && { exec 3<&- 2>/dev/null; return 0; }; return 1; }

free_port() {
    local p
    while :; do
        p=$(( (RANDOM % 40000) + 20000 ))
        case "$p" in 10808|10809) continue ;; esac
        port_busy "$p" || { echo "$p"; return; }
    done
}

# measure <packets> <lengths> <delays> -> "ok handshake kbps"
measure() {
    local packets="$1" lengths="$2" delays="$3"
    local port; port=$(free_port)
    local fm='null'
    [ -n "$packets" ] && fm=$(jq -cn --arg pk "$packets" --arg ln "$lengths" --arg dl "$delays" \
        '{tcp:[{type:"fragment",settings:{packets:$pk,lengths:[$ln],delays:[$dl]}}]}')

    jq -n --argjson proxy "$PROXY" --argjson port "$port" --argjson fm "$fm" '{
        log: { loglevel: "error" },
        inbounds: [ { port: $port, listen: "127.0.0.1", protocol: "socks",
                      settings: { auth: "noauth", udp: false } } ],
        outbounds: [
          ( $proxy | .tag = "proxy"
                   | if $fm == null then . else .streamSettings.finalmask = $fm end ),
          { protocol: "freedom", tag: "direct" }
        ] }' > "$WORK/cfg.json" 2>/dev/null

    "$XRAY" run -c "$WORK/cfg.json" > "$WORK/xray.log" 2>&1 &
    PID=$!

    local i
    for i in $(seq 1 40); do
        port_busy "$port" && break
        kill -0 "$PID" 2>/dev/null || break
        sleep 0.2
    done
    if ! kill -0 "$PID" 2>/dev/null; then
        echo "0 0 0"; PID=""; return
    fi

    local ok=0 line code t s hs_list="" sp_list=""
    for i in $(seq 1 "$TRIALS"); do
        line=$(curl -s -o /dev/null --max-time "$TIMEOUT" \
                    --socks5-hostname "127.0.0.1:${port}" \
                    -w '%{http_code} %{time_appconnect} %{speed_download}' \
                    "$TARGET" 2>/dev/null)
        code=$(echo "$line" | awk '{print $1}')
        t=$(echo "$line" | awk '{print $2}')
        s=$(echo "$line" | awk '{print $3}')
        case "${code:-000}" in
            2*|3*) ok=$((ok+1)); hs_list="$hs_list ${t:-0}"; sp_list="$sp_list ${s:-0}" ;;
        esac
    done

    kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; PID=""

    if [ "$ok" -gt 0 ]; then
        # Median, not mean. On a one-core box a single slow sample drags an
        # average far enough to crown the wrong candidate, and the ranking
        # then reports a difference that is scheduling noise.
        local hs sp
        hs=$(echo $hs_list | tr ' ' '\n' | grep . | sort -n \
             | awk '{v[NR]=$1} END{print (NR%2)?v[(NR+1)/2]:(v[NR/2]+v[NR/2+1])/2}')
        sp=$(echo $sp_list | tr ' ' '\n' | grep . | sort -n \
             | awk '{v[NR]=$1} END{m=(NR%2)?v[(NR+1)/2]:(v[NR/2]+v[NR/2+1])/2; printf "%.0f", m/1024}')
        printf '%d %.3f %s\n' "$ok" "$hs" "$sp"
    else
        echo "0 0 0"
    fi
}

record() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ),$LABEL,$HOST,$1,$2,$3,$4,$5,$TRIALS,$6,$7" >> "$OUT"
}

SEEN_MIN=99
SEEN_MAX=-1

sweep() {
    local which="$1"; shift
    echo "--- sweeping $which ---"
    printf '  %-10s %-8s %-9s %-8s %s\n' "value" "ok/$TRIALS" "hs(s)" "kB/s" ""
    local v r ok hsv spv best_v="" best_ok=-1 best_hs=999
    for v in "$@"; do
        case "$which" in
            packets) r=$(measure "$v" "$BEST_LENGTHS" "$BEST_DELAYS"); record packets "$v" "$BEST_LENGTHS" "$BEST_DELAYS" ${r% *} "${r##* }" ;;
            lengths) r=$(measure "$BEST_PACKETS" "$v" "$BEST_DELAYS"); record lengths "$BEST_PACKETS" "$v" "$BEST_DELAYS" ${r% *} "${r##* }" ;;
            delays)  r=$(measure "$BEST_PACKETS" "$BEST_LENGTHS" "$v"); record delays "$BEST_PACKETS" "$BEST_LENGTHS" "$v" ${r% *} "${r##* }" ;;
        esac
        ok=$(echo "$r"  | awk '{print $1}')
        hsv=$(echo "$r" | awk '{print $2}')
        spv=$(echo "$r" | awk '{print $3}')
        printf '  %-10s %-8s %-9s %-8s %s\n' "$v" "$ok" "$hsv" "$spv" \
               "$([ "$ok" = "0" ] && echo BLOCKED)"
        [ "$ok" -lt "$SEEN_MIN" ] && SEEN_MIN="$ok"
        [ "$ok" -gt "$SEEN_MAX" ] && SEEN_MAX="$ok"
        if [ "$ok" -gt "$best_ok" ] || { [ "$ok" = "$best_ok" ] && awk -v a="$hsv" -v b="$best_hs" 'BEGIN{exit !(a<b)}'; }; then
            best_ok="$ok"; best_hs="$hsv"; best_v="$v"
        fi
    done
    echo "  -> $which = $best_v"
    echo
    case "$which" in
        packets) BEST_PACKETS="$best_v" ;;
        lengths) BEST_LENGTHS="$best_v" ;;
        delays)  BEST_DELAYS="$best_v" ;;
    esac
}

# ---------- baseline ----------
# If the unfragmented connection already works, everything below will look
# good and mean nothing. That is worth saying loudly rather than letting a
# clean-looking table be believed.
echo "--- baseline, no fragmentation ---"
BASE=$(measure "" "" "")
BASE_OK=$(echo "$BASE" | awk '{print $1}')
echo "  ok=$BASE_OK/$TRIALS  handshake=$(echo "$BASE" | awk '{print $2}')s"
record baseline none none none "$BASE_OK" "$(echo "$BASE" | awk '{print $2}')" "$(echo "$BASE" | awk '{print $3}')"
if [ "$BASE_OK" = "$TRIALS" ]; then
    echo
    echo "  WARNING: it already works unfragmented from here."
    echo "  Either this path is not filtered, or you are not on the network you"
    echo "  meant to test. Every result below will look fine and prove nothing."
fi
echo

sweep packets $PACKETS_LIST
sweep lengths $LENGTHS_LIST
sweep delays  $DELAYS_LIST

if [ "$MODE" = "full" ]; then
    echo "--- pairs, around the staged winner ---"
    for l in $LENGTHS_LIST; do
        for d in $DELAYS_LIST; do
            r=$(measure "$BEST_PACKETS" "$l" "$d")
            record pair "$BEST_PACKETS" "$l" "$d" "$(echo "$r" | awk '{print $1}')" \
                   "$(echo "$r" | awk '{print $2}')" "$(echo "$r" | awk '{print $3}')"
            printf '  %-9s %-9s ok=%-5s hs=%s\n' "$l" "$d" \
                   "$(echo "$r" | awk '{print $1}')" "$(echo "$r" | awk '{print $2}')"
        done
    done
    echo
fi

echo "=== result for: $LABEL ==="
echo

# When nothing failed, nothing was learned about which value is better. Saying
# so is the whole point -- otherwise the winner below looks like a discovery
# when it was decided by a few hundred milliseconds of scheduling noise.
if [ "$SEEN_MIN" = "$SEEN_MAX" ] && [ "$SEEN_MIN" = "$TRIALS" ]; then
    echo "  NO DISCRIMINATION on this network: every candidate passed $TRIALS/$TRIALS."
    if [ "$BASE_OK" = "0" ]; then
        echo "  Fragmentation is doing real work here -- unfragmented scored 0/$TRIALS --"
        echo "  but which values you use makes no measurable difference on this path."
        echo "  Take the fastest, and re-run where it actually bites: a mobile carrier."
    else
        echo "  Unfragmented also passed, so this path is not filtered at all and none"
        echo "  of these numbers mean anything. Run it from inside the filtered network."
    fi
    echo
elif [ "$SEEN_MAX" = "0" ]; then
    echo "  EVERY candidate failed, including the baseline. That is not a fragment"
    echo "  result -- either the endpoint in $CFG is down, or something is blocking"
    echo "  it wholesale, or xray refused the settings. Check by hand before trusting"
    echo "  anything above:"
    echo "    ./xray run -c /tmp/… and read the error, then confirm the config works."
    echo
fi

jq -cn --arg pk "$BEST_PACKETS" --arg ln "$BEST_LENGTHS" --arg dl "$BEST_DELAYS" \
    '{tcp:[{type:"fragment",settings:{packets:$pk,lengths:[$ln],delays:[$dl]}}]}'
echo
echo "  Panel Settings -> Sub Formats -> Final Mask:"
echo "    Type      Fragment"
echo "    Packets   $BEST_PACKETS"
echo "    Lengths   #1  $BEST_LENGTHS"
echo "    Delays    #1  $BEST_DELAYS"
echo "    Max Split (leave empty)"
echo
echo "  appended to $OUT -- run this on each network with its own --label,"
echo "  then compare. One operator's answer is not automatically another's."
echo "SCAN_DONE"
