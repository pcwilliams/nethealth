# NetHealth — Internet Health Monitor (macOS)

A beautiful, resizable macOS window that shows the live health of **every
network connection the Mac has** — one stacked panel per link (e.g. Ethernet →
Starlink and Wi-Fi → fibre at the same time), each with a flowing **aurora
latency ribbon** that scrolls smoothly through time. Each link's own router, the
Starlink dish (where present), and a public anchor (Cloudflare) are probed ~once
per second *over that interface*, and a periodic **bandwidth test** measures
download/upload per link. Colour shifts green→amber→red as a link degrades.

## Living documents — keep these in sync

This project carries the four standard living docs. **Update them whenever the
behaviour or design changes** (the owner asked for this explicitly):

- **CLAUDE.md** (this file) — developer reference / decisions / gotchas
- **README.md** — user-facing overview, features, build & run
- **architecture.html** — interactive Mermaid.js diagrams (shared dark theme, CDN)
- **tutorial.html** — conversational, prompt-by-prompt build narrative

## Overview

- **Platform:** macOS 14+ (SwiftUI, MVVM, Swift 5)
- **Bundle ID:** `com.pwilliams.NetHealth` · **Team:** `L7GB763YG3`
- **Window:** `.hiddenTitleBar`, content-size resizable, min 780 wide × (300 per connection + 60) tall
- Sandboxed with `com.apple.security.network.client`.

## Targets (verified addresses)

| Name | Host | Probe ports | What it tells you |
|------|------|-------------|-------------------|
| Router | *that link's gateway* | 80, 443, 9000 | LAN gateway — the local hop. Read per interface from the routing table (`192.168.1.1` on Starlink, `192.168.108.1` on the fiber LAN, etc.) |
| Dish | `192.168.100.1` | 80, 443 | Starlink dish (user terminal), reachable even in Bypass Mode. **Optional** — omitted on non-Starlink networks |
| Cloudflare | `1.1.1.1` | 443, 80 | Public-internet anchor |

These are built **per connection** by `ConnectionDiscovery.targets(for:)` — edit
that to change hosts/ports.

### Multiple connections (one panel each)

The owner's Mac has Ethernet → Starlink (`en0`, primary) **and** Wi-Fi → 5 Gb/s
fibre (`en1`) live at once. macOS keeps one IPv4 default route per interface:
the primary is unscoped, the others carry `RTF_IFSCOPE` (`netstat -rn` shows the
`I` flag) and are only used by sockets *bound* to that interface.

- **Discovery:** `Gateway.defaultRoutes()` walks `sysctl(NET_RT_DUMP)` and returns
  every default route with its `rtm_index`, interface name, gateway, and
  `isPrimary` (no `RTF_IFSCOPE`). `ConnectionDiscovery.discover(path:)` merges
  that with `NWPathMonitor`'s `availableInterfaces` (for Wi-Fi/Ethernet type and
  the `NWInterface` handle) and skips tunnels (`utun`, `ipsec`, `.other`…).
  The view model re-discovers on every path update and every 10 ticks;
  `NetworkConnection` objects are keyed by BSD name so history survives, and a
  changed gateway on the same interface rebuilds that link's targets.
- **Pinned probes:** `TCPPinger`/`ICMPPinger` take `interfaceIndex` and
  `setsockopt(IPPROTO_IP, IP_BOUND_IF)` before connecting — sandbox-safe.
  Verified: Cloudflare reads ~25 ms via Starlink vs ~10 ms via fibre in the
  same tick.
- **Dish is per-link:** every connection gets the optional dish target; it only
  answers over the Starlink link (which is then badged `STARLINK`). A
  never-answered optional target is probed every second for 15 s, then only
  every 15 s (`NetHealthViewModel.shouldProbe`), so we don't keep firing SYNs
  at `192.168.100.1` through the fibre router.

### Bandwidth test (SpeedTester)

- Cloudflare's endpoints: `GET https://speed.cloudflare.com/__down?bytes=N` and
  `POST /__up`. **Requests over 100 MB get HTTP 403**, and after a burst of
  testing Cloudflare started answering **HTTP 429 to any single `__down` of
  ≥10 MB** from that IP (5 MB still 200; 12 back-to-back 5 MB requests on one
  keep-alive connection all 200). So each download stream loops **4 MB GETs**
  (`downloadRequestBytes`) over one keep-alive connection, parsing
  `Content-Length` to know when to ask for the next; uploads split the cap
  across streams as one POST each.
- **URLSession can't pin an interface**, so it's hand-rolled HTTP/1.1 over
  `NWConnection` with TLS and `params.requiredInterface = NWInterface`.
  `.waiting` is treated as failure (the pinned link can't reach the host).
- **6 parallel streams** — one stream measured only ~170 Mbps on the fibre.
- Each direction stops at the first of: 3 s after the first byte, the byte cap
  (**40 MB ↓ / 15 MB ↑** — cut from 120/40 at the owner's request), all streams
  done, or 4 s with no data. Rate skips the
  first 25 % (≤0.5 s) after first byte to exclude slow start. Upload bytes are
  counted on `contentProcessed`, and the end time is stretched to the server's
  response (it only replies once it has the whole body), limiting the
  socket-buffer overestimate.
- Connections are tested **one at a time**, download then upload. The UI
  schedule is `SpeedTestInterval` (default **every 10 min** — every minute
  drew 429s, and 5 → 10 min halves the data; persisted in
  UserDefaults key `speedTestInterval`); first test runs 5 s after launch.
  If no links (or no `NWPath`, needed for the `NWInterface` that pins the
  test) are known yet when it's due, it retries every 5 s rather than
  waiting a full interval. The Bandwidth card shows the wall-clock time of
  the latest test (`tested 07:16:50`, with the date once it's not today)
  alongside the relative "18s ago · next 9m".
- **HTTP 429 happened** at once-a-minute (seen live, it cleared within minutes).
  `NetworkConnection.record` backs that link off 5 → 10 → 20 → 30 min; a clean
  result resets it. The card shows the last good reading dimmed.
- Test spans are stored as `SpeedWindow`s and shaded on the graph: a free
  latency-under-load (bufferbloat) view — Wi-Fi Cloudflare RTT went ~10 → 100+ ms
  during a download.
- Validated against `curl --interface en1` ×6 parallel: app and curl agree
  (110–170 Mbps on the Wi-Fi hop — the Mac's Wi-Fi, not the 5 Gb/s fibre, is
  the bottleneck).

### Local link rate (LinkStatus)

The owner asked about a bandwidth test *to the router*. Not practical: both
routers only serve a ~5 KB admin page (no speed endpoint, no iperf3), so a
loop would measure their embedded web server, not the link — and hammering a
router's admin UI is the same kind of risk we avoid with the dish. A real LAN
throughput test needs iperf3 at the far end.

Instead `LinkReader.read(interfaceName:kind:)` asks the OS, sending nothing:

- **Wi-Fi:** `CWWiFiClient.shared().interface(withName:)` → `transmitRate()`,
  `wlanChannel()` (band, number, width), `rssiValue()`, `noiseMeasurement()`,
  `activePHYMode()`. Works under the sandbox with no entitlement; only `ssid()`
  needs Location permission (returns nil) and we don't use it. `import CoreWLAN`
  autolinks — no pbxproj framework entry.
- **Ethernet:** `getifaddrs` `AF_LINK` entry's `if_data.ifi_baudrate`
  (`1000000000` for 1000baseT). It's meaningless for Wi-Fi (reads ~48 M).
- `NetworkConnection.link` is read on creation, on info change, and every 5
  ticks. `isLinkLimited` = last good ↓ ≥ 60 % of the link rate (Wi-Fi rarely
  delivers more than 60–70 % of PHY rate).
- The panel header chip (`ConnectionPanel.linkChip`) shows `link.summary`, turns
  amber when Wi-Fi is on 2.4 GHz or `isLinkLimited`, and `.help` shows
  `link.details` (mode, width, noise, SNR, a 2.4 GHz hint).
- **Finding (2026-10-19):** the Mac's Wi-Fi was on **2.4 GHz ch 11, 20 MHz,
  ~137–172 Mbps PHY, −66 dBm** — exactly why the 5 Gb/s fibre measured
  ~140 Mbps. Joining the router's 5/6 GHz band is the fix, not the app.

### Works on any network, not just Starlink

NetHealth originally hard-coded the Starlink home setup. It now adapts to
whatever LAN it's on:

- **Router = the real default gateway.** `Gateway.defaultIPv4()` reads the
  kernel routing table via `sysctl(NET_RT_DUMP)` — the in-process equivalent of
  `route -n get default` — and points the Router target at the actual gateway
  (fiber, cable, hotspot, …), falling back to `192.168.1.1` only if no default
  route exists. This is a routing-table *read*, so it works under the App
  Sandbox with no extra entitlement. `--selftest` prints the detected gateway.
- **Optional targets omit cleanly.** `PingTarget.optional` marks a target (the
  dish) that only exists on some networks. An optional target that has **never**
  answered is treated as absent: omitted from the cards, the graph ribbons, and
  the overall-health tint, so a missing dish can't paint the window "Offline".
  Once it answers at least once (`TargetHealth.everReachable` latches), it stays
  visible — including showing a genuine outage in red. The card row animates the
  insert/removal. `visibleHealths` is the present-only list the UI iterates.
- **Connection-refused counts as reachable.** A bare gateway with no open web
  port (common on fiber routers) replies to the TCP probe with a RST. That's a
  *complete* round trip from a host that's up, so `TCPPinger` now treats
  `ECONNREFUSED` as a valid latency sample (real SYN→RST RTT) rather than
  "unreachable" — which is what lets the local hop read healthy regardless of
  open ports. Genuine `EHOSTUNREACH`/timeouts still fail (keeping an absent dish
  absent).

> **Do not poke the dish's API.** The dish's gRPC management port `9200` is
> deliberately **not** in its probe list. We only do a gentle TCP-connect on the
> web ports (80/443). Around 2026-05-30 the dish appeared to crash while being
> probed once a second, and the gRPC `Handle` endpoint that serves telemetry is
> the *same* one that accepts `reboot`/`stow` — so we stay off it entirely. The
> community `starlink-grpc-tools` likewise warns about over-frequent polling and
> ships explicit "dish reboot detected" handling. See Lessons below.

## How latency is measured — and the ICMP/sandbox finding

The natural choice was ICMP echo (real ping). **It does not work under the macOS
App Sandbox:** you *can* create an unprivileged `SOCK_DGRAM`/`IPPROTO_ICMP`
socket and `sendto` on it, but the kernel **denies the inbound echo reply with
`EPERM` (errno 1, "Operation not permitted")**. Confirmed with `--netdiag`:

```
ICMP socket(): ok fd=3
raw: sendto -> 16
raw: recv -> -1 errno=1 (Operation not permitted)   ← sandbox blocks the reply
TCP connect(1.1.1.1:443): ok
TCPPinger.ping(1.1.1.1:443): 30.74 ms               ← TCP works perfectly
```

So latency is measured by **TCP connect time** — the SYN→SYN/ACK round trip to
the first reachable port, a close proxy for ICMP RTT and what `tcping`-style
tools use. `ICMPPinger` is kept and tried first; the moment it hits `EPERM` it is
disabled for the session and everything falls through to `TCPPinger`. (Run the
app **un-sandboxed** and real ICMP would light up automatically.)

**The active method is now visible.** `PingService.measure` returns a
`Reading(rtt, method)` where `method` is `.icmp` or `.tcp`; the winning method
flows into each `PingSample` and is surfaced as a small badge on every
`StatCard` (muted `TCP`, or a green `ICMP` when real echo works). `--selftest`
prints it too (`… 22.8 ms  via TCP`). This makes the sandbox-vs-ICMP state
self-evident at a glance instead of needing `--netdiag` — handy because the
firewall "accept incoming connections" prompt does **not** change it (that's a
separate mechanism from the sandbox EPERM on the echo reply).

## Architecture

```
NetHealth/
├── NetHealthApp.swift        @main; WindowGroup; `--selftest` / `--speedtest` / `--watch` / `--netdiag` CLI modes
├── ContentView.swift         header (schedule picker, Test now, data used) + stacked ConnectionPanels + ambient bg
├── ConnectionPanel.swift     one link: header (Wi-Fi/Ethernet, PRIMARY/STARLINK badges, IPs) + graph + fixed-slot card row (CardSlot)
├── BandwidthCard.swift       ↓/↑ Mbps (live while testing), sparkline history, tested-at timestamp, next/last test, 429 status
├── Models.swift              ProbeMethod, PingSample(+method), HealthState, PingTarget(+ports,+optional), TargetHealth (stats+method+everReachable/isPresent)
├── NetworkConnection.swift   ConnectionInfo, ConnectionDiscovery (routes + NWPath → links, per-link targets), SpeedPhase/SpeedResult/SpeedWindow, NetworkConnection (@MainActor per-link state + 429 backoff)
├── Gateway.swift             per-interface default routes via sysctl(NET_RT_DUMP) (+RTF_IFSCOPE → primary); local IPv4 via getifaddrs
├── ICMPPinger.swift          unprivileged ICMP echo — auto-disables on sandbox EPERM; optional IP_BOUND_IF
├── TCPPinger.swift           TCP connect-time probe (the actual measurement path); ECONNREFUSED = reachable; IP_BOUND_IF pinning
├── PingService.swift         actor; ICMP-first, sticky fall-through to TCP; returns Reading(rtt, method); takes interfaceIndex
├── LinkStatus.swift          LinkStatus + LinkReader: Wi-Fi rate/band/channel/RSSI via CoreWLAN, Ethernet speed via if_data.ifi_baudrate
├── SpeedTester.swift         multi-stream HTTPS ↓/↑ against speed.cloudflare.com over NWConnection(requiredInterface)
├── NetHealthViewModel.swift  @MainActor; NWPathMonitor → connections; 1 Hz probe loop over connection × target; speed-test scheduler
├── AuroraGraphView.swift     Canvas + TimelineView; time-scrolling gradient ribbons + shaded speed-test windows (per connection)
└── StatCard.swift            per-target ms / min·avg·max / jitter / loss + ICMP|TCP method badge
```

`HealthState` buckets latency: <20 excellent, <40 good, <80 fair, <150 poor,
else bad; ≥50% recent loss forces bad; unreachable → offline. The worst current
state drives each panel's border tint; the worst across all connections drives
the ambient background tint.

### The graph — smooth time-scrolling (AuroraGraphView)

The ribbon is the heart of the app and went through real iteration. Key decisions:

- **Position by real age, not index.** Each `PingSample` carries a wall-clock
  `date`. A point's X is `width − (now − date)/window · width` (window = 90 s).
  Driven by a 60 Hz `TimelineView` clock, the whole ribbon glides continuously —
  it *scrolls through time* rather than compressing as history grows (the first
  index-based version stretched all samples across the width and compressed).
- **Pin the leading edge.** Positioning purely by age makes the newest point
  drift left for a second and then a fresh point pops in at the right edge — a
  ~7 px right-then-left **sawtooth** every update. Fix: append a synthetic point
  that holds the latest value out to `x = width`, so the trace only ever scrolls
  smoothly left; new readings change the edge value, not its X.
- **Eased Y-axis with hysteresis.** The vertical scale auto-fits to a "nice"
  bucket (50/100/150/250/400/600/1000 ms) but **eases** toward it (≈150 ms time
  constant) and uses hysteresis (grow at once, shrink only when well clear) so a
  latency hovering on a threshold can't flip-flop the scale.
- **RibbonAnimator** is a small reference type held in `@State`; the Canvas draw
  closure mutates its `displayScale`/`scaleBucket` each frame without tripping
  SwiftUI value-state invalidation (redraws come from the TimelineView).
- Catmull-Rom smoothing for the flowing curve; vertical gradient fill + blurred
  glow underlay; faint scrolling time guides (`-30s`, `-60s`, …).

## Build, run & test

```bash
# build
xcodebuild -project NetHealth.xcodeproj -scheme NetHealth -destination 'platform=macOS' build

# build + launch the window (Debug)
./run-macos.sh

# headless networking self-test (measures each target once, prints RTT, exits
# non-zero only if everything is unreachable) — no GUI needed
./run-macos.sh Debug --selftest

# per-connection bandwidth test (download + upload, prints Mbps / MB / seconds)
./run-macos.sh Debug --speedtest

# the GUI's concurrent 1 Hz probe loop, one log line per tick (default 15 s)
./run-macos.sh Debug --watch 30

# raw socket diagnostics (errno at each step)
build/Build/Products/Debug/NetHealth.app/Contents/MacOS/NetHealth --netdiag

# Release build → install into /Applications (falls back to ~/Applications)
./deploy.sh
```

`deploy.sh` builds Release in a throwaway DerivedData dir, kills any running
instance, and `cp -R`s the signed `.app` into `/Applications`. It sources
`~/appledev/setupenv.sh` if present so an `APPLE_TEAM_ID` there overrides signing;
otherwise it relies on the `DEVELOPMENT_TEAM` baked into the project. Verified:
Release build signs with hardened runtime and `codesign --strict` passes.

Last verified self-test (2026-10-18, Ethernet → Starlink primary + Wi-Fi → fibre):

```
NetHealth self-test — 2 connection(s)
  Ethernet  en0  192.168.1.x    gw 192.168.1.1  (primary)
    link  1 Gb/s
    [OK]   Router      192.168.1.1          0.8 ms  via TCP
    [OK]   Dish        192.168.100.1        1.0 ms  via TCP
    [OK]   Cloudflare  1.1.1.1             24.5 ms  via TCP
  Wi-Fi  en1  192.168.108.x  gw 192.168.108.1
    link  172 Mbps · 2.4 GHz ch 11 · −67 dBm  802.11ax (Wi-Fi 6)  20 MHz  noise -96 dBm
    [OK]   Router      192.168.108.1       10.0 ms  via TCP
    [--]   Dish        192.168.100.1    not present (optional)
    [OK]   Cloudflare  1.1.1.1             11.4 ms  via TCP
5 targets reachable (4 required across 2 connection(s))
```

and `--speedtest` (40 MB ↓ / 15 MB ↑ caps): Starlink ≈ 300 ↓ / 25 ↑ Mbps,
fibre-over-Wi-Fi ≈ 140 ↓ / 100–160 ↑ Mbps. (All `via TCP` confirms the sandbox is blocking ICMP, as expected.)

## Publishing (GitHub + Pages)

- Public repo: **https://github.com/pcwilliams/nethealth** (`main`; push over
  SSH, since HTTPS has no stored credentials). Commits use the GitHub no-reply
  address (`11552527+pcwilliams@users.noreply.github.com`, repo-local config)
  so no personal email is published.
- **Pages:** `.github/workflows/pages.yml` copies `*.html` + `docs/` into
  `_site` and deploys on pushes touching those paths. Live at
  https://pcwilliams.github.io/nethealth/ (`index.html` landing page →
  `architecture.html`, `tutorial.html`). Page footers link to the GitHub
  README, not `README.md` (Pages doesn't render Markdown here).
- `.gitignore` excludes `build/`, `xcuserdata/`, `.DS_Store` and `.claude/`
  (local permissions full of home-directory paths).
- **README screenshot** `docs/screenshot.png`: window capture with shadow
  (`screencapture -l <CGWindowID>`), then every `192.168.x.x` except the dish is
  located with Vision OCR (`VNRecognizeTextRequest` + `boundingBox(for:)`) and
  pixelated with Pillow; re-run OCR on the output to confirm nothing is
  readable. Docs show the Mac's own LAN addresses as `192.168.1.x` /
  `192.168.108.x`.

## App icon

Generated programmatically by `generate_icons.py` (Python/Pillow), **modelled on
the app's own look**: the deep `AmbientBackground` gradient + top glow, overlaid
with three flowing **aurora latency ribbons** in the health tints (amber/teal/
green) — each with a translucent gradient fill, a Gaussian-blurred glow stroke, a
crisp trace, and a glowing leading-edge dot, plus the faint scale/time grid.
Full-bleed 1024² RGB, 3× supersampled, emitted to every macOS slot with a
matching `Contents.json`. Re-run after a palette/look change:

```bash
python3 generate_icons.py
```

## Status

- **Phase 1 (done, verified):** Aurora ribbon UI, three targets, live
  min/avg/max/jitter/loss stats, resizable window, ambient health background,
  smooth 60 fps time-scrolling graph with pinned leading edge and eased scale.
- **Probe-method badge (done, verified):** each `StatCard` shows whether the
  live reading is `ICMP` or `TCP`; threaded through `PingService.Reading` →
  `PingSample.method` → `TargetHealth.method`. `--selftest` prints it too.
- **Multi-connection + bandwidth (done, verified 2026-10-18):** stacked panel
  per live link (interface-pinned probes, per-link gateway, dish only on the
  Starlink link), periodic multi-stream Cloudflare ↓/↑ test with schedule
  picker (default 10 min), Test now, live Mbps, sparkline, shaded
  latency-under-load windows, 429 backoff, session data counter, cards in fixed
  aligned slots; `--speedtest` and `--watch` CLI modes.
  Snapshot before this work: `~/appledev/nethealth copy`.
- **Local link rate (done, verified 2026-10-19):** header chip per panel with
  Wi-Fi transmit rate/band/channel/RSSI (CoreWLAN) or Ethernet speed
  (`ifi_baudrate`), amber on 2.4 GHz or when the last download reached ≥60 % of
  it; also printed by `--selftest`. No traffic to the router.
- **Any-network support (done, verified 2026-06-26):** Router target now follows
  the machine's real default gateway (`Gateway.defaultIPv4()` via
  `sysctl(NET_RT_DUMP)`); the dish is an `optional` target that's omitted from
  cards/graph/overall when it never answers (so a non-Starlink LAN reads
  "Excellent", not "Offline"); and a `ECONNREFUSED` RST counts as a reachable
  local hop. Verified live on fiber (gateway `192.168.108.1`, dish omitted, two
  cards) and via `--selftest`.
- **Phase 2 (abandoned — do not revive without care):** the original plan was
  rich Starlink dish telemetry via the dish gRPC API at `192.168.100.1:9200`
  (`SpaceX.API.Device.Device/Handle`, `get_status`) — PoP latency, drop rate,
  throughput, % sky obstructed, uptime, alerts. **Dropped on the owner's call**
  after the dish appeared to crash while being probed: that same `Handle`
  endpoint also accepts `reboot`/`stow`, so we keep NetHealth a passive
  latency monitor and never speak gRPC to the dish. Port 9200 was removed from
  the dish probe list entirely (gentle TCP-connect on 80/443 only).

## Lessons / gotchas

- **Multiple links = multiple default routes.** Secondary ones are
  `RTF_IFSCOPE`-scoped and only used by sockets bound with `IP_BOUND_IF`
  (BSD sockets) or `requiredInterface` (Network.framework). Without binding,
  every probe silently measures the primary link.
- **URLSession has no public interface pinning** — use `NWConnection` +
  `requiredInterface` for per-link HTTP.
- **Cloudflare speed endpoints:** `__down` > 100 MB → 403; heavy testing earns
  **429 on single requests ≥10 MB** (small ones still served) — loop small
  requests, test every 10 min, and back off on 429.
- **Fixed card slots need per-slot observation.** Panels lay out Router · Dish ·
  Cloudflare · Bandwidth in fixed positions (gap where the dish is absent) so
  cards line up across stacked panels. `CardSlot` holds `@ObservedObject
  TargetHealth`: checking `health.isPresent` inside the panel's `ForEach`
  didn't redraw when the dish's `everReachable` flipped (the panel only observes
  the connection), so the dish card never appeared.
- **The fibre router's port 80 stalled briefly** (94 % router loss over Wi-Fi in
  the GUI) right after a burst of back-to-back speed tests + parallel curls; it
  recovered on its own and `--watch` / a Python 1 Hz replica showed the probe
  logic was fine. If it recurs, check whether it correlates with test bursts.
- **Wi-Fi shows periodic ~100 ms spikes** on *both* router and Cloudflare at
  once (radio scanning/power-save) — a real Wi-Fi artefact, not a probe bug.

- **You can't speed-test *to* a consumer router** — it has no endpoint that
  can source/sink data fast. Read the link rate from the OS instead (CoreWLAN /
  `ifi_baudrate`), which is free and sandbox-safe.

- **The App Sandbox blocks ICMP echo replies (`EPERM` on `recv`)** even with
  `network.client` — unprivileged ICMP datagram sockets are not usable. Measure
  latency via **TCP connect time** instead (see `--netdiag` to reproduce). The
  per-card `ICMP`/`TCP` badge now shows which path is live without `--netdiag`.
- **Don't poke the Starlink dish's gRPC API (`:9200`).** It appears to crash the
  user terminal, and the `Handle` endpoint that serves telemetry also accepts
  `reboot`/`stow` — too sharp a tool for a passive monitor. Probe the dish only
  with a gentle TCP-connect on web ports 80/443; never port 9200. `starlink-grpc-tools`
  independently warns about over-frequent polling and ships reboot-detection.
- **The Firewall prompt ≠ the Sandbox ICMP block.** Allowing macOS's "accept
  incoming connections" dialog governs inbound *connections*; it does not lift
  the sandbox `EPERM` on the ICMP echo reply, so ICMP stays disabled regardless.
- **Time-scrolling charts: pin the leading edge.** Positioning by real age gives
  smooth scroll but sawtooths at the right as new samples pop in; hold the latest
  value out to `x = width` to remove it.
- **Auto-scaling axes need hysteresis** or they flip-flop on a threshold.
- **A GUI app's buffered `print` to a redirected stdout isn't reliably flushed** —
  CLI modes write via `FileHandle.standardOutput.write`.
- **`App.init()` runs on the MainActor** — CLI probes use `Task.detached`; a plain
  `Task {}` + `sema.wait()` would deadlock.
- **macOS has no `timeout(1)` command** — don't wrap test runs in it; the
  self-test has its own internal watchdog.
- **Starlink dish is always at `192.168.100.1`**; the router gateway varies by
  network — read it from the routing table (`sysctl(NET_RT_DUMP)`,
  `Gateway.defaultIPv4()`) rather than hard-coding `192.168.1.1`. The sysctl read
  works under the sandbox (it's not a network connection).
- **`ECONNREFUSED` (a RST) means the host is up.** It's a full SYN→RST round trip
  — a valid latency sample — so `TCPPinger` returns it as a reading. Only treat
  `EHOSTUNREACH`/timeouts as unreachable, which is what keeps an absent optional
  target (the dish on non-Starlink LANs) correctly hidden.
- **Latch optional-target presence; don't hide on a single miss.** `everReachable`
  flips true on the first successful reply and stays true, so a present dish
  doesn't flicker out on one dropped probe — only a *never*-seen optional target
  is omitted.
- `pbxproj` hand-authored (macOS-only, `SDKROOT=macosx`); verify with
  `xcodebuild -list` before trusting edits.
- Swift can't use the C `FD_SET`/`FD_ZERO` macros — `TCPPinger` reimplements them.
- SourceKit may report spurious "Cannot find X in scope" across files; the
  `xcodebuild` result is the source of truth.
