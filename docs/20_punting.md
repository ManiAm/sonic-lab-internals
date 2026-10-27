# Punting — Sending Packets from the ASIC to the CPU

> **Prerequisites**: [Ports and Host Interfaces](18_ports_and_host_interfaces.md) — host interfaces and why data-plane traffic never reaches the CPU. [The Forwarding Chain](19_forwarding_chain.md) — the SAI forwarding object chain.


## Fast Path vs Slow Path

Every packet arriving at a switch port takes one of two paths:

- **Fast path** (data plane) — The ASIC matches the packet against its forwarding tables (routes, ACLs, MAC table) and forwards it out an egress port — entirely in hardware, at line rate, with no CPU involvement. This is the path that millions of packets per second take.

- **Slow path** (control plane) — The ASIC determines that the packet requires software processing and redirects it to the CPU through a [host interface](18_ports_and_host_interfaces.md#host-interfaces). The Linux kernel receives the packet, and a user-space daemon handles it. This path is orders of magnitude slower — a CPU can process thousands to tens of thousands of packets per second, compared to the ASIC's millions.

The slow path exists because certain packets **cannot** be handled in hardware. The ASIC has no BGP implementation, no ARP state machine, no LLDP agent. These protocols run as software daemons on the CPU, and the only way they can receive packets is if the ASIC forwards those packets to the CPU. This redirection from the ASIC to the CPU is called **punting**.

<img src="../pics/switch-planes.png" alt="Fast path vs slow path"  width="700">

The diagram above shows three traffic types entering a switch through the ingress interface:

- **Data** traffic (e.g., a user's HTTP request being routed through the switch) — the vast majority passes straight through the data plane from ingress to egress, entirely in hardware. The CPU never sees it. However, a small portion of data traffic can be punted to the CPU as exceptions — for example, packets with an expired TTL, no matching route, or MTU exceeded.

- **Control** traffic (e.g., BGP updates, ARP requests, LLDP) — always punted upward to the CPU, because the ASIC has no protocol implementation. Software daemons must process these.

- **Management** traffic (e.g., SSH sessions, SNMP queries to the switch itself) — always punted to the CPU, since these are destined for the switch, not being forwarded through it.

All punted traffic passes through the **CoPP** policer that rate-limits what reaches the control plane, protecting the CPU from being overwhelmed. This architectural boundary is what the rest of this document explores in detail.

> **Physical note:** On the [Celestica DX010](https://github.com/ManiAm/net-lab-dx010/blob/master/docs/01_README_dx010.md#two-board-pcb-architecture) used in our lab, the data plane and control plane are literally on **separate PCBs** — the upper board carries the Tomahawk ASIC and front-panel ports, while the lower board carries the Intel Atom CPU, RAM, and storage. The two boards communicate over a PCIe interconnect through the CPU port. This two-board design is common in 1U white-box switches but is not universal — some platforms place the CPU and ASIC on the same board, and modular chassis switches use entirely different architectures with line cards and supervisor modules.


## What Gets Punted

The ASIC does not punt packets arbitrarily. Every punt decision is driven by a **trap rule** that SONiC explicitly programs into the ASIC. Without a matching trap rule, the ASIC either forwards the packet in the fast path or drops it — the CPU never sees it. This applies to all three traffic types from the previous section: **control** traffic (BGP, ARP, LLDP) needs trap rules so the ASIC knows to redirect it to the CPU, **data** traffic exceptions (TTL expired, no route) need trap rules to catch the edge cases, and **in-band management** traffic (packets addressed to the switch's own IP) needs a trap rule so the ASIC sends it to the local kernel instead of trying to forward it.

> **Out-of-band management traffic is different.** SSH sessions and SNMP queries arriving on the dedicated management port (`eth0`) bypass the ASIC entirely — the management port is wired directly to the CPU, not to the switching chip. No trap rules are needed for this traffic because it never enters the ASIC's forwarding pipeline. The punting rules discussed in this document apply only to traffic entering through the ASIC's front-panel ports.

Common categories of punted traffic:

| Traffic class            | Category                        | Examples                       | Why the CPU needs it |
|--------------------------|---------------------------------|--------------------------------|---|
| **Control**              | Routing protocols               | BGP (TCP/179), OSPF, PIM, BFD  | Protocol daemons in FRR must process updates |
| **Control**              | Address resolution              | ARP requests/replies, IPv6 NDP | The kernel must learn or respond to neighbors |
| **Control**              | Link-layer discovery            | LLDP, LACP, STP BPDUs          | Protocol daemons must manage link state |
| **Data** (exception)     | ICMP                            | Ping (echo request), traceroute (TTL expired) | The kernel must generate replies or error messages |
| **Data** (exception)     | Exception packets               | TTL = 1, IP options, MTU exceeded | The kernel must generate ICMP error responses |
| **Data** (exception)     | No forwarding match             | No route, or a route pointing to CPU | The ASIC has no hardware entry, so it falls back to the CPU |
| **Management** (in-band) | Packets addressed to the switch | IP packets with destination = switch's own IP | The kernel must deliver them to the local socket |


## Punt Actions

Not all punted traffic is handled the same way. The ASIC can do different things with a matched packet depending on the action assigned to its trap rule:

| Action      | What the ASIC does                                                        | CPU sees it? |
|-------------|---------------------------------------------------------------------------|---|
| **Trap**    | Removes the packet from the forwarding pipeline — it is **not** forwarded | Yes |
| **Copy**    | Forwards the packet normally in hardware **and** sends a copy to the CPU  | Yes (copy) |
| **Log**     | Same as Copy, but intended for logging and diagnostic use                 | Yes (copy) |
| **Drop**    | Drops the packet — it is neither forwarded nor sent to the CPU            | No |
| **Forward** | Forwards the packet normally — effectively disables the trap              | No |

**Trap** is for traffic that the CPU must handle exclusively. ARP requests are trapped — the kernel must process them, and they should not be forwarded as regular data. BGP packets destined to the switch are also trapped.

**Copy** is for traffic where both the hardware and the CPU need to act. For example, ICMP echo requests might be copied — the ASIC forwards the packet normally while the CPU also receives a copy to prepare a reply.

**Drop** disables punting entirely for a given traffic type — the ASIC silently discards matching packets. This is used to suppress traffic that the CPU does not need.


## The Punt Path

The previous sections described *what* gets punted and *what action* the ASIC takes. This section explains *how* a punted packet physically travels from the ASIC to the CPU. Several hardware components work together along this path:

```
                         ASIC
  ┌───────────────────────────────────────────────────────────────────────┐
  │                                                                       │
  │   Network       Ingress        Packet       Egress                    │
  │    Ports ──────► Pipeline ────► Buffer ────► Pipeline ──────► Network |
  │                   (parse,        (on-chip     (edit,          Ports   |
  │                    lookup,        memory)      schedule)              |
  │                   classify)                                           │
  │                      │                                                │
  │                      │ trap match                                     │
  │                      ▼                                                │
  │                  ┌────────┐                                           │
  │                  │Policer │──► drop (over limit)                      │
  │                  └───┬────┘                                           │
  │                      │ accept                                         │
  │                      ▼                                                │
  │              ┌──────────────┐                                         │
  │              │  CPU Queues  │                                         │
  │              │ Q7 ████      │ ◄── BGP, BFD                            │
  │              │ Q4 ██████    │ ◄── ARP, LACP, LLDP                     │
  │              │ Q0 █         │ ◄── exceptions                          │
  │              └──────┬───────┘                                         │
  │                     │ scheduler                                       │
  │                     │ (strict priority)                               │
  │              ┌──────┴───────┐                                         │
  │              │  DMA Engine  │                                         │
  │              └──────┬───────┘                                         │
  └─────────────────────┼─────────────────────────────────────────────────┘
                        │ CPU port (PCIe bus)
                        ▼
              ┌──────────────────┐
              │   Host Memory    │
              │  (DMA rx ring)   │
              └────────┬─────────┘
                       │
                       ▼
              ┌──────────────────┐
              │  Kernel Driver   │
              │   → netdev       │
              │   → socket       │
              └──────────────────┘
```

The subsections below walk through each component in order, following a packet from the trap match to the kernel.

### Policer

When the ingress pipeline matches a packet against a trap rule, the packet does not go directly to a CPU queue. First, a **policer** decides whether to accept or drop it. A policer is a hardware rate limiter — it enforces a maximum number of packets (or bytes) per second for a given set of traps. Any traffic exceeding the limit is dropped in hardware before it ever reaches a queue or the CPU.

This is the first line of defense against CPU overload. Without policers, a flood of ARP requests or ICMP packets could saturate the CPU queues, starving critical protocols like BGP of processing time.

Policers are typically implemented using a **token bucket** algorithm. Two standard metering schemes define how token buckets classify traffic:

- **Single Rate Three Color Marker (srTCM)** — defined in [RFC 2697](https://datatracker.ietf.org/doc/html/rfc2697)
- **Two Rate Three Color Marker (trTCM)** — defined in [RFC 4115](https://datatracker.ietf.org/doc/html/rfc4115)

Both are covered in detail in the [QoS — Service Models](https://github.com/ManiAm/DC-QOS/blob/master/docs/02_SERVICE_MODELS.md) topic. [CoPP](#copp--control-plane-policing) is responsible for selecting the metering mode and configuring the rate and burst parameters for each policer.

### CPU Queues

After the policer accepts a packet, it enters one of several **CPU queues** inside the ASIC. The CPU port has multiple queues (typically 8 or more, depending on the ASIC). Each punted traffic type is assigned to a specific queue index, which determines its **priority** relative to other punted traffic.

For example, SONiC's default policy assigns:

| Queue | Traffic types                         | Why this priority                             |
|-------|---------------------------------------|-----------------------------------------------|
| Q7    | BGP, BFD                              | Routing protocol loss causes network outages  |
| Q4    | ARP, LACP, LLDP, DHCP                 | Important but less time-critical than routing |
| Q0    | Exception traffic (TTL expired, etc.) | Best-effort — acceptable to drop under load   |

Different traffic types assigned to the same queue share the same scheduling priority but can still have **separate policers** — so an ARP flood does not consume the rate budget allocated to BGP, even if both land in the same queue. How these assignments are organized is covered in the [Trap Groups](#trap-groups) section below.

### Scheduling

The CPU port's **scheduler** determines the order in which packets are dequeued from the CPU queues. SONiC typically uses **strict priority** scheduling — the scheduler always serves the highest-numbered non-empty queue first. A packet in Q7 is dequeued before any packet in Q4, and Q4 before Q0.

This means that under heavy load, lower-priority queues can be starved — exception traffic in Q0 may wait indefinitely while BGP packets in Q7 keep arriving. This is intentional: it is better to drop a TTL-expired ICMP error than to delay a BGP keepalive that could cause a route withdrawal.

### CPU Port

The **CPU port** is a special internal port on the ASIC that faces the management CPU rather than a front-panel connector. It is the boundary between the ASIC and the host system. On most switch platforms, this connection is a **PCIe bus** — the same high-speed serial interface used to connect GPUs, NICs, and SSDs in standard servers.

The CPU port behaves like any other egress port on the ASIC — it has queues, a scheduler, and a bandwidth limit. The difference is that instead of driving a SerDes lane to a front-panel cage, it connects to the ASIC's DMA engine, which transfers packets across the PCIe bus to host memory.

### DMA and Ring Buffers

**DMA** (Direct Memory Access) is the mechanism that moves packets between the ASIC and host memory without CPU involvement. The CPU does not fetch each punted packet individually — the ASIC's DMA engine writes packets directly into pre-allocated buffers in host RAM, and the CPU simply reads from those buffers.

The host-side memory is organized as a **ring buffer** (also called a descriptor ring). This is a fixed-size circular array of buffer slots, shared between the DMA engine (which writes) and the kernel driver (which reads):

1. The kernel driver pre-allocates a ring of buffer slots in host memory and gives the DMA engine their addresses.
2. When the scheduler dequeues a packet from a CPU queue, the DMA engine writes the packet data into the next available slot in the ring.
3. The kernel driver detects the new packet (via interrupt or polling), reads the data, and delivers it to the appropriate [host interface](18_ports_and_host_interfaces.md#host-interfaces) netdev.
4. The driver marks the slot as free, and the DMA engine can reuse it for the next packet.

This ring buffer design allows the ASIC and CPU to work at their own speeds without blocking each other — the ASIC can burst packets into the ring while the kernel drains them at its own pace, as long as the ring does not fill up.


## Trap Groups

A **trap group** is a container that bundles one or more related traps together and assigns them shared properties — specifically a **policer** (rate limiter) and a **CPU queue** index.

Without grouping, every individual trap would need its own policer and queue assignment. Trap groups simplify this: protocols with similar importance and rate requirements are placed in the same group, so they share a single policer budget and land in the same queue.

For example, SONiC's default configuration defines groups like:

- **queue4_group1** — contains ARP, LLDP, and UDLD traps. These are important link-level protocols that can share the same rate limit and CPU queue.
- **queue7_group** — contains BGP and BFD traps. These are time-critical routing protocols that need a higher-priority queue and their own rate budget.

Each trap is assigned to exactly one group. The group determines *how fast* traffic is accepted (via the policer) and *at what priority* it is processed (via the queue). The [SAI Trap Objects](#sai-trap-objects) section later in this document covers how trap groups are programmed into the ASIC.




## CoPP — Control Plane Policing

CoPP (Control Plane Policing) is the framework that configures trap groups and their rate limits. Without CoPP, a flood of ARP requests or ICMP packets could saturate the CPU and prevent critical protocols like BGP from receiving their packets — potentially causing route withdrawals and network outages.

### The CoPP Configuration File

CoPP policy is defined in `/etc/sonic/copp_cfg.json`, which is **generated at boot** from a Jinja2 template. A systemd oneshot service (`copp-config.service`) runs before SWSS starts:

```bash
# /usr/bin/copp-config.sh
sonic-cfggen -d -t /usr/share/sonic/templates/copp_cfg.j2 > /etc/sonic/copp_cfg.json
```

The template (`copp_cfg.j2`) can vary rates based on device metadata. For example, management-type devices get a higher DHCP rate (300 pps) than leaf/spine devices (100 pps). The rendered JSON is then loaded into CONFIG_DB.

Each entry in the JSON maps a trap group to its CPU queue, rate limit, and the set of trap types it contains:

```json
{
    "COPP_GROUP|queue4_group1": {
        "trap_action": "trap",
        "trap_priority": "4",
        "queue": "4",
        "meter_type": "packets",
        "mode": "sr_tcm",
        "cir": "6000",
        "cbs": "6000",
        "red_action": "drop"
    },
    "COPP_TRAP|bgp": {
        "trap_ids": "bgp,bgpv6",
        "trap_group": "queue4_group1"
    }
}
```

The policer fields in `COPP_GROUP` control the rate limit:

| Field | Meaning |
|---|---|
| `meter_type` | What to count — `packets` (packets per second) or `bytes` (bytes per second) |
| `mode` | Policer algorithm — `sr_tcm` stands for **Single Rate Three Color Marker** (RFC 2697), which classifies traffic into green (conforming), yellow (exceeding), and red (violating) based on a single rate and burst size |
| `cir` | **Committed Information Rate** — the sustained rate allowed (here, 6000 packets per second) |
| `cbs` | **Committed Burst Size** — the maximum burst that can exceed the steady rate momentarily (here, 6000 packets) |
| `red_action` | What to do with packets that violate the rate — `drop` discards them in hardware |

In this example, BGP packets (IPv4 and IPv6) are assigned to `queue4_group1` and rate-limited to 6,000 packets per second. Packets exceeding that rate are dropped by the ASIC before reaching the CPU.

### The Programming Pipeline

CoPP configuration follows the standard SONiC pipeline:

```
/etc/sonic/copp_cfg.json
    │  loaded into CONFIG_DB at boot
    ▼
CONFIG_DB: COPP_TRAP, COPP_GROUP
    │  coppmgrd reads and writes to APPL_DB
    ▼
APPL_DB: COPP_TABLE
    │  CoppOrch consumes
    ▼
SAI: trap groups, traps, policers
```

- **`coppmgrd`** (manager daemon in SWSS) — reads CoPP configuration from CONFIG_DB and writes it to APPL_DB's `COPP_TABLE`.
- **`CoppOrch`** (orchagent module) — consumes `COPP_TABLE`, creates the SAI trap groups, policers, and trap objects, and binds them together.

### Config Merge and Override

`coppmgrd` does not blindly copy the JSON into APPL_DB. At startup it reads both the init file (`copp_cfg.json`) and any existing `COPP_GROUP|*` / `COPP_TRAP|*` keys in CONFIG_DB. The merge logic works as follows:

- **Override** — if the same key exists in both the init file and CONFIG_DB, the CONFIG_DB fields take precedence. This is how an operator customizes rates without editing the template.
- **Suppress** — setting a CONFIG_DB key to `NULL` suppresses the init entry entirely, preventing that group or trap from being published.
- **Restore** — when a CONFIG_DB override is deleted, `coppmgrd` re-creates the entry from the original init file values.

### Feature Gating

Not every trap in the JSON is installed into the ASIC. A trap name is only published to APPL_DB if one of two conditions is met:

1. The trap's JSON entry has `"always_enabled": "true"` — for example, `lacp`, `arp`, `udld`, `ip2me`, and `neighbor_miss` are always enabled regardless of any feature state.

2. The CONFIG_DB `FEATURE|<name>` table has `state` set to `enabled` or `always_enabled` — for example, `bgp`, `lldp`, `dhcp_relay`, and `sflow` are only installed when their corresponding feature is enabled.

If neither condition is met, `coppmgrd` excludes that trap's IDs from the group's `trap_ids` list in APPL_DB. For example, the default template includes MACsec (EAPoL) and NAT traps, but if those features are not enabled, no SAI trap object is ever created for them.

When a feature is later enabled or disabled at runtime, `coppmgrd` recomputes the trap ID list for the affected group and updates APPL_DB. If disabling a feature leaves a trap group with zero enabled traps, the group is removed from APPL_DB entirely.

### What CoppOrch Does

When `CoppOrch` starts, it performs three initialization steps before processing any APPL_DB entries:

1. **Trap capability query** — `CoppOrch` asks the SAI vendor library which trap types the hardware supports by calling `sai_query_attribute_enum_values_capability()`. If the query fails (not all vendors implement it), it falls back to a hardcoded list of ~45 common trap types. The supported set is published to STATE_DB's `COPP_TRAP_CAPABILITY_TABLE`. Any trap type not in the supported set is silently skipped when processing APPL_DB entries.

2. **Default hostif table entry** — `CoppOrch` creates a wildcard host interface table entry that routes all trapped packets through the `NETDEV_PHYSICAL_PORT` channel:

    ```c
    attr.value.s32 = SAI_HOSTIF_TABLE_ENTRY_TYPE_WILDCARD;
    /* ... */
    attr.value.s32 = SAI_HOSTIF_TABLE_ENTRY_CHANNEL_TYPE_NETDEV_PHYSICAL_PORT;
    ```

    This is the critical link between "the ASIC traps a packet" and "the packet appears on the correct Linux **netdev**" (network device — the per-port Linux interface such as `Ethernet0`). Without this entry, the kernel would not know which interface received the trapped packet. The sFlow group overrides this per-trap with a `GENETLINK` channel (see below).

3. **Default trap group and TTL_ERROR** — `CoppOrch` fetches the switch's built-in default trap group (via `SAI_SWITCH_ATTR_DEFAULT_TRAP_GROUP`) and hardcodes `SAI_HOSTIF_TRAP_TYPE_TTL_ERROR` onto it. This happens outside of `coppmgrd`'s control — TTL errors are always trapped regardless of the JSON configuration.

After initialization, `CoppOrch` processes each `COPP_TABLE` entry from APPL_DB: it creates or updates the SAI trap group (with the queue index), creates a policer (with the cir/cbs/red_action values), and creates one SAI trap object per trap type in the group's `trap_ids` list.

> **Platform note — trap priority**: `CoppOrch` skips setting `SAI_HOSTIF_TRAP_ATTR_TRAP_PRIORITY` on Mellanox and Marvell platforms because those SAI implementations do not support it. The `trap_priority` value from the config stays in APPL_DB but never reaches the ASIC on those platforms.

### Genetlink Channel for sFlow

Most trapped packets reach user space through the **netdev channel** — they appear as packets on the per-port Linux network devices. sFlow is the exception.

The sFlow trap group carries `genetlink_name=psample` and `genetlink_mcgrp_name=packets` in the config. **Genetlink** is a kernel messaging mechanism that allows user-space programs to receive structured data from the kernel without going through the normal network stack. When `CoppOrch` sees these fields, it creates a `SAI_HOSTIF_TYPE_GENETLINK` host interface and per-trap table entries with `CHANNEL_TYPE_GENETLINK`. This causes sFlow sample packets to bypass the netdev path and go directly to the kernel's `psample` genetlink family, where the sFlow agent reads them.

### Trap Counters

`CoppOrch` binds a SAI generic counter to each trap object via `SAI_HOSTIF_TRAP_ATTR_COUNTER_ID` and registers it with the flex counter infrastructure. This populates `COUNTERS_TRAP_NAME_MAP` in COUNTERS_DB, enabling per-trap packet and byte counters. The counters are polled every 10 seconds by default.

### STATE_DB Feedback

Three STATE_DB tables provide operational verification that CoPP is programmed:

| Table | Written by | What it confirms |
|---|---|---|
| `COPP_GROUP_TABLE\|<group>` | `coppmgrd` | `state=ok` — the group was published to APPL_DB |
| `COPP_TRAP_TABLE\|<trap>` | `coppmgrd` + `CoppOrch` | `state=ok` from coppmgrd; `hw_status=installed` after SAI accepts the trap |
| `COPP_TRAP_CAPABILITY_TABLE\|traps` | `CoppOrch` | The list of trap IDs the vendor SAI supports |

These tables let an operator confirm which traps are actually installed in hardware, and which were skipped because the feature was disabled or the vendor SAI does not support them.

### Default CoPP Policy

SONiC ships with a default CoPP policy that covers all standard protocols. The defaults are designed to protect the CPU under normal and adversarial conditions while ensuring critical protocols (BGP, LACP) always have enough bandwidth:

| Group | Queue | Trap IDs | Rate (pps) | Action |
|---|---|---|---|---|
| `queue4_group1` | 4 | bgp, bgpv6, lacp, eapol | 6000 | trap |
| `queue4_group2` | 4 | arp_req, arp_resp, neigh_discovery | 600 | copy |
| `queue4_group3` | 4 | lldp, udld, dhcp, dhcpv6 | 100 | trap |
| `queue2_group1` | 2 | sample_packet (sFlow) | 1000 | trap |
| `queue1_group1` | 1 | ip2me | 6000 | trap |
| `queue1_group2` | 1 | src_nat_miss, dest_nat_miss | 600 | trap |
| `queue1_group3` | 1 | neighbor_miss | 200 | trap |
| `default` | 0 | (TTL error, hardcoded by CoppOrch) | 600 | — |

All policers use `meter_type=packets`, `mode=sr_tcm`, `red_action=drop`. The `queue4` groups share the highest CPU queue (4) because BGP, ARP, and LLDP are the most operationally critical. The `queue1` groups handle switch-addressed traffic (ip2me), NAT misses, and neighbor discovery misses at a lower priority. The `default` group at queue 0 has the lowest priority and catches exception traffic.

Operators can customize rates by applying a CONFIG_DB patch (which overrides the init file as described in [Config Merge and Override](#config-merge-and-override)) and running `config reload`.


## SAI Trap Objects

SONiC programs punt behavior through three SAI object types that work together: **traps**, **packet actions**, and **trap groups**. This section explains each one, starting with the trap object itself.

### Trap (`SAI_OBJECT_TYPE_HOSTIF_TRAP`)

A trap object tells the ASIC: "when you see a packet matching this type, perform this action." Each trap is identified by a **trap type** — a predefined enum in SAI that covers every protocol and exception the ASIC can recognize:

```c
sai_attribute_t trap_attrs[3];
trap_attrs[0].id        = SAI_HOSTIF_TRAP_ATTR_TRAP_TYPE;
trap_attrs[0].value.s32 = SAI_HOSTIF_TRAP_TYPE_BGP;       /* match BGP packets */
trap_attrs[1].id        = SAI_HOSTIF_TRAP_ATTR_PACKET_ACTION;
trap_attrs[1].value.s32 = SAI_PACKET_ACTION_TRAP;          /* punt to CPU */
trap_attrs[2].id        = SAI_HOSTIF_TRAP_ATTR_TRAP_GROUP;
trap_attrs[2].value.oid = trap_group_oid;                   /* rate-limit group */
sai_hostif_api->create_hostif_trap(&trap_oid, switch_id, 3, trap_attrs);
```

> The `.oid` fields hold **OID**s (Object Identifiers) — opaque handles that SAI returns when you create an object. You pass OIDs back to SAI to reference existing objects (here, linking the trap to its trap group).

### Trap Group (`SAI_OBJECT_TYPE_HOSTIF_TRAP_GROUP`)

A trap group bundles multiple traps together and assigns shared properties — a [policer](#policer) and a [CPU queue](#cpu-queues) index (both described earlier). SAI exposes these as two attributes:

```c
sai_attribute_t group_attrs[2];
group_attrs[0].id        = SAI_HOSTIF_TRAP_GROUP_ATTR_QUEUE;
group_attrs[0].value.u32 = 4;                               /* CPU queue index */
group_attrs[1].id        = SAI_HOSTIF_TRAP_GROUP_ATTR_POLICER;
group_attrs[1].value.oid = policer_oid;                      /* rate limiter */
sai_hostif_api->create_hostif_trap_group(&group_oid, switch_id, 2, group_attrs);
```

### CPU Port Discovery

`PortsOrch` discovers the CPU port at initialization by querying the switch, and stores it as a `Port` object with type `Port::CPU`:

```c
sai_attribute_t attr;
attr.id = SAI_SWITCH_ATTR_CPU_PORT;
sai_switch_api->get_switch_attribute(gSwitchId, 1, &attr);

m_cpuPort = Port("CPU", Port::CPU);
m_cpuPort.m_port_id = attr.value.oid;
```


## The Complete Punt Path

Putting it all together, here is the full path a punted packet takes from the wire to a user-space daemon:

```
Physical port (wire)
    │
    ▼
ASIC ingress pipeline
    │  packet matches a trap rule (e.g., BGP on TCP/179)
    ▼
Policer checks rate limit
    │  over rate → packet dropped in hardware (never reaches CPU)
    │  under rate → accepted
    ▼
CPU port queue (e.g., queue 4 for BGP)
    │  scheduler serves higher queues first
    ▼
DMA to host memory
    │
    ▼
Hostif table entry routes to channel
    │  default: NETDEV_PHYSICAL_PORT → packet appears on the
    │           Linux netdev for the ingress port (e.g., Ethernet8)
    │  sFlow:  GENETLINK → packet goes to the psample kernel module
    ▼
Linux kernel network stack
    │  IP routing, socket lookup
    ▼
User-space daemon (e.g., bgpd listening on TCP/179)
```

The hostif table entry step is often invisible but essential. The wildcard entry that `CoppOrch` creates at startup (see [What CoppOrch Does](#what-copporch-does)) tells the ASIC driver to deliver trapped packets through the per-port netdev channel. This is how the kernel knows that a trapped BGP packet arrived on `Ethernet8` rather than some other port.

The reverse direction — CPU to wire — is simpler. When a daemon sends a packet (for example, a BGP UPDATE), it writes to a socket. The kernel routes the packet to the appropriate host interface, and SAI transmits it on the physical port. No trap rules are involved in the egress direction.

---

**Previous**: [← The Forwarding Chain](19_forwarding_chain.md) · **Next**: [The BGP Container and FRR →](21_bgp_container.md)
