# Access Control Lists (ACLs)

> **Prerequisites**: [Orchagent Deep Dive](12_orchagent.md) — Orch architecture and SAI interaction. [The Forwarding Chain](19_forwarding_chain.md) — the SAI forwarding object chain.


## What Is an ACL?

An Access Control List (ACL) is an ordered set of rules that the switch evaluates against every packet passing through a specific point in the forwarding pipeline. Each rule specifies **match criteria** (which packets to select) and an **action** (what to do with them). The switch tests rules from highest priority to lowest — the first match wins, and its action is applied.

ACLs serve three broad purposes:

- **Security** — block unwanted traffic. For example, drop all inbound packets from a known-bad source prefix, or permit SSH only from a management subnet.

- **Traffic steering** — redirect or copy specific flows. For example, mirror all traffic matching a 5-tuple (source IP, destination IP, source port, destination port, and protocol) to a monitoring port for analysis.

- **QoS marking** — reclassify packets. For example, remark the DSCP (Differentiated Services Code Point) value of traffic from a specific application so downstream QoS policies treat it at the correct priority.

Without ACLs, the switch would forward every packet that has a valid route — there would be no mechanism to enforce security policy, selectively mirror traffic, or override QoS markings in the data plane.


## Two ACL Domains in SONiC

SONiC implements ACLs in two fundamentally different domains, each protecting a different part of the system:

|                          | Data-Plane ACLs                                                 | Control-Plane ACLs                         |
|--------------------------|-----------------------------------------------------------------|--------------------------------------------|
| **What they protect**    | The forwarding pipeline — traffic transiting through the switch | The Linux network stack — traffic destined for the CPU |
| **Where rules execute**  | In the ASIC hardware (TCAM)                                     | In the Linux kernel (iptables / ip6tables) |
| **Programmed by**        | `AclOrch` via SAI                                               | `caclmgrd` via iptables commands |
| **CONFIG_DB table type** | `L3`, `L3V6`, `MIRROR`, etc.                                    | `CTRLPLANE`                      |
| **Performance**          | Line rate — millions of packets per second                      | Software rate — thousands of packets per second |
| **TCAM usage**           | Yes — each rule consumes a TCAM entry                           | No — kernel netfilter, no ASIC resources |

The two domains complement each other. Data-plane ACLs filter transit traffic at wire speed inside the ASIC. Control-plane ACLs protect the switch's own management services (SSH, SNMP, BGP) from unauthorized access — filtering by source address, which is something [CoPP](21_punting.md#copp--control-plane-policing) cannot do (CoPP rate-limits punted traffic but does not distinguish by source).


## Data-Plane ACLs

Data-plane ACLs are the primary focus of this document. They are programmed into the ASIC's TCAM and evaluate packets at line rate as part of the hardware forwarding pipeline.

### TCAM — Where ACL Rules Live

ACL rules are stored in the ASIC's **TCAM** (Ternary Content-Addressable Memory) — a special on-chip memory that compares a packet header against all stored rules in parallel and returns the highest-priority match in a single clock cycle. This is what makes line-rate ACL evaluation possible. For a general introduction to TCAM and how it compares to other memory types (SRAM, DRAM, Binary CAM), see [Appendix A — Memory Types](A1_memory_types.md#ternary-cam-tcam).

**Practical implications for SONiC ACL operators:**

- **TCAM is a finite, shared resource.** ACLs, LPM (Longest Prefix Match) routes, host routes, and some internal system rules all compete for the same TCAM banks. The partitioning between these features is typically fixed at boot based on the platform's SAI profile and cannot be changed at runtime.

- **Entry size varies by match key.** Every ACL rule consumes one or more TCAM entries. Rules with wider match keys consume more space — on some platforms, IPv6 rules take twice the TCAM entries of IPv4 rules because IPv6 addresses are 128 bits vs. IPv4's 32 bits.

- **Resource exhaustion is possible.** If an operator installs too many ACL rules, the ASIC runs out of TCAM entries and new rules fail to program. `AclOrch` handles this gracefully — when `sai_acl_api->create_acl_entry()` returns a resource-exhaustion error, the rule is parked in a retry cache and automatically re-attempted when other rules are removed and TCAM space is freed.

- **SONiC monitors TCAM usage via CRM** (Critical Resource Monitoring). `CrmOrch` periodically queries `SAI_ACL_TABLE_ATTR_AVAILABLE_ACL_ENTRY` for each ACL table and publishes used/available counts to COUNTERS_DB. If usage crosses a configurable threshold (default: 85%), CRM logs a warning. Operators can check usage with:

    ```bash
    crm show resources acl table   # TCAM entries used/available per table
    crm show resources acl group   # ACL table groups used/available
    ```

With this hardware context in mind, the following sections walk through how an operator defines ACL rules in SONiC and how they are programmed into the ASIC.

### CONFIG_DB Schema

An operator defines data-plane ACLs using two CONFIG_DB tables:

**`ACL_TABLE`** — defines the table container:

```json
{
    "ACL_TABLE": {
        "DATAACL": {
            "type": "L3",
            "stage": "ingress",
            "policy_desc": "Data plane ACL for security",
            "ports": ["Ethernet0", "Ethernet4", "PortChannel01"]
        }
    }
}
```

| Field         | Description |
|---------------|-------------|
| `type`        | The table type — determines which match fields and actions are available (see [Table Types](#table-types)) |
| `stage`       | Pipeline stage: `ingress`, `egress`, or `pre_ingress` |
| `ports`       | List of ports or port-channels the table is bound to |
| `policy_desc` | Optional human-readable description |

**`ACL_RULE`** — defines individual rules within a table:

```json
{
    "ACL_RULE": {
        "DATAACL|RULE_10": {
            "PRIORITY": "10",
            "SRC_IP": "10.0.0.0/8",
            "DST_IP": "192.168.1.0/24",
            "IP_PROTOCOL": "6",
            "L4_DST_PORT": "80",
            "PACKET_ACTION": "DROP"
        },
        "DATAACL|RULE_20": {
            "PRIORITY": "20",
            "SRC_IP": "172.16.0.0/12",
            "PACKET_ACTION": "FORWARD"
        }
    }
}
```

The key format is `<table_name>|<rule_name>`. Each rule specifies a priority (higher wins), one or more match fields, and an action.

### Table Types

Each ACL table has a **type** that defines which match fields and actions the table supports. The type is set at table creation and cannot be changed afterward. `AclOrch` registers these types at initialization via `initDefaultTableTypes()`:

| Type | Match fields | Typical use |
|------|-------------|-------------|
| `L3` | IPv4 src/dst, IP protocol, L4 ports, TCP flags, ICMP type/code, DSCP, EtherType, VLAN ID | General IPv4 packet filtering |
| `L3V6` | IPv6 src/dst, next header, L4 ports, TCP flags, ICMPv6 type/code, VLAN ID | General IPv6 packet filtering |
| `L3V4V6` | Combined L3 + L3V6 fields, plus IN_PORTS | Dual-stack filtering (platform-dependent) |
| `MIRROR` | Same as L3 | IPv4 traffic mirroring to an ERSPAN (Encapsulated Remote Switched Port Analyzer) session |
| `MIRRORV6` | Same as L3V6 | IPv6 traffic mirroring |
| `MIRROR_DSCP` | DSCP | Mirror traffic based on DSCP value |
| `PFCWD` | TC (traffic class) | PFC watchdog — drop or forward PFC-stormed queues |
| `MCLAG` | Same as L3 | MCLAG-specific filtering |
| `DROP` | L3 + L3V6 fields, IN/OUT ports | Explicit drop rules |

> **Custom table types.** Operators can define their own table types via the `ACL_TABLE_TYPE` CONFIG_DB table, specifying arbitrary combinations of match fields, actions, and bind point types. `AclOrch` processes these through `doAclTableTypeTask()`.

Some table types are platform-dependent. For example, `L3V4V6` (combined IPv4/IPv6 in a single table) is only supported on Marvell Memory, XS, CLX, and virtual switch platforms. On other platforms, operators must use separate `L3` and `L3V6` tables. `AclOrch` queries these capabilities at startup and publishes them to STATE_DB.

### Pipeline Stages

ACL tables operate at one of three points in the forwarding pipeline:

| Stage | SAI Constant | When it runs |
|-------|-------------|-------------|
| **Ingress** | `SAI_ACL_STAGE_INGRESS` | After the ingress parser but before forwarding lookup — the most common stage for security ACLs |
| **Egress** | `SAI_ACL_STAGE_EGRESS` | After the forwarding decision, before the packet leaves the egress port — used for egress filtering or DSCP remarking |
| **Pre-ingress** | `SAI_ACL_STAGE_PRE_INGRESS` | Before the main ingress pipeline — used for early classification before standard L2/L3 processing |

Not every ASIC supports all three stages. The available stages and their supported actions vary by vendor — `AclOrch` queries these capabilities via `queryAclActionCapability()` at startup.

### Match Fields

Each ACL rule specifies one or more match fields. The full set of supported fields (defined in `aclorch.h`) maps SONiC field names to SAI entry attributes:

| Layer | SONiC Field | What It Matches |
|-------|-------------|-----------------|
| **L2** | `ETHER_TYPE` | EtherType (e.g., `0x0800` for IPv4, `0x86DD` for IPv6) |
| **L2** | `VLAN_ID` | Outer VLAN tag |
| **L3** | `SRC_IP` / `DST_IP` | IPv4 source / destination (prefix or host) |
| **L3** | `SRC_IPV6` / `DST_IPV6` | IPv6 source / destination |
| **L3** | `IP_PROTOCOL` | IP protocol number (6 = TCP, 17 = UDP, 1 = ICMP) |
| **L3** | `DSCP` | Differentiated Services Code Point |
| **L4** | `L4_SRC_PORT` / `L4_DST_PORT` | TCP/UDP source / destination port |
| **L4** | `L4_SRC_PORT_RANGE` / `L4_DST_PORT_RANGE` | Port range (e.g., `1024-65535`) |
| **L4** | `TCP_FLAGS` | TCP flag bitmask (SYN, ACK, FIN, etc.) |
| **ICMP** | `ICMP_TYPE` / `ICMP_CODE` | ICMP type and code |
| **ICMP** | `ICMPV6_TYPE` / `ICMPV6_CODE` | ICMPv6 type and code |
| **Tunnel** | `TUNNEL_VNI` | VxLAN Network Identifier |
| **Tunnel** | `INNER_ETHER_TYPE`, `INNER_IP_PROTOCOL`, `INNER_L4_SRC_PORT`, `INNER_L4_DST_PORT` | Inner packet headers (for tunneled traffic) |
| **Port** | `IN_PORTS` / `OUT_PORT` / `OUT_PORTS` | Ingress or egress port(s) |

Port ranges are implemented using **SAI ACL range objects** (`sai_acl_range_t`), which the ASIC evaluates in hardware. `AclOrch` manages range object lifecycle and reference counting — if multiple rules use the same range, they share a single SAI range object.

### Actions

Each rule has exactly one primary action:

| SONiC Action | SAI Constant | Effect |
|-------------|-------------|--------|
| `FORWARD` | `SAI_PACKET_ACTION_FORWARD` | Permit the packet (continue forwarding) |
| `DROP` | `SAI_PACKET_ACTION_DROP` | Silently discard the packet |
| `COPY` | `SAI_PACKET_ACTION_COPY` | Send a copy to the CPU while forwarding the original (see [ACL-Based Trapping](21_punting.md#acl-based-trapping)) |
| `REDIRECT` | `SAI_ACL_ENTRY_ATTR_ACTION_REDIRECT` | Redirect to a specific next hop, next-hop group, or port |
| `DO_NOT_NAT` | — | Exempt the packet from NAT (Network Address Translation) processing |

Additional actions can be combined with the primary action:

- **Mirror** (`MIRROR_ACTION`, `MIRROR_INGRESS_ACTION`, `MIRROR_EGRESS_ACTION`) — copy the packet to a mirror session (ERSPAN or local SPAN).
- **DSCP remarking** (`DSCP_ACTION`) — set a new DSCP value on the packet.
- **Counter** (`COUNTER`) — enable per-rule hit counting (enabled by default for most rule types).

### SAI ACL Object Model

Before walking through how `AclOrch` programs ACL rules, it helps to understand the SAI objects it creates. The SAI ACL subsystem uses a layered object model:

```
Port / LAG / Switch            (bind point — where ACLs attach)
  └── ACL Table Group          (per bind point, per stage)
        └── ACL Table Group Member   (links table to group, carries priority)
              └── ACL Table          (defines match fields and stage)
                    └── ACL Entry    (one per rule — match + action + priority)
                          ├── ACL Range      (for port range matches)
                          └── ACL Counter    (hit counter)
```

- **Bind point** — the attachment target for an ACL: a port, LAG, or the switch as a whole. A bind point is a SAI concept that defines *where* in the system an ACL group takes effect.
- **ACL Table Group** — a container attached to a bind point at a specific stage (ingress, egress, or pre-ingress). Multiple tables can be bound to the same bind point by placing them in the same group, each with a different priority via the group member.
- **ACL Table** — defines the set of match fields the ASIC must support for entries in this table. All entries in a table share the same match-field schema.
- **ACL Entry** — a single rule with match criteria, an action, and a priority. The ASIC evaluates entries within a table by priority.
- **ACL Range** — a reusable object representing a numeric range (e.g., L4 port range 1024–65535). Referenced by entries that need range matching.
- **ACL Counter** — tracks packets and/or bytes matched by an entry.

### The AclOrch Programming Pipeline

`AclOrch` subscribes to **both** CONFIG_DB and APPL_DB for ACL tables and rules. This dual-source design allows ACLs to come from the operator (CONFIG_DB) or from applications like PBH (Policy-Based Hashing) via APPL_DB:

```
CONFIG_DB                          APPL_DB
  ACL_TABLE_TYPE ─┐                  ACL_TABLE_TYPE ─┐
  ACL_TABLE ──────┤                  ACL_TABLE ──────┤
  ACL_RULE ───────┘                  ACL_RULE ───────┘
                   ╲                               ╱
                    ╲                             ╱
                     ▼                           ▼
                          AclOrch (orchagent)
                                │
                           SAI ACL API
                                │
                            ASIC_DB
                                │
                              syncd
                                │
                           Vendor SDK
                                │
                               ASIC
```

When `AclOrch` processes a new ACL table entry, it walks the SAI object hierarchy described above:

1. **Parses the table attributes** — type, stage, port list, and description.
2. **Resolves the table type** — looks up the type name in its registered types (built-in or custom) to determine match fields, actions, and bind point types.
3. **Creates a SAI ACL table** — calls `sai_acl_api->create_acl_table()` with the stage, bind points, and match field list.
4. **Binds the table to ports** — for each port in the table's port list, creates an ACL table group (if one doesn't exist for that bind point and stage), adds the table as a group member, and binds the group to the port via `sai_port_api->set_port_attribute()`.

When a rule is added:

1. **Parses match fields and actions** — validates each field against the table's type.
2. **Creates SAI ACL range objects** (if port ranges are used) — shared across rules via reference counting.
3. **Creates a SAI ACL entry** — calls `sai_acl_api->create_acl_entry()` with the table OID (Object Identifier — the unique handle SAI uses to reference the table), priority, match fields, and actions.
4. **Creates a counter** — binds a SAI counter to the entry for hit tracking.
5. **Registers with flex counters** — the counter is polled periodically and published to COUNTERS_DB.

### ACL Counters

`AclOrch` creates a SAI counter for each ACL entry by default and registers it with the [flex counter](16_flex_counters.md) infrastructure under the `ACL_STAT_COUNTER` group. The counters are polled every 10 seconds (configurable) and the results are published to `COUNTERS_DB`. The counter-to-rule mapping is stored in `COUNTERS_DB`'s `ACL_COUNTER_RULE_MAP` table.

Operators can view per-rule hit counts using:

```bash
aclshow -a          # show all ACL rules with hit counts
```


## Control-Plane ACLs (caclmgrd)

Control-plane ACLs protect the switch's own management services — SSH, SNMP, NTP, and others — by filtering traffic destined for the CPU's Linux network stack. Unlike data-plane ACLs, these rules are **not** programmed into the ASIC. They are implemented as Linux `iptables` and `ip6tables` rules running in the kernel.

### Why a Separate Mechanism?

[CoPP](21_punting.md#copp--control-plane-policing) rate-limits punted traffic inside the ASIC to prevent CPU overload, but it does not perform source-based filtering — it cannot express a policy like "allow SSH only from 10.0.0.0/8." That kind of per-source, per-service access control requires inspecting the packet after it arrives at the CPU, which is exactly what `iptables` does. Control-plane ACLs fill this gap.

### How caclmgrd Works

`caclmgrd` (Control-plane ACL Manager Daemon) runs as a host service in `sonic-host-services`. It is a Python daemon that:

1. **Reads CONFIG_DB** — subscribes to `ACL_TABLE` and `ACL_RULE` tables, filtering for entries where `type = CTRLPLANE`.
2. **Translates rules to iptables commands** — each ACL rule becomes one or more `iptables` / `ip6tables` commands with the appropriate `-s` (source), `-p` (protocol), `--dport` (destination port), and `-j` (action) flags.
3. **Applies the rules** — runs the generated iptables commands to install them in the kernel.
4. **Listens for changes** — monitors CONFIG_DB for updates and re-applies the full rule set when changes are detected. It debounces rapid changes (0.5-second delay) to avoid unnecessary iptables churn.

### CTRLPLANE Table Structure

A control-plane ACL table uses `"type": "CTRLPLANE"` and adds a `services` field that identifies which management protocol the table protects:

```json
{
    "ACL_TABLE": {
        "SSH_ONLY": {
            "type": "CTRLPLANE",
            "services": ["SSH"],
            "policy_desc": "Allow SSH from management subnet only"
        }
    },
    "ACL_RULE": {
        "SSH_ONLY|RULE_1": {
            "PRIORITY": "100",
            "SRC_IP": "10.0.0.0/8",
            "PACKET_ACTION": "ACCEPT"
        },
        "SSH_ONLY|RULE_2": {
            "PRIORITY": "1",
            "SRC_IP": "0.0.0.0/0",
            "PACKET_ACTION": "DROP"
        }
    }
}
```

The `services` field maps to `caclmgrd`'s built-in service definitions, which supply the default IP protocol and destination port:

| Service | Protocol | Port(s) |
|---------|----------|---------|
| SSH | TCP | 22 |
| SNMP | TCP, UDP | 161 |
| NTP | UDP | 123 |
| EXTERNAL_CLIENT | TCP | (from rule) |
| ANY | any | all |

### What caclmgrd Generates

At startup, `caclmgrd` builds a complete iptables rule set for each namespace:

1. **Default policies** — set INPUT, FORWARD, OUTPUT to ACCEPT (safe baseline before flushing).
2. **Flush existing rules** — clear all chains to start clean.
3. **Allow localhost** — accept all traffic from 127.0.0.1 / ::1 on loopback.
4. **Allow established connections** — accept packets from already-established TCP sessions.
5. **Allow essential protocols** — ICMP (ping, traceroute), ICMPv6 (NDP — Neighbor Discovery Protocol — for neighbor solicitation/advertisement), DHCP, BGP.
6. **Apply user-defined rules** — translate each CTRLPLANE ACL rule into an iptables command.
7. **Block ip2me traffic** — drop all remaining packets destined for the switch's own interface IPs (the final default-deny).

This ordering ensures that essential protocols are never accidentally blocked, even if the operator's ACL rules are incomplete.

### Multi-ASIC Support

On multi-ASIC platforms, `caclmgrd` generates additional NAT rules — DNAT (Destination NAT) and SNAT (Source NAT) — to forward management traffic arriving on front-panel interfaces in ASIC namespaces to the host namespace where the management services run.


## Data-Plane vs Control-Plane: When to Use Which

| Scenario | Use |
|----------|-----|
| Block transit traffic from a source prefix | Data-plane ACL (`L3`, ingress) |
| Mirror specific flows to a monitoring port | Data-plane ACL (`MIRROR`, ingress) |
| Allow SSH only from the management subnet | Control-plane ACL (`CTRLPLANE`, service SSH) |
| Remark DSCP for traffic entering the network | Data-plane ACL (`L3`, ingress, with `DSCP_ACTION`) |
| Drop traffic with specific TCP flags (SYN flood) | Data-plane ACL (`L3`, ingress) |
| Rate-limit punted traffic (BGP, ARP, LLDP) | Not ACL — use [CoPP](21_punting.md#copp--control-plane-policing) instead |
| Punt custom traffic to the CPU | Data-plane ACL with `COPY` action (see [ACL-Based Trapping](21_punting.md#acl-based-trapping)) |

---

**Previous**: [← The Forwarding Chain](19_forwarding_chain.md) · **Next**: [Punting →](21_punting.md)
