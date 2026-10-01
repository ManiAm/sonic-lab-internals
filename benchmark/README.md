

# Running the BGP Route-Download Benchmark

This guide is the hands-on companion to [The BGP Route-Download Benchmark](../docs/15_benchmark.md), which explains the pipeline, defines the metrics, and presents measured results. Everything here is procedure: what tools you need, how to set them up, and the exact steps to run a benchmark on a SONiC switch. All scripts referenced below live in this directory (`benchmark/`).

---

## Route Injectors

The benchmark requires a software BGP speaker running on a lab server to advertise a controlled set of routes into the switch under test. Two open-source tools serve this purpose, each suited to a different scale: `ExaBGP` for lightweight, scripted injections and `GoBGP` for high-throughput, large-scale runs.

Other BGP implementations — BIRD, a standalone FRR instance, rustybgp — can technically open a session and announce prefixes, but they are full routing daemons designed to *be* routers, not test harnesses. ExaBGP and GoBGP are purpose-built for controlled injection: one is a scriptable speaker with no routing table, the other is an API-first daemon with native MRT replay.

### ExaBGP — The Scriptable BGP Speaker

ExaBGP dates back to 2009 and was publicly released in July 2010 by Thomas Mangin of Exa Networks (a UK ISP), originally built to announce anycast DNS addresses. It is written in Python, licensed under BSD 3-clause, and still actively maintained (the 4.2.x line is the widely deployed stable version; a 5.x line is current).

ExaBGP is **not a router** — it is a programmable BGP *speaker*, often called "the BGP Swiss army knife." It keeps minimal state: no real route table, no best-path selection, and it never touches the kernel's forwarding table. All it does is open a genuine BGP session and announce or withdraw exactly what you tell it to. You control it through a config file and a pipe-based API: your script (in any language) prints text commands like `announce route 10.0.0.0/24 next-hop 192.0.2.1` to ExaBGP's stdin, and ExaBGP streams BGP events back as JSON on stdout.

This pipe-based design made it the standard tool for scripted BGP: DDoS blackholing (it was the first open-source FlowSpec implementation, RFC 5575), anycast health-check announcers, looking glasses, and — as here — route injection for benchmarks.

**For the benchmark**, ExaBGP is the quick-scripting choice: a few lines of shell or Python can announce routes at whatever pace you want, with no daemon configuration to learn.

### GoBGP — The API-First BGP Daemon

GoBGP was started by NTT's open-source research team in 2014, with version 1.0 shipping in October 2015. It is written in Go, licensed under Apache 2.0, and maintained by a large community (~190 contributors) on a monthly release cadence.

Where ExaBGP is a speaker, GoBGP is a **full BGP daemon**: it maintains a real routing table (RIB), runs best-path selection, supports add-paths and route-server mode, and implements heavyweight protocol machinery — MRT dump injection/replay, BMP monitoring, EVPN, FlowSpec, and RPKI validation. It was designed "API-first" for the SDN era: the daemon (`gobgpd`) is controlled entirely through a gRPC API, its configuration follows the vendor-neutral OpenConfig YANG model, and even its CLI tool (`gobgp`) is just another gRPC client. Its typical deployments are IXP route servers, BGP on white-box switches, and telemetry pipelines.

**For the benchmark**, GoBGP is the high-throughput choice: it preloads the entire synthetic route set into its RIB (or replays an MRT dump) and then streams it over the session at full speed. This is why the large-scale 100k/200k runs use the GoBGP path.


## The Supporting Toolkit

The injectors get routes *into* the switch, but we still need to **generate** the route set, **measure** what the switch is doing, **prove** where the bottleneck is, and **tie it all together** into a repeatable run.

### Route generation — `gen_mrt.py`

Before the injector can advertise routes, you need a file full of synthetic prefixes. `gen_mrt.py` is a short Python script that builds an [MRT](https://datatracker.ietf.org/doc/html/rfc6396) dump — the standard binary format that every BGP tool understands. You tell it how many /24 prefixes you want, what next-hop to stamp on them, and what origin AS to use; it writes a file like `routes_100k.mrt` in a few seconds. GoBGP's `mrt inject` command loads this file directly into its RIB.

*Why a separate generator?* Decoupling generation from injection means you can inspect, version-control, and reuse the exact same route set across runs — important for reproducibility.

### Measurement — `asic_monitor.py`

This is the **core measurement instrument**. It runs on the switch (copied there via `scp`) and does one thing: polls the CRM (Critical Resource Monitoring) IPv4 route counter twice per second, logging `(timestamp, count)` pairs. When given the injector's IP, it also polls FRR's received-prefix counter (`pfxRcd`) each sample, so one run captures both RIB-IN convergence and ASIC programming time on the same timeline.

It detects three events automatically:
- **FIRST_ROUTES** — the ASIC count starts moving (first route reaches hardware).
- **RIBIN_COMPLETE** — FRR holds the full route set (ingestion finished).
- **COMPLETE** — the ASIC count reaches baseline + injected routes (hardware programming finished).

The output is a machine-readable `/tmp/asic_results.json` with per-sample data and summary timestamps. This is where the download rate and end-to-end rate come from.

**RIB-IN capture.** The `RIBIN_COMPLETE` event and per-sample `received` fields in `asic_results.json` provide the [RIB-IN convergence](../docs/15_benchmark.md#rib-in-convergence--a-different-kind-of-metric) measurement. The [measured results](../docs/15_benchmark.md#measured-results) use this dual-counter data (CRM for ASIC programming, `pfxRcd` for RIB-IN). Precision caveat: with ~2 s effective polling and 1 s established-epoch granularity, the RIB-IN timestamp is coarse — quote it as "a few seconds," not to the millisecond.

*Why CRM counters?* They are lightweight and non-intrusive — see [Anatomy of a Measurement](#anatomy-of-a-measurement) for why Redis `KEYS` scans are unsuitable for continuous polling.

### Bottleneck proof — `linkproof_monitor.py`

A common objection: "maybe the injector or the management link is the bottleneck, not the switch." This standalone script settles it by polling **two** counters simultaneously — routes *received* by FRR and routes *programmed* in the ASIC — and printing them side by side every two seconds. If the link were the bottleneck, both curves would rise together. In practice, the received counter flattens within seconds while the programmed counter keeps climbing for minutes. The same dual-poll data is also captured by `asic_monitor.py` in every run; this script exists as a dedicated, visual way to demonstrate the proof independently.

### On-switch log files — `swss.rec` and `sairedis.rec`

These are not scripts you write — they are **log files that SONiC already produces** on the switch, and the benchmark reads them after each run for per-stage timestamps:

- **`swss.rec`** (`/var/log/swss/swss.rec`) — orchagent's operation log. Every route that orchagent processes appears as a `ROUTE_TABLE ... SET` line with a microsecond-precision timestamp. The first and last SET of the run give the orchagent processing span (a per-stage lag diagnostic); for the hardware-verified programming window, use CRM counters from `asic_results.json`.
- **`sairedis.rec`** (`/var/log/swss/sairedis.rec`) — the SAI-call log. Every bulk-create that syncd sends to the ASIC is recorded here, with operation codes and entry counts. This is where you verify batching behavior (e.g., bulk sizes of 1,000 + 24) and per-bulk timing.

*No setup needed* — these files exist on any SONiC switch with default logging. You just `scp` them off the switch after a run.

### FRR's CLI — `vtysh`

`vtysh` is FRR's unified command-line interface, already installed inside the BGP container on every SONiC switch. The benchmark uses it for two things: configuring the BGP neighbor before a run (`vtysh -c 'conf t' ...`) and extracting the session-established timestamp afterward (`show bgp neighbors <IP> json` → `bgpTimerUpEstablishedEpoch`). That epoch is the E2E clock-start — the moment the switch's BGP daemon considers the session up.

### GoBGP config — `gobgpd.conf`

A minimal TOML file: your AS number, your IP as router-id, and a non-privileged listen port (10179). This is the only config GoBGP needs — the neighbor and route set are added at runtime via CLI commands. Included in the benchmark directory so you can edit the router-id and go.

### The orchestrator — `run_bench.sh`

Once you understand the individual tools, `run_bench.sh` chains them into a single command: DUT preparation, RIB preload, monitor start, session trigger, artifact collection, withdraw and drain. Running `bash run_bench.sh 100000 100k-iter1` executes one complete iteration and collects all output files. It is optional — the [step-by-step guide](#running-the-benchmark) works without it — but it makes multi-iteration sweeps and CI integration practical.

### Post-processing — `compute_metrics.py`

After a run completes, `compute_metrics.py` reads the collected artifacts (`asic_results.json`, `bgp_neighbor.json`, `swss_rec_firstlast.txt`, `sairedis_rec_firstlast.txt`) and computes every metric needed for the results table — all on the DUT's clock, with no cross-machine correlation. It outputs structured JSON (stdout) and a human-readable summary (stderr):

```bash
python3 compute_metrics.py results/100k-iter1
```

### Quick reference

| Tool | Runs on | Role |
|---|---|---|
| `gen_mrt.py` | your machine | Generate the synthetic route file |
| `gobgpd.conf` | your machine | Minimal GoBGP daemon configuration |
| `asic_monitor.py` | the switch | Poll CRM + FRR counters, produce timing data |
| `linkproof_monitor.py` | the switch | Prove the bottleneck is the pipeline, not the link |
| `swss.rec` / `sairedis.rec` | the switch (already there) | Per-stage timestamps and batching evidence |
| `vtysh` | the switch (already there) | Configure BGP neighbor, extract session timestamps |
| `run_bench.sh` | your machine | Orchestrate a full run end-to-end |
| `compute_metrics.py` | your machine | Compute all table metrics from a run's artifacts |


## Anatomy of a Measurement

Conceptually, every run follows the same recipe (the [hands-on guide](#running-the-benchmark) turns each step into exact commands):

1. **Establish a clean baseline.** Record the switch's existing route counts before advertising anything. The benchmark measures only the *delta*: expected final count = baseline + injected routes. Without a baseline, pre-existing routes (loopbacks, connected, management) pollute the math.

2. **Inject routes and start the clock.** A software BGP speaker on a lab server opens a real BGP session to the switch and advertises a large, fixed route set (e.g., 100,000 IPv4 /24 prefixes). No traffic generator is needed — this exercises the control plane, not the data plane. The session-Established moment (FRR records it as an epoch timestamp) starts the end-to-end clock.

3. **Timestamp every stage while routes flow.** Each stage of the pipeline leaves a trace; the benchmark collects the *first* and *last* route event at each one:

| Stage                          | Where the timestamp comes from |
|--------------------------------|------------------------------------------------|
| BGP accepts the routes         | bgpd's received-prefix counter (`show bgp summary`) |
| zebra selects best paths       | zebra log (route install messages) |
| fpmsyncd hands off             | fpmsyncd entries in syslog |
| APPL_DB populated              | APPL_DB route-key count (one-shot checks) |
| orchagent processes the routes | `swss.rec` — microsecond-precision `ROUTE_TABLE \| SET` lines |
| ASIC database written          | `sairedis.rec` (the SAI-call log) / ASIC_DB route-entry count |
| Hardware actually holds them   | **CRM counters**, polled in a loop (`crm show resources ipv4 route`) |

   The live polling loop (twice per second, logging `timestamp, count` pairs) is what turns a count into a *rate over time*.

   **Important: use CRM counters, not Redis `KEYS` scans.** CRM (Critical Resource Monitoring) is SONiC's built-in tracker of ASIC table usage, refreshed at the configured polling interval. Redis `KEYS` scans are O(N) on a single-threaded Redis server and throttle the very route programming being measured (~5–15% error at 100k scale). Key-count commands are fine for one-shot before/after checks, but the continuous polling loop must use CRM.

4. **Stop the clock when the hardware count reaches the target.** The run ends when the ASIC-level count equals baseline + injected routes. Verifying at the hardware layer matters because it is the only layer that actually forwards traffic.

5. **Repeat and record.** Withdraw the routes, wait for counts to drain back to baseline, and repeat (typically three iterations). Average the rates, note the spread, and write everything — per-stage timestamps, rates, and the switch configuration used — into a machine-readable summary so runs can be compared over time. The same harness can then run on a schedule in CI with pass/fail thresholds, catching regressions before they ship.



---

# Running the Benchmark

This is the exact procedure used to benchmark a standalone SONiC switch (Celestica Seastone DX010, Broadcom ASIC, mgmt IP 192.168.2.170) from a Linux workstation, with real measured results at the end. Total hands-on time: about 45 minutes (programming is slower on this platform, so each iteration takes longer). Nothing on the switch is changed permanently — every step is runtime-only and reversible.

All scripts live in this directory and are introduced in [The Supporting Toolkit](#the-supporting-toolkit) above.

## Test Topology

```text
┌─────────────────────────────────────────────────────────────────────────────────┐
│                          Management Network  192.168.2.0/24                     │
│                                                                                 │
│   ┌───────────────────────────────┐       ┌───────────────────────────────────┐ │
│   │  Linux Server (GoBGP Injector)│       │  DUT: Celestica Seastone DX010    │ │
│   │  192.168.2.197                │       │  192.168.2.170 (eth0 / mgmt)      │ │
│   │                               │       │                                   │ │
│   │  gobgpd (AS 65432)            │       │  FRR/bgpd (AS 65100)              │ │
│   │    ├─ listen :10179           │       │    ├─ listen :179                 │ │
│   │    ├─ router-id 192.168.2.197 │       │    ├─ router-id 10.1.0.32         │ │
│   │    └─ preloaded 100k routes   │       │    └─ neighbor 192.168.2.197      │ │
│   │       (nexthop: 10.0.0.9)     │       │                                   │ │
│   │                               │  BGP  │  Broadcom ASIC                    │ │
│   │  gen_mrt.py → routes_100k.mrt │──TCP──│    ├─ ~147k IPv4 route capacity   │ │
│   │  gobgp mrt inject ...         │  :179 │    └─ CRM counters polled by      │ │
│   │  gobgp neighbor add ...       │───────│       asic_monitor.py             │ │
│   │                               │  SSH  │                                   │ │
│   │  ssh admin@192.168.2.170      │───────│  orchagent -b 1024 -s             │ │
│   │  scp asic_monitor.py → /tmp/  │  :22  │    (batch=1024, sync mode)        │ │
│   └───────────────────────────────┘       │                                   │ │
│                                           │  Front-panel ports (100G each):   │ │
│                                           │    Ethernet16: 10.0.0.8/31  (up)  │ │
│                                           │    Ethernet64: 10.0.0.32/31 (up)  │ │
│                                           │    Ethernet96: 10.0.0.48/31 (up)  │ │
│                                           │                                   │ │
│                                           │  Static ARP on Ethernet16:        │ │
│                                           │    10.0.0.9 → 02:aa:bb:cc:dd:01   │ │
│                                           │    (fake neighbor so nexthop      │ │
│                                           │     resolves → routes reach ASIC) │ │
│                                           └───────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────────┘
```

The pipeline data flow is covered in detail in [100k Routes Through the Pipeline](../docs/15_benchmark.md#100k-routes-through-the-pipeline--a-concrete-example).

## What You Need

- A Linux machine on the same network that can reach the switch's management IP — this is where GoBGP runs. A dedicated lab server is ideal; avoid running GoBGP from inside WSL2 (Go binaries can hit `connect: no route to host` errors due to WSL2's virtual networking layer).
- SSH access to the switch (admin account).
- Nothing else: no traffic generator, no spare server, no cabling changes. The switch's front-panel ports don't even need real neighbors — one oper-up port is enough (a physical loopback cable to another port of the same switch works).

## Step 1 — Install GoBGP on Your Local Machine (NOT on the Switch)

Install locally for three reasons: the switch CPU is part of what you're measuring (an injector running there would steal cycles from the pipeline daemons and skew the result); the switch's FRR already owns TCP port 179; and the end-to-end metric starts at "session established with an external peer," which is what a real reboot or peering flap looks like.

```bash
mkdir -p ~/gobgp-bench && cd ~/gobgp-bench
curl -sL https://github.com/osrg/gobgp/releases/download/v4.9.0/gobgp_4.9.0_linux_amd64.tar.gz | tar xz gobgp gobgpd
./gobgp --version   # gobgp version 4.9.0
```

Create a minimal config — your AS, your IP as router-id, and a non-privileged listen port (you initiate the connection outbound, so you never need to bind 179 locally):

```toml
# gobgpd.conf
[global.config]
  as = 65432
  router-id = "<YOUR_IP>"
  port = 10179
```

## Step 2 — Generate the Route Set

Use `../benchmark/gen_mrt.py` to build an MRT dump of synthetic /24 prefixes. The crucial argument is the **next-hop**: pick an IP that the switch can resolve on a front-panel port (see Step 3). The DX010 has ~147k IPv4 route capacity (37 baseline + 147,419 available), so 100k is a safe benchmark size; generating the file takes a few seconds.

```bash
python3 ../benchmark/gen_mrt.py 100000 10.0.0.9 65432 routes_100k.mrt   # count, nexthop, origin-AS, outfile
python3 ../benchmark/gen_mrt.py 25000  10.0.0.9 65432 routes_25k.mrt    # small set for a validation run
```

## Step 3 — Prepare the Switch (Three Runtime-Only Adjustments)

**3a. Make the next-hop resolvable.** Routes only reach the ASIC if their next-hop resolves to a neighbor on an oper-up front-panel port — a next-hop on the mgmt interface will never be programmed into hardware. If the port has no real neighbor, fake one with a static ARP entry; SONiC's neighsyncd picks it up and programs it into the ASIC like a real neighbor. Pick a port that is up and already has an IP (check `show ip interfaces`), and use an address inside its subnet:

```bash
sudo ip neigh replace 10.0.0.9 lladdr 02:aa:bb:cc:dd:01 dev Ethernet16
sonic-db-cli APPL_DB hgetall "NEIGH_TABLE:Ethernet16:10.0.0.9"   # must show the entry
```

**3b. Open the BGP port on the mgmt interface.** SONiC's control-plane firewall only accepts TCP/179 on front-panel interfaces (`! -i eth0`), so the session from your machine over mgmt is silently dropped — the classic symptom is both sides stuck in Active. One runtime iptables rule fixes it (disappears on reboot):

```bash
sudo iptables -I INPUT 2 -p tcp -s <YOUR_IP> --dport 179 -j ACCEPT
```

**3c. Configure the BGP neighbor in FRR and speed up route counters:**

```bash
vtysh -c 'conf t' -c 'router bgp <SWITCH_AS>' -c 'neighbor <YOUR_IP> remote-as 65432' -c 'address-family ipv4 unicast' -c 'neighbor <YOUR_IP> activate' -c 'end'
sudo crm config polling interval 1    # CRM route counters update every 1s instead of every 300s
```

Do NOT run `config save` — everything stays runtime-only, and a reboot returns the switch to its original state.

## Step 4 — Start the Measurement on the Switch

Copy `asic_monitor.py` to the switch and start it *before* bringing the session up. It records the baseline, then polls the CRM route counter twice per second until the target is reached, writing timestamped samples to `/tmp/asic_results.json`. It uses CRM counters rather than Redis `KEYS` scans — see the [anatomy section](#anatomy-of-a-measurement) for why this matters.

```bash
scp ../benchmark/asic_monitor.py admin@<SWITCH>:/tmp/
ssh admin@<SWITCH> "nohup python3 -u /tmp/asic_monitor.py 100000 300 <YOUR_IP> > /tmp/asic_monitor.log 2>&1 &"
```

Note the `-u` flag for unbuffered output — without it, Python buffers stdout when redirected to a file and you won't see progress until the script exits. The timeout is set to 300 s because this platform programs ~700 routes/second (100k routes takes ~150 s plus session setup time).

The third argument (your injector's IP) is optional but recommended: with it, the monitor also polls FRR's received-prefix counter (`pfxRcd`) each sample and prints `RIBIN_COMPLETE` the moment bgpd holds the full route set — giving you both RIB-IN convergence and ASIC programming time from a single timeline.

## Step 5 — Preload GoBGP and Start the Run

Start gobgpd, load the entire route set into its RIB while the session is still down, and then — this is the clock-start moment — add the neighbor. The session establishes and GoBGP streams the full preloaded table at full speed:

```bash
./gobgpd -f gobgpd.conf -l warn &
./gobgp mrt inject global routes_100k.mrt --no-ipv6   # preload: a few seconds for 100k
./gobgp neighbor add <SWITCH_MGMT_IP> as <SWITCH_AS>  # T_START — session comes up, routes flow
```

Watch `/tmp/asic_monitor.log` on the switch: it prints `FIRST_ROUTES` when the ASIC count starts moving, `RIBIN_COMPLETE` when bgpd has received everything, and `COMPLETE` when the hardware target is reached (roughly 150 seconds for 100k on this Broadcom platform).

## Step 6 — Collect the Numbers

Three sources, all on the switch's own clock (never mix your machine's clock with the switch's — clock skew ruins the math):

- `/tmp/asic_results.json` — the polled samples, first-route time, RIB-IN completion time, and total time.
- `/var/log/swss/swss.rec` — orchagent's operation log (see [The Supporting Toolkit](#the-supporting-toolkit) for details). Search for `ROUTE_TABLE ... SET` lines — the SAI-level entries (`SAI_OBJECT_TYPE_ROUTE_ENTRY`) live in `sairedis.rec`, not here.
- `vtysh -c 'show bgp neighbors <YOUR_IP> json'` — the `bgpTimerUpEstablishedEpoch` field gives the session-established moment (1-second granularity).

Plug these into the formulas from [Measuring Route-Download Speed](../docs/15_benchmark.md#measuring-route-download-speed--two-rates): `asic_results.json` provides CRM-based `first_route_time` and `total_time` (hardware-verified); the established epoch from `bgp_neighbor.json` is `t_bgp_session_established`; `swss.rec` timestamps give the orchagent processing span (a per-stage diagnostic, not the hardware-verified window). Use `compute_metrics.py` to combine all sources correctly.

## Step 7 — Repeat and Drain

Run at least 3 iterations. Between runs, `./gobgp neighbor del <SWITCH_MGMT_IP>` tears the session down, FRR withdraws everything, and the ASIC count drains back to baseline in ~60–90 seconds — verify with `crm show resources ipv4 route` before starting the next iteration.

## Step 8 — Clean Up the Switch

```bash
vtysh -c 'conf t' -c 'router bgp <SWITCH_AS>' -c 'no neighbor <YOUR_IP>' -c 'end'
sudo ip neigh del 10.0.0.9 dev Ethernet16
sudo iptables -D INPUT -p tcp -s <YOUR_IP> --dport 179 -j ACCEPT
sudo crm config polling interval 300
rm -f /tmp/asic_monitor.py /tmp/asic_results.json /tmp/asic_monitor.log
crm show resources ipv4 route    # back to baseline
```

## Common Pitfalls

All encountered during the first run of this guide:

1. **BGP session stuck in Active on both sides** → the SONiC control-plane firewall dropping TCP/179 on eth0 (Step 3b).
2. **Session up, routes received, ASIC count never moves** → next-hop not resolvable on a front-panel port (Step 3a); check `ip neigh show` and `NEIGH_TABLE` in APPL_DB.
3. **Empty timing data** → grepping `swss.rec` for SAI object names; the SAI layer logs to `sairedis.rec`, orchagent logs `ROUTE_TABLE` operations to `swss.rec`.
4. **Measurement interferes with the system** → polling with Redis `KEYS` scans instead of CRM counters; see the [anatomy section](#anatomy-of-a-measurement).
5. **Never `sudo killall python3` on SONiC.** SONiC's internal management daemons (caclmgrd, hostcfgd, etc.) are Python processes. Killing all Python processes crashes containers — bgp, swss, and syncd restart, port LEDs cycle, and all runtime config (CRM polling, iptables rules, BGP neighbors) is lost. To stop the monitor, target it specifically: `pgrep -f 'python3 /tmp/asic_monitor' | xargs -r kill`.
6. **`pkill -f` can kill its own SSH session.** Running `ssh switch "pkill -f 'asic_monitor.py'"` matches the *ssh command line itself* — pkill sees the string in its parent's argv and kills the SSH session. Use separate SSH calls: one to kill, one to start the new process.
7. **Leftover routes between iterations** → If gobgpd stays running across iterations, routes from the previous run remain in the RIB and are injected again (e.g., 26k instead of 25k). Always `gobgp global rib del all -a ipv4` before each injection.
