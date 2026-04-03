# Igareck Isolated MVP

This runbook builds the simplest isolated benchmark from public community white-list configs.

Goals:

- do not touch Android runtime or UI
- do not touch the current macOS VPN session
- do not depend on Odin One owner profiles or the Finland server
- fetch public configs from `igareck/vpn-configs-for-russia`
- filter them into the minimal reproducible scope
- test them through a local loopback SOCKS proxy only

Current isolated MVP scope:

- public `vless://` configs only
- `security=reality|tls`
- `type=tcp|ws|grpc`
- local smoke runner through `sing-box`

Why this scope first:

- it matches the most common white-list shape in the community repo
- it already covers the most practical public transports we see there
- it still avoids the next experimental zone, `xhttp`
- it gives a clean external benchmark before we move anything into Odin One Android/UI

## One-command run

```bash
zsh apps/desktop/scripts/reality-whitelist-igareck-isolated-mvp.sh \
  --engine sing-box \
  --limit 12 \
  --max-per-sni 1 \
  --max-per-transport 4 \
  --output-dir /tmp/odin-one-igareck-isolated-mvp-live
```

Outputs:

- `/tmp/odin-one-igareck-isolated-mvp-live/raw/` with fetched source files
- `/tmp/odin-one-igareck-isolated-mvp-live/filtered-subscription.txt`
- `/tmp/odin-one-igareck-isolated-mvp-live/candidates.json`
- `/tmp/odin-one-igareck-isolated-mvp-live/summary.md`
- `/tmp/odin-one-igareck-isolated-mvp-live/smoke/results.json`
- `/tmp/odin-one-igareck-isolated-mvp-live/smoke/summary.md`

## What it really proves

This benchmark answers:

- which public white-list `VLESS` configs in the current supported scope can be reached from this Mac
- which repeated `SNI` surfaces are worth another pass
- whether the local isolated client path itself works without disconnecting the current VPN

It does not yet answer:

- whether a config works from a Russian white-list-only mobile network
- whether `grpc`, `ws`, `xhttp`, or `hysteria2` are stronger in that environment
- whether Odin One should productize the exact same config shape

## Important limitation

This isolated MVP is an external benchmark, not a product path.

If a public config passes here, it only means:

- the config is reachable from this current Mac/network
- the local loopback SOCKS test worked

It still needs separate field validation before we treat it as a realistic Russian white-list bypass candidate.

## Building the next queue from live results

After a smoke run, build the next queue around families that already showed at least one pass:

```bash
zsh apps/desktop/scripts/reality-whitelist-igareck-next-queue.sh \
  --raw-dir /tmp/odin-one-igareck-isolated-mvp-live/raw \
  --results /tmp/odin-one-igareck-isolated-mvp-live/smoke/results.json \
  --results /tmp/odin-one-igareck-next-queue-live/smoke/results.json \
  --limit 8 \
  --max-per-sni 1 \
  --max-per-transport 4 \
  --engine sing-box \
  --output-dir /tmp/odin-one-igareck-next-queue-live
```

Outputs:

- `/tmp/odin-one-igareck-next-queue-live/filtered-subscription.txt`
- `/tmp/odin-one-igareck-next-queue-live/candidates.json`
- `/tmp/odin-one-igareck-next-queue-live/summary.md`
- `/tmp/odin-one-igareck-next-queue-live/smoke/results.json`

What this step does:

- accepts one or more previous `results.json`
- excludes exact configs already tested in any of them
- derives simple server and host families
- boosts untested candidates from families that already had a pass
- demotes families with only failures

## Building an operator shortlist

Once you already have a few smoke waves, export only the passed candidates into a reusable shortlist:

```bash
zsh apps/desktop/scripts/reality-whitelist-igareck-shortlist.sh \
  --results /tmp/odin-one-igareck-isolated-mvp-live-v3/smoke/results.json \
  --results /tmp/odin-one-igareck-next-queue-live/smoke/results.json \
  --results /tmp/odin-one-igareck-next-queue-cumulative/smoke/results.json \
  --limit 12 \
  --output-dir /tmp/odin-one-igareck-shortlist-live
```

Outputs:

- `/tmp/odin-one-igareck-shortlist-live/shortlist.json`
- `/tmp/odin-one-igareck-shortlist-live/subscription.txt`
- `/tmp/odin-one-igareck-shortlist-live/summary.md`
