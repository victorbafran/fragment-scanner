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

RES=$(mktemp)
trap 'rm -f "$RES"' EXIT

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
        note="ok on $ok of 3"
        # A host can answer perfectly and still be useless here. cp.cloudflare
        # .com returns 204 with no body, so there is nothing to time -- picking
        # it would give a scan where every address reads 0 kB/s.
        [ "$kb" = "0" ] && note="$note, but sends no data -- cannot measure speed"
        printf '  %-30s %-8s %-10s %s\n' "$host" "$code" "$kb" "$note"
        [ "$kb" = "0" ] || echo "$kb|$host|$bytespath|$path" >> "$RES"
    else
        printf '  %-30s %-8s %-10s %s\n' "$host" "-" "-" "no answer"
    fi
done <<EOF
$CANDIDATES
EOF

echo
if [ -s "$RES" ]; then
    # Fastest that actually sent something, and a byte-count path wins a tie
    # since it lets the scan control how much it fetches.
    BEST=$(sort -t'|' -k1,1nr "$RES" | awk -F'|' '$3!="-"{print; exit}')
    [ -n "$BEST" ] || BEST=$(sort -t'|' -k1,1nr "$RES" | head -1)
    kb=$(echo "$BEST"   | cut -d'|' -f1)
    h=$(echo "$BEST"    | cut -d'|' -f2)
    bp=$(echo "$BEST"   | cut -d'|' -f3)
    p=$(echo "$BEST"    | cut -d'|' -f4)
    [ "$bp" != "-" ] && p="$bp"
    echo "=== put this in settings.conf ==="
    echo "  host      = $h"
    echo "  down_path = $p"
    case "$p" in
        *bytes=) echo "  up_path   = /__up" ;;
        *)       echo "  up_path   = -"
                 echo "  measure   = download" ;;
    esac
    echo
    case "$p" in
        *bytes=) echo "  Chosen because it can be asked for an exact size, which is what makes"
                 echo "  one address comparable with the next, and it accepts uploads too."
                 echo "  It takes a byte count, so size in settings.conf still applies." ;;
        *) echo "  Chosen because it was the fastest of the ones that returned data"
           echo "  (${kb} kB/s) and nothing better was reachable."
           echo "  It serves a fixed page, so size is ignored and the figures are"
           echo "  rougher -- fine for ranking addresses against each other, which"
           echo "  is all the scan needs. It also has nowhere to upload to, which"
           echo "  is why measure has to be download." ;;
    esac
else
    echo "Nothing usable. Either nothing answered, or the only hosts that did"
    echo "send no body and cannot be timed. If some answered:"
    echo "  - pass another Cloudflare-fronted domain as an argument to try it"
    echo "If none did:"
    echo "  - check this machine has working internet right now"
    echo "  - if it does, the whole Cloudflare range may be blocked on this network"
    echo "    on 443, which no choice of host can work around"
fi
echo "HOSTCHECK_DONE"
