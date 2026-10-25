# The Forwarding Chain

> **Prerequisites**: [Ports and Host Interfaces](17_ports_and_host_interfaces.md) — port initialization, host interfaces, and the data-plane vs control-plane distinction. [The SAI Object Model](14_sai_object_model.md) — object IDs, entry keys, and the four operations.

A **port** is the bottom of the forwarding chain — it represents a physical (or logical) Ethernet interface on the switch (e.g., `Ethernet8` at 100G). At boot time, ports are Layer 2 (L2) objects: they can bridge traffic but cannot route IP packets. Port initialization — how `PortsOrch` creates SAI port objects and host interfaces — is covered in the [previous document](17_ports_and_host_interfaces.md).

To participate in IP routing, a port must be promoted to Layer 3. That is the job of the **router interface**.


## Router Interfaces (IntfsOrch)

Assigning an IP address to a port triggers the creation of a `SAI_OBJECT_TYPE_ROUTER_INTERFACE` — the SAI object that promotes the port from L2 to L3. A RIF connects the port to the IP forwarding engine: it binds the port to a virtual router (VRF), assigns a source MAC address (typically the switch's base MAC) that the ASIC writes into every routed packet's L2 header on egress, and enables independent control of IPv4 and IPv6 routing.

### What Triggers RIF Creation

When an operator runs:

```bash
config interface ip add Ethernet8 10.0.0.201/30
```

This writes **two entries** to CONFIG_DB's `INTERFACE` table — a general entry (`INTERFACE|Ethernet8`) and an address entry (`INTERFACE|Ethernet8|10.0.0.201/30`). From there, the configuration flows through four steps:

1. **`intfmgrd` processes the general entry** — It reads `INTERFACE|Ethernet8` from CONFIG_DB, checks that the port is ready (via STATE_DB), applies interface-level settings (VRF, MAC, MPLS) to the Linux kernel, and writes `INTF_TABLE:Ethernet8` to APPL_DB.

2. **`intfmgrd` processes the address entry** — It reads `INTERFACE|Ethernet8|10.0.0.201/30`, waits until the general entry from step 1 is complete (`isIntfCreated`), then runs `ip address add 10.0.0.201/30 dev Ethernet8` in the kernel and writes `INTF_TABLE:Ethernet8:10.0.0.201/30` to APPL_DB.

3. **`IntfsOrch` creates the RIF** — It picks up `INTF_TABLE:Ethernet8` (no IP prefix in the key), calls `addRouterIntfs()`, and programs a `SAI_OBJECT_TYPE_ROUTER_INTERFACE` in the ASIC with the port OID, VRF, source MAC, and MTU.

4. **`IntfsOrch` adds an IP-to-me route** — It picks up `INTF_TABLE:Ethernet8:10.0.0.201/30` (IP prefix in the key), calls `addIp2MeRoute()`, and programs a `/32` host route that directs packets addressed to `10.0.0.201` to the CPU for local processing.

```mermaid
sequenceDiagram
    participant CLI as Operator (CLI)
    participant CDB as CONFIG_DB
    participant MGR as intfmgrd
    participant KER as Linux Kernel
    participant SDB as STATE_DB
    participant ADB as APPL_DB
    participant ORCH as IntfsOrch
    participant SAI as SAI / ASIC

    CLI->>CDB: SET INTERFACE|Ethernet8<br/>SET INTERFACE|Ethernet8|10.0.0.201/30

    Note over CDB,MGR: Step 1 — General entry (interface-level)
    CDB->>MGR: INTERFACE|Ethernet8 (SubscriberStateTable)
    MGR->>SDB: check PORT_TABLE|Ethernet8 (port state ok?)
    SDB-->>MGR: state: ok
    MGR->>KER: set VRF, MAC, MPLS, admin state
    MGR->>ADB: SET INTF_TABLE:Ethernet8
    MGR->>SDB: SET INTERFACE|Ethernet8 (vrf: "")

    Note over CDB,MGR: Step 2 — Address entry (IP-level)
    CDB->>MGR: INTERFACE|Ethernet8|10.0.0.201/30 (SubscriberStateTable)
    MGR->>SDB: check INTERFACE|Ethernet8 exists (isIntfCreated)
    SDB-->>MGR: exists
    MGR->>KER: ip address add 10.0.0.201/30 dev Ethernet8
    MGR->>ADB: SET INTF_TABLE:Ethernet8:10.0.0.201/30<br/>(family: IPv4, scope: global)
    MGR->>SDB: SET INTERFACE|Ethernet8:10.0.0.201/30<br/>(state: ok)

    Note over ADB,ORCH: Step 3 — RIF creation
    ADB->>ORCH: INTF_TABLE:Ethernet8 (no IP prefix)
    ORCH->>ORCH: setIntf() → addRouterIntfs()
    ORCH->>SAI: create_router_interface<br/>(type: PORT, port_id, vr_id, src_mac, mtu)
    SAI-->>ORCH: rif_oid

    Note over ADB,ORCH: Step 4 — IP-to-me route
    ADB->>ORCH: INTF_TABLE:Ethernet8:10.0.0.201/30
    ORCH->>ORCH: setIntf() → addIp2MeRoute()
    ORCH->>SAI: create_route_entry<br/>(10.0.0.201/32 → CPU port)
```

### RIF Types

`IntfsOrch` creates RIFs using the following SAI types, depending on the underlying interface:

| SAI RIF Type | Underlying Object | When It Is Used |
|---|---|---|
| `PORT` | A physical port OID | IP address assigned to a physical interface (e.g., `Ethernet0`). |
| `PORT` | A LAG OID | IP address assigned to a LAG (Link Aggregation Group) interface (e.g., `PortChannel1`). SAI uses the same `PORT` type — the `PORT_ID` attribute simply points to the LAG OID instead of a physical port OID. |
| `VLAN` | A VLAN OID | IP address assigned to a VLAN interface (e.g., `Vlan100`). The RIF enables routing between the VLAN and other L3 domains. |
| `SUB_PORT` | A port OID + VLAN tag | A sub-interface (e.g., `Ethernet0.100`). Isolates traffic by VLAN tag on a single physical port. |

> **Loopback interfaces** (e.g., `Loopback0`) are handled differently. `IntfsOrch` does **not** create a SAI RIF for them — it only tracks them in software and adds IP-to-me routes (local routes that direct packets addressed to the switch's own IP to the CPU). The `SAI_ROUTER_INTERFACE_TYPE_LOOPBACK` type exists in SAI but is used only by tunnel modules (`tunneldecaporch`, `srv6orch`, `muxorch`) for overlay interfaces, not for `Loopback0`.

### RIF Attributes

The attributes below are defined in `sairouterinterface.h`. Mandatory attributes must be supplied at creation; conditional attributes are mandatory only when the RIF type requires them; optional attributes have defaults.

**Mandatory (all RIF types)**:

| Attribute | Type | Flags | Purpose |
|---|---|---|---|
| `VIRTUAL_ROUTER_ID` | OID | Create-only | The VRF this RIF belongs to. Every RIF must reference a virtual router. |
| `TYPE` | Enum | Create-only | The RIF type (`PORT`, `VLAN`, `SUB_PORT`, `LOOPBACK`, `BRIDGE`, `QINQ_PORT`). |

**Conditional (mandatory for specific types)**:

| Attribute | Type | Flags | Required When |
|---|---|---|---|
| `PORT_ID` | OID | Create-only | TYPE is `PORT` or `SUB_PORT`. References a port, LAG, or system port OID. |
| `VLAN_ID` | OID | Create-only | TYPE is `VLAN`. References a VLAN OID. |
| `OUTER_VLAN_ID` | uint16 | Create-only | TYPE is `SUB_PORT` or `QINQ_PORT`. The outer VLAN tag. |
| `INNER_VLAN_ID` | uint16 | Create-only | TYPE is `QINQ_PORT`. The inner VLAN tag. |
| `BRIDGE_ID` | OID | Create-only | TYPE is `BRIDGE`. References a 1D bridge OID. |

**Optional (with defaults)**:

| Attribute | Type | Default | Purpose |
|---|---|---|---|
| `SRC_MAC_ADDRESS` | MAC | Inherited from VR | Source MAC written into routed packets leaving this RIF. |
| `MTU` | uint32 | 1514 | Maximum transmission unit for this RIF. |
| `ADMIN_V4_STATE` | bool | true | Enable/disable IPv4 routing on this RIF. |
| `ADMIN_V6_STATE` | bool | true | Enable/disable IPv6 routing on this RIF. |
| `LOOPBACK_PACKET_ACTION` | enum | FORWARD | Action when a packet is routed back out the same RIF it arrived on. |
| `NEIGHBOR_MISS_PACKET_ACTION` | enum | TRAP | Action when no neighbor entry matches (send to CPU by default). |
| `INGRESS_ACL` / `EGRESS_ACL` | OID | null | Bind an ACL table or group to this RIF. |
| `V4_MCAST_ENABLE` / `V6_MCAST_ENABLE` | bool | false | Enable multicast routing on this RIF. |
| `NAT_ZONE_ID` | uint8 | 0 | NAT zone for this RIF. |
| `DISABLE_DECREMENT_TTL` | bool | false | Skip TTL decrement for routed packets. |
| `ADMIN_MPLS_STATE` | bool | false | Enable MPLS on this RIF. |

### SAI Calls

For a port-type RIF, the two mandatory attributes (`VIRTUAL_ROUTER_ID`, `TYPE`) plus the conditional `PORT_ID` and the optional `SRC_MAC_ADDRESS` are the typical set:

```c
sai_attribute_t rif_attrs[4];
rif_attrs[0].id        = SAI_ROUTER_INTERFACE_ATTR_VIRTUAL_ROUTER_ID;
rif_attrs[0].value.oid = default_vr_oid;           /* mandatory: the VRF */
rif_attrs[1].id        = SAI_ROUTER_INTERFACE_ATTR_TYPE;
rif_attrs[1].value.s32 = SAI_ROUTER_INTERFACE_TYPE_PORT;  /* mandatory: RIF type */
rif_attrs[2].id        = SAI_ROUTER_INTERFACE_ATTR_PORT_ID;
rif_attrs[2].value.oid = port_oid;                 /* conditional: required for PORT type */
rif_attrs[3].id        = SAI_ROUTER_INTERFACE_ATTR_SRC_MAC_ADDRESS;
memcpy(rif_attrs[3].value.mac, switch_mac, 6);     /* optional: defaults to VR's MAC */
sai_router_intfc_api->create_router_interface(&rif_oid, switch_id, 4, rif_attrs);
```

The `SRC_MAC_ADDRESS` attribute determines the source MAC the ASIC writes into routed packets leaving this RIF. On egress, the ASIC rewrites the entire L2 header — source MAC from the RIF, destination MAC from the neighbor entry — while preserving the L3 header (standard hop-by-hop routing behavior).

### Where the Source MAC Comes From

Every Ethernet frame carries a 48-bit (6-byte) source and destination MAC address. To guarantee that every network interface in the world has a globally unique address, the IEEE splits the 48 bits into two halves:

- **First 3 bytes** — the **OUI** (Organizationally Unique Identifier). Any vendor that builds Ethernet devices must register with the IEEE, which assigns them one or more OUIs (e.g., Arista, Mellanox, and Broadcom each have their own).

- **Last 3 bytes** — a device identifier, assigned by the manufacturer to each unit during production, ensuring no two interfaces share the same address.

<img src="../pics/MAC.png" alt="MAC address structure" width="400">

The manufacturer programs a **base MAC address** and a **MAC range** into the switch's system EEPROM at the factory — before the switch ever runs an operating system. You can inspect both with `show platform syseeprom`:

```
admin@sonic:~$ show platform syseeprom

TLV Name             Code      Len  Value
-------------------  ------  -----  ----------------------
Product Name         0x21        5  DX010
Base MAC Address     0x24        6  0C:48:C6:80:4D:1A
MAC Addresses        0x2A        2  131
Manufacturer         0x2B        9  CELESTICA
...
```

This Celestica DX010 has a base MAC of `0C:48:C6:80:4D:1A` with a range of 131 addresses.

### Factory MAC vs Active MAC

Linux network interfaces can have **two** MAC addresses:

| Field | What it is | Mutable? |
|---|---|---|
| **`permaddr`** (permanent address) | A unique per-port MAC allocated from the EEPROM range at the factory | No — read-only, burned into hardware |
| **`link/ether`** (active address) | The MAC currently in use on the wire | Yes — software can override it |

On some platforms and drivers, `ip -d link show` displays both (e.g., `link/ether ... permaddr ...`). On SONiC, the Ethernet netdevs are **hostif interfaces** created by SAI — not traditional NIC interfaces — so `permaddr` is not always separately exposed. What you can always verify is the active MAC:

```
admin@sonic:~$ ip -d link show Ethernet8

26: Ethernet8: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 9100 ...
    link/ether 0c:48:c6:80:4d:1a brd ff:ff:ff:ff:ff:ff ...
```

Every port on the switch uses the same active MAC — the base MAC from the EEPROM:

```
admin@sonic:~$ for port in Ethernet0 Ethernet4 Ethernet8 Ethernet12 Ethernet120 Ethernet124; do
>   echo "$port: $(cat /sys/class/net/$port/address)"
> done

Ethernet0: 0c:48:c6:80:4d:1a
Ethernet4: 0c:48:c6:80:4d:1a
Ethernet8: 0c:48:c6:80:4d:1a
Ethernet12: 0c:48:c6:80:4d:1a
Ethernet120: 0c:48:c6:80:4d:1a
Ethernet124: 0c:48:c6:80:4d:1a
```

All identical — `0c:48:c6:80:4d:1a`. This is the MAC that gets programmed as `SAI_ROUTER_INTERFACE_ATTR_SRC_MAC_ADDRESS` on every RIF. The EEPROM's MAC range provides additional addresses for other uses (management port, CPU port), but SONiC does not allocate unique MACs per front-panel port.

### How SONiC Programs the Source MAC

The base MAC flows from hardware to every RIF through a chain where each level inherits from the one above by default:

```
System EEPROM (factory-programmed)
    │  read at first boot by sonic-cfggen
    ▼
DEVICE_METADATA|localhost.mac           (CONFIG_DB)
    │  read by SwitchOrch at startup
    ▼
SAI_SWITCH_ATTR_SRC_MAC_ADDRESS
    │  inherited by default
    ▼
SAI_VIRTUAL_ROUTER_ATTR_SRC_MAC_ADDRESS
    │  inherited by default
    ▼
SAI_ROUTER_INTERFACE_ATTR_SRC_MAC_ADDRESS
```

You can verify the CONFIG_DB end of this chain:

```
admin@sonic:~$ sonic-cfggen -d -v 'DEVICE_METADATA["localhost"]["mac"]'

0c:48:c6:80:4d:1a
```

This matches the EEPROM — confirming the full path from hardware to software.

Unless explicitly overridden at any level, **every RIF on the switch shares the same source MAC**. This is standard for IP routing: each hop is identified by its IP address, not its MAC, so a single shared MAC is sufficient.

> [`syseepromd`](24_pmon_container.md#syseepromd--system-eeprom-daemon) also reads the EEPROM at boot and publishes the base MAC and other TLV fields (serial number, platform name, vendor) to the `EEPROM_INFO` table in STATE_DB — this path is for monitoring and CLI display (`show platform syseeprom`), not for programming the ASIC. For how `DEVICE_METADATA` is populated during first boot, see [Platform Configuration](25_platform_configuration.md).


## From RIF to Route: The Full Object Chain

With ports promoted to L3 by router interfaces, the switch can route IP packets. But a RIF alone is not enough — the ASIC also needs to know *where* to send packets and *what destination MAC* to write on egress. These answers come from additional SAI objects that chain together above the RIF.

Consider the following topology. This switch has IP `10.0.0.201` on `Ethernet8`, connected to a neighbor at `10.0.0.202` via a point-to-point `/30` link. A remote network, `10.20.0.0/24`, is reachable through that neighbor — the switch learned this via a routing protocol:

<img src="../pics/forwarding-topology.png" alt="Forwarding topology example" width="800">

When a packet destined for `10.20.0.0/24` arrives at this switch, the switch does not need to know the full path to the destination. It only needs to know: **hand this packet to my neighbor `10.0.0.202` — they know how to get it there.** This is hop-by-hop IP routing: each router decides only the next step, not the entire journey.

To make that single hop work, the ASIC needs to know three things: which **port** to send the packet out of, what **source MAC** to write (its own), and what **destination MAC** to write (the neighbor's). SONiC programs this information into the ASIC as a chain of SAI objects — each one references the next — plus a neighbor entry that provides the destination MAC:

<img src="../pics/nh-flow.png" alt="SAI forwarding object chain" width="850">

A **route entry** is the starting point of every forwarding decision. It maps a destination prefix (e.g., `10.20.0.0/24`) to a next-hop object, telling the ASIC "packets matching this prefix should be forwarded through this next hop." When a route has **multiple equal-cost paths**, the route entry points to a next-hop group instead of a single next hop — that is covered in [Load Balancing](22_load_balancing.md).

A **next hop** is the forwarding target that the route entry points to. It combines the neighbor's IP address (`10.0.0.202`) with the RIF it is reachable through, giving the ASIC the information it needs to determine the egress port and look up the destination MAC from the neighbor entry. `NeighOrch` creates a next hop alongside every neighbor entry.

A **neighbor entry** maps the neighbor's IP address to its MAC address, learned through ARP (IPv4) or NDP (IPv6). The IP is the **remote peer's** address and the ASIC looks it up by `{rif, neighbor_ip}` at egress to get the destination MAC for L2 header rewriting.

Each object in this chain must exist before the objects above it can be created. This bottom-up dependency is enforced by the [`m_orchList`](12_orchagent.md#the-main-select-loop) ordering — each module runs only after the modules it depends on:

```
SwitchOrch → PortsOrch → IntfsOrch → NeighOrch → NhgOrch → RouteOrch
```

The rest of this document covers `NeighOrch` — the module that creates neighbor entries and next hops. Route entries and next-hop groups are covered in [Load Balancing](22_load_balancing.md).


## Neighbors and Next Hops (NeighOrch)

### What a Neighbor Is

A **neighbor** is a device directly reachable on a connected link — one IP hop away. The IP-to-MAC binding that the switch needs for L2 header rewriting is called an **adjacency**, discovered at runtime:

- **IPv4** — ARP (Address Resolution Protocol)
- **IPv6** — NDP (Neighbor Discovery Protocol)

### How Neighbors Are Learned

Neighbors reach `NeighOrch` through two paths:

**Dynamic neighbors** (the common case) — The Linux kernel learns a neighbor through ARP or NDP. The `neighsyncd` sync daemon (in the SWSS container) listens for kernel neighbor netlink events and writes each learned neighbor to APPL_DB:

```
Kernel ARP table                     APPL_DB
10.0.0.202 → bb:cc:dd:ee:ff:01        NEIGH_TABLE:Ethernet8:10.0.0.202
  (learned via ARP)      ──►           family: IPv4
                        neighsyncd     neigh: bb:cc:dd:ee:ff:01
```

**Static neighbors** — An operator configures a fixed neighbor entry in CONFIG_DB's `NEIGH` table. The `nbrmgrd` manager daemon processes it and writes it to APPL_DB's `NEIGH_TABLE`, following the same path as dynamic entries from that point on.

### SAI Objects: Neighbor Entry and Next Hop

`NeighOrch` creates **two** SAI objects for each neighbor — this is a critical detail for understanding the forwarding chain:

1. **Neighbor Entry** (`SAI_OBJECT_TYPE_NEIGHBOR_ENTRY`) — Tells the ASIC the MAC address to use when sending packets to this IP on this RIF. This is an entry-key object (not OID-based), keyed by `{switch_id, rif_oid, ip_address}`.

2. **Next Hop** (`SAI_OBJECT_TYPE_NEXT_HOP`) — An OID-based object that represents a forwarding destination. Routes and next-hop group members reference this object. Its key attributes are the neighbor's IP address and the RIF it is reachable through.

Why two objects? Because they serve different purposes in the ASIC:
- The **neighbor entry** populates the ASIC's **adjacency table** — it answers "what MAC do I rewrite the packet with?"
- The **next hop** is a **forwarding target** — it answers "where do I send packets?" and is what route entries and next-hop group members point to.

### SAI Calls

```c
/* 1. Create the neighbor entry — programs the adjacency table */
sai_neighbor_entry_t nbr_entry;
nbr_entry.switch_id        = switch_id;
nbr_entry.rif_id           = rif_oid;               /* the RIF on Ethernet8 */
nbr_entry.ip_address       = sai_ip(10.0.0.202);      /* neighbor IP */

sai_attribute_t nbr_attr;
nbr_attr.id                = SAI_NEIGHBOR_ENTRY_ATTR_DST_MAC_ADDRESS;
memcpy(nbr_attr.value.mac, "bb:cc:dd:ee:ff:01", 6); /* learned via ARP */
sai_neighbor_api->create_neighbor_entry(&nbr_entry, 1, &nbr_attr);

/* 2. Create the next hop — a target that routes can point to */
sai_attribute_t nh_attrs[3];
nh_attrs[0].id        = SAI_NEXT_HOP_ATTR_TYPE;
nh_attrs[0].value.s32 = SAI_NEXT_HOP_TYPE_IP;
nh_attrs[1].id        = SAI_NEXT_HOP_ATTR_IP;
nh_attrs[1].value.ipaddr = sai_ip(10.0.0.202);        /* same neighbor IP */
nh_attrs[2].id        = SAI_NEXT_HOP_ATTR_ROUTER_INTERFACE_ID;
nh_attrs[2].value.oid = rif_oid;                     /* same RIF */
sai_next_hop_api->create_next_hop(&nh_oid, switch_id, 3, nh_attrs);
```

The `nh_oid` returned by the second call is the forwarding target that the rest of the system references. For a single-path route, `RouteOrch` sets `SAI_ROUTE_ENTRY_ATTR_NEXT_HOP_ID` directly to this OID. For multi-path Equal-Cost Multi-Path (ECMP) routes, `RouteOrch` or `NhgOrch` creates a next-hop group member with `SAI_NEXT_HOP_GROUP_MEMBER_ATTR_NEXT_HOP_ID` pointing to this OID — the member is the join object that attaches the next hop to the group (see the [next-hop group diagram](22_load_balancing.md)).


## Putting It All Together

To see how the entire chain is built, consider a concrete scenario: an operator configures `Ethernet8` with IP `10.0.0.201/30`, the switch learns neighbor `10.0.0.202` via ARP, and BGP advertises a route to `10.20.0.0/24` via `10.0.0.202`.

**Step 1 — Port** (boot time, `PortsOrch`):

The ASIC's physical port for `Ethernet8` is configured with speed, MTU, and admin state. A host interface is created so the CPU can send and receive control traffic on this port. At this point, the port is L2 only. (See [Ports and Host Interfaces](17_ports_and_host_interfaces.md) for details.)

**Step 2 — Router Interface** (IP assignment, `IntfsOrch`):

The operator runs `config interface ip add Ethernet8 10.0.0.201/30`. This triggers `intfmgrd` → APPL_DB → `IntfsOrch`, which creates a `SAI_OBJECT_TYPE_ROUTER_INTERFACE` of type `PORT` on the port's OID. The port is now L3 — the ASIC will route IP packets through it.

**Step 3 — Neighbor + Next Hop** (ARP resolution, `NeighOrch`):

The kernel sends an ARP request for `10.0.0.202` and receives a reply with MAC `bb:cc:dd:ee:ff:01`. `neighsyncd` writes this to APPL_DB. `NeighOrch` creates a `SAI_OBJECT_TYPE_NEIGHBOR_ENTRY` (for MAC rewriting) and a `SAI_OBJECT_TYPE_NEXT_HOP` (as a forwarding target).

**Step 4 — Route** (BGP update, `RouteOrch`):

FRR receives a BGP update for `10.20.0.0/24` via `10.0.0.202`. `fpmsyncd` writes it to APPL_DB. `RouteOrch` looks up the next-hop OID for `10.0.0.202` (created in step 3) and creates a `SAI_OBJECT_TYPE_ROUTE_ENTRY` pointing to it.

The resulting SAI object chain in the ASIC:

```
SAI_ROUTE_ENTRY { dest: 10.20.0.0/24 }
    NEXT_HOP_ID ──► SAI_NEXT_HOP { ip: 10.0.0.202, rif: rif_oid }
                                          │
                         ┌────────────────┘
                         ▼
               SAI_ROUTER_INTERFACE { type: PORT, port: port_oid }
                         │
                         ▼
               SAI_PORT { speed: 100G, admin: up }

SAI_NEIGHBOR_ENTRY { rif: rif_oid, ip: 10.0.0.202 }
    DST_MAC ──► bb:cc:dd:ee:ff:01   (used to rewrite L2 header on egress)
```

When a packet destined for `10.20.0.0/24` arrives at the switch, the ASIC:
1. Matches the destination IP against the route entry → finds the next-hop OID.
2. Follows the next hop to the RIF → determines the egress port.
3. Looks up the neighbor entry for `10.0.0.202` on that RIF → gets the destination MAC.
4. Rewrites the L2 header (source MAC from the RIF, destination MAC from the neighbor), decrements the TTL, and sends the packet out `Ethernet8`.


## Summary

| SAI Object | Created By | Triggered When | Key Attributes |
|---|---|---|---|
| Router Interface | `IntfsOrch` | IP address assigned to interface | Type, port/VLAN OID, virtual router, source MAC |
| Neighbor Entry | `NeighOrch` | ARP/NDP learned or static config | RIF, IP address, destination MAC |
| Next Hop | `NeighOrch` | Same as neighbor | Type (IP), IP address, RIF |

The dependency chain flows strictly downward: removing a port requires first removing its RIF, which requires first removing all neighbors on it, which requires first removing all next hops (and by extension, all next-hop group members and routes that reference them). This bottom-up creation and top-down teardown order is fundamental to SAI programming.

---

**Previous**: [← Ports and Host Interfaces](17_ports_and_host_interfaces.md) · **Next**: [Punting →](19_punting.md)
