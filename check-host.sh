#!/bin/bash
# Find a Cloudflare-fronted host this network will actually talk to.
#
#   check-host.sh [more.example.com ...]
#
# scan-ip.sh needs one host it can fetch through a pinned address. The default
# is speed.cloudflare.com, and some networks block that name outright -- which
# looks identical to every address being dead: connections open on 443 and no
# TLS request ever completes. This tells the two apart by trying the same
# request against several names through the same addresses.
#
# Run it on the network that is failing. Whatever comes back OK goes in
# settings.conf as `host`, with the matching `down_path`.

set -uo pipefail

# A few Cloudflare addresses that are almost always up. Not a scan -- these are
# only carriers for the hostname being tested.
IPS="104.16.132.229 172.64.80.9 188.114.97.3"

# name|path to fetch|path that takes a byte count, or - if it has none
CANDIDATES="speed.cloudflare.com|/__down?bytes=100000|/__down?bytes=
cp.cloudflare.com|/|-
www.cloudflare.com|/|-
developers.cloudflare.com|/|-
blog.cloudflare.com|/|-
discord.com|/|-
www.zoomit.ir|/|-"

for extra in "$@"; do CANDIDATES="${CANDIDATES}
${extra}|/|-"; done

echo "=== which hosts answer through a pinned Cloudflare address ==="
echo "  (run this on the network that is failing)"
echo
printf '  %-30s %-8s %-10s %s\n' "host" "http" "kB/s" "note"

BEST=""
while IFS='|' read -r host path bytespath; do
    [ -n "$host" ] || continue
    ok=0; code=""; speed=0
    for ip in $IPS; do
        out=$(curl -k -s -o /dev/null --max-time 12 \
                   -H "Host: $host" --resolve "${host}:443:${ip}" \
                   -w '%{http_code} %{speed_download}' \
                   "https://${host}${path}" 2>/dev/null)
        code=$(echo "$out" | awk '{print $1}')
        case "${code:-000}" in
            2*|3*) ok=$((ok+1))
                   speed=$(awk -v a="$speed" -v b="$(echo "$out" | awk '{print $2}')" 'BEGIN{print a+b}') ;;
        esac
    done
    if [ "$ok" -gt 0 ]; then
        kb=$(awk -v s="$speed" -v n="$ok" 'BEGIN{printf "%.0f", s/n/1024}')
        printf '  %-30s %-8s %-10s %s\n' "$host" "$code" "$kb" "ok on $ok of 3"
        [ -z "$BEST" ] && [ "$bytespath" != "-" ] && BEST="$host|$bytespath"
        [ -z "$BEST" ] && BEST="$host|$path"
    else
        printf '  %-30s %-8s %-10s %s\n' "$host" "-" "-" "no answer"
    fi
done <<EOF
$CANDIDATES
EOF

echo
if [ -n "$BEST" ]; then
    h=${BEST%%|*}; p=${BEST#*|}
    echo "=== put this in settings.conf ==="
    echo "  host      = $h"
    echo "  down_path = $p"
    echo
    case "$p" in
        *bytes=) echo "  That path takes a byte count, so size in settings.conf still applies." ;;
        *) echo "  That path serves a fixed page, so size is ignored and the speed"
           echo "  figures will be rougher. Good enough to rank addresses against"
           echo "  each other, which is all the scan needs." ;;
    esac
else
    echo "Nothing answered at all. That is not about the host name:"
    echo "  - check this machine has working internet right now"
    echo "  - if it does, the whole Cloudflare range may be blocked on this network"
    echo "    on 443, which no choice of host can work around"
fi
echo "HOSTCHECK_DONE"
