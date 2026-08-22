# fragment-scanner

[راهنمای فارسی](README_FA.md)

Finds the TLS fragment parameters that actually get through the DPI on a given
network, and prints them in the exact shape a 3x-ui panel wants.

Fragmentation settings get copied between people as folklore — one config's
numbers get pasted into another's and nobody measures whether they help. The
numbers are network-specific and they expire. This measures them instead.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/victorbafran/fragment-scanner/main/install.sh | sh
```

Works on a Linux server and on Android under Termux. It brings its own `xray`
binary, because the machine you want to measure from usually has none.

## Use

Put a config that already works on this network in `working.json`, then:

```sh
cd ~/fragment-scanner && ./scan.sh working.json --label irancell
```

Options: `--trials N` (repeats per candidate, default 5), `--target URL`,
`--out FILE`, `--full` (also test length/delay pairs).

Output ends with the value to paste into
**Panel Settings → Sub Formats → Final Mask**, plus each field spelled out for
the form.

## Finding a clean Cloudflare address

```sh
cfip
```

Settings live in `settings.conf` and the ranges in `ranges.txt`, both plain
text, both yours, neither overwritten on reinstall. Anything on the command
line still wins over the file.

By default it measures the line first and sets the bar at a share of what that
line actually manages. A fixed threshold is meaningless without it: 200 kB/s is
a good result on one connection and a failure on another, which is how a scan
ends up reporting nothing on a slow line and looking broken. `--share` moves
the fraction, `--min-speed` and `--min-upload` replace it with numbers of your
own, in kilobytes per second.

Samples random addresses from Cloudflare's ranges, keeps the ones that answer,
drops the ones that do not actually front the test host, and measures download
(and with `--upload`, upload) on what is left. Prints the fastest, and appends
everything to `ips.csv`.

`--ranges` takes your own CIDRs, comma-separated or as a file. `--host` picks a
different Cloudflare-fronted host to measure against. `--max-latency` and
`--min-speed` filter. `--via <config>` measures through your own tunnel instead
of directly, which is worth it when your domain is *not* filtered.

The address is pinned with `curl --resolve` while the hostname stays put, so
the handshake and the Host header still name the real site and only the edge
changes — same site, different door. Ping is not used: ICMP is deprioritised or
dropped on many Iranian paths, and Cloudflare is anycast, so a ping time
describes distance to some edge rather than throughput. The TCP handshake to
443 is timed instead.

Do not point this at a filtered domain. The block is on the name, not the
address, so every candidate fails identically and the scan separates nothing.
Find the address against an unfiltered host, then apply it to your real config.

The method follows [CFScanner](https://github.com/MortezaBashsiz/CFScanner),
which is the tool this community already trusts for it.

## Read this before trusting a result

**It must run inside the filtered network.** Run it anywhere else and there is
no DPI on the path, so every candidate succeeds and the table is noise wearing
a lab coat. The script tests an unfragmented baseline first and warns loudly
when that already works, which is the signature of running it in the wrong
place.

**One network's answer is not another's.** A datacenter, a home line and a
mobile carrier are not filtered the same way. Run it once per network with its
own `--label`; results append to `results.csv` so they can be compared. Testing
on Irancell and MCI usually means a phone with each SIM, running Termux.

**Answers expire.** Filtering changes. A setting that won last month is not
automatically the one that wins today, so re-run it when things degrade rather
than assuming the config went stale for some other reason.

**The endpoint has to be known-good.** If the server or inbound in
`working.json` is broken, every candidate fails and the tool cannot tell you
which of the two is at fault. Confirm the config works somewhere first.

## What it measures

For each candidate it starts a throwaway xray with a SOCKS inbound on a random
high port, then makes several requests through it and records three things:
whether it connected, how long the TLS handshake took, and how fast the
transfer ran.

Candidates are ranked on success rate first, then on the faster handshake.
Blocking is probabilistic, so a single success proves nothing — that is why
every candidate is repeated. Speed is reported too, because very small
fragments usually get through but cost handshake time, and the right answer is
a trade-off rather than an outright winner.

The search is staged — `packets`, then `lengths`, then `delays` — because the
full cross product is hundreds of runs. `--full` sweeps length/delay pairs
afterwards for the case where two parameters interact.

It never binds ports 10808 or 10809. Those belong to whatever client is already
running on the machine, and taking them cuts the network out from under you
mid-test.

## Nothing here is configuration

No addresses, domains, keys or user ids belong in this repository — it is
public. `working.json` is yours, stays on your machine, and is gitignored.
