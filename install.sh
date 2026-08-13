#!/bin/sh
# One-command install, on a server or on Android under Termux.
#
#   curl -fsSL https://raw.githubusercontent.com/victorbafran/fragment-scanner/main/install.sh | sh
#
# Installs into ~/fragment-scanner: the scanner itself plus a matching xray
# binary, since the machine you want to measure from usually has none.
# Re-running it is safe and just refreshes both.

set -eu

REPO=https://raw.githubusercontent.com/victorbafran/fragment-scanner/main
DIR="$HOME/fragment-scanner"

say()  { printf '  %s\n' "$1"; }
fail() { printf 'ABORT: %s\n' "$1"; exit 1; }

echo "=== fragment-scanner install ==="

# ---------- packages ----------
# Termux and Debian want different package managers, and neither has the
# other's names for these.
if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX}/bin" ]; then
    PLATFORM=termux
    for p in jq curl unzip; do
        command -v "$p" > /dev/null 2>&1 || pkg install -y "$p" > /dev/null 2>&1 || true
    done
else
    PLATFORM=linux
    if ! command -v jq > /dev/null 2>&1 || ! command -v unzip > /dev/null 2>&1; then
        if command -v apt-get > /dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get -yq update  > /dev/null 2>&1 || true
            DEBIAN_FRONTEND=noninteractive apt-get -yq install jq curl unzip > /dev/null 2>&1 || true
        fi
    fi
fi
say "platform : $PLATFORM"

for p in jq curl; do
    command -v "$p" > /dev/null 2>&1 || fail "$p is missing and could not be installed"
done

mkdir -p "$DIR"

# ---------- xray ----------
# Pinned, not "latest". Xray's latest *stable* release is v26.3.27, which
# predates the plural lengths/delays form of the fragment mask. 3x-ui emits
# exactly that form, and a core without it refuses to start with
#
#   infra/conf: LengthMin can't be 0
#
# which surfaces as every candidate looking blocked -- a scan full of zeroes
# that reads like DPI and is really a version mismatch. Measured on a real
# box: identical settings, 0/3 on 26.3.27 and 204 OK on 26.7.28. Pin to a
# core that has the feature, and match what the panel itself runs.
XRAY_VERSION="${XRAY_VERSION:-v26.7.28}"

# The download name differs per architecture, and getting it wrong produces a
# binary that simply will not execute, with no useful error.
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)   ASSET=Xray-linux-64.zip    ;;
    aarch64|arm64)  ASSET=Xray-linux-arm64-v8a.zip ;;
    armv7l|armv7)   ASSET=Xray-linux-arm32-v7a.zip ;;
    *) fail "unsupported architecture: $ARCH" ;;
esac
say "arch     : $ARCH -> $ASSET"
say "xray ver : $XRAY_VERSION (pinned)"

if [ ! -x "$DIR/xray" ] || ! "$DIR/xray" version 2>/dev/null | head -1 | grep -q "${XRAY_VERSION#v}"; then
    say "fetching xray..."
    curl -fsSL -o "$DIR/xray.zip" \
        "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/$ASSET" \
        || fail "could not download xray ${XRAY_VERSION}"
    unzip -oq "$DIR/xray.zip" xray -d "$DIR" || fail "could not unpack xray"
    rm -f "$DIR/xray.zip"
    chmod +x "$DIR/xray"
fi
say "xray     : $("$DIR/xray" version 2>/dev/null | head -1 || echo installed)"

# ---------- the scanner ----------
curl -fsSL -o "$DIR/scan.sh" "$REPO/scan.sh" || fail "could not download scan.sh"
chmod +x "$DIR/scan.sh"

cat <<EOF

installed to $DIR

next:
  1. put a config that already works on this network in $DIR/working.json
  2. run it, naming the network you are on:

       cd $DIR && ./scan.sh working.json --label irancell

Run it once per network -- mobile carrier, home line, datacenter -- with a
different label each time. Results append to results.csv so they can be
compared afterwards. Running it outside the filtered network measures nothing.
EOF
