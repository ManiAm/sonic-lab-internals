# Ports, Interfaces, and Neighbors

> **Prerequisites**: [Orchagent Deep Dive](12_orchagent.md) — the select loop, `m_orchList` ordering, and `doTask()`. [The SAI Object Model](14_sai_object_model.md) — object IDs, entry keys, and the four operations.

Before a route can be programmed into the ASIC, the lower-level objects it depends on must already exist. A route entry points to a next hop. A next hop references a router interface. A router interface sits on top of a port. This document covers these foundational SAI objects — ports, router interfaces, and neighbors — and the three orchagent modules that manage them: `PortsOrch`, `IntfsOrch`, and `NeighOrch`.


## The Forwarding Object Chain

Every IP packet that the ASIC forwards at line rate traverses a chain of SAI objects. Each object in the chain references the one below it:

```
Route Entry          "to reach 10.1.0.0/24, use this next hop"
    │
    ▼
Next Hop             "forward via 10.0.0.2 on this RIF"
    │
    ▼
Router Interface     "L3 interface on Ethernet0"
    │
    ▼
   Port              "physical Ethernet0, 100G"
```

> When a route has **multiple equal-cost paths**, the route entry points to a next-hop group instead of a single next hop. The group and its members are covered in [Load Balancing](20_load_balancing.md) and [SAI Next-Hop Group Types](21_nhg_types.md).

The orchagent modules that manage these objects must run in dependency order. This is enforced by the [`m_orchList`](12_orchagent.md#the-main-select-loop) ordering:

```
SwitchOrch → PortsOrch → IntfsOrch → NeighOrch → NhgOrch → RouteOrch
```

Each module depends on SAI objects created by the modules to its left: you cannot create a RIF on a port that does not exist, and you cannot create a neighbor on a RIF that does not exist.


## Ports (PortsOrch)

A port is the most fundamental SAI object — it represents a physical or logical Ethernet interface on the switch.

### Port Objects in SAI

Unlike most SAI objects that orchagent creates on demand, port objects **already exist** when the switch initializes. During `sai_switch_api->create_switch()`, the SAI implementation discovers the ASIC's physical ports and pre-creates a `SAI_OBJECT_TYPE_PORT` for each one. Orchagent retrieves the full list via `SAI_SWITCH_ATTR_PORT_LIST`:

```c
sai_attribute_t attr;
attr.id = SAI_SWITCH_ATTR_PORT_LIST;
attr.value.objlist.count = port_count;
attr.value.objlist.list  = port_oid_array;
sai_switch_api->get_switch_attribute(switch_id, 1, &attr);
```

`PortsOrch` then **configures** each pre-existing port with the desired attributes:

| SAI Attribute | Purpose | Example |
|---|---|---|
| `SAI_PORT_ATTR_ADMIN_STATE` | Enable or disable the port | `true` |
| `SAI_PORT_ATTR_SPEED` | Link speed in Mbps | `100000` (100G) |
| `SAI_PORT_ATTR_MTU` | Maximum transmission unit | `9100` |
| `SAI_PORT_ATTR_FEC_MODE` | Forward error correction | `RS` |
| `SAI_PORT_ATTR_HW_LANE_LIST` | Physical SerDes lanes | `{0, 1, 2, 3}` |

### Port Initialization Pipeline

Port configuration flows through a multi-stage pipeline before reaching the ASIC:

```
CONFIG_DB                    APPL_DB                      ASIC
PORT|Ethernet0               PORT_TABLE:Ethernet0
  speed: 100000     ──►        speed: 100000      ──►    SAI port configured
  mtu: 9100        portmgrd    mtu: 9100          PortsOrch  (admin_state, speed,
  admin_status: up  portsyncd  admin_status: up              mtu, fec, lanes)
```

Two processes participate in this stage:

- **`portmgrd`** (manager daemon) — subscribes to CONFIG_DB's `PORT` table, applies admin state and MTU to the Linux kernel, and writes processed state to APPL_DB.
- **`portsyncd`** (sync daemon) — reads the `PORT` table from CONFIG_DB and publishes it to APPL_DB's `PORT_TABLE`. It also listens for kernel netlink events to track port state changes.

`PortsOrch` consumes `PORT_TABLE` from APPL_DB and calls `sai_port_api->set_port_attribute()` to configure each port in the ASIC.

### The PortInitDone Signal

Orchagent cannot process routes, interfaces, or neighbors until all ports are ready. The initialization handshake works as follows:

1. `portsyncd` reads every entry from the CONFIG_DB `PORT` table and writes them to APPL_DB.
2. Once all ports have been written, `portsyncd` publishes a **`PortInitDone`** flag to APPL_DB.
3. Orchagent's main thread blocks until it sees `PortInitDone`, then begins processing all other APPL_DB tables.

This guarantees that port OIDs are available before any downstream Orch (IntfsOrch, NeighOrch, etc.) tries to reference them.

### Host Interfaces

For each physical port, `PortsOrch` also creates a **host interface** (`SAI_OBJECT_TYPE_HOSTIF`). This SAI object connects the ASIC port to a Linux network device (netdev), allowing the CPU to send and receive packets on that port — for example, ARP requests, BGP control packets, or LLDP frames.

```c
sai_attribute_t hostif_attrs[3];
hostif_attrs[0].id        = SAI_HOSTIF_ATTR_TYPE;
hostif_attrs[0].value.s32 = SAI_HOSTIF_TYPE_NETDEV;
hostif_attrs[1].id        = SAI_HOSTIF_ATTR_OBJ_ID;
hostif_attrs[1].value.oid = port_oid;             /* link to the SAI port */
hostif_attrs[2].id        = SAI_HOSTIF_ATTR_NAME;
strncpy(hostif_attrs[2].value.chardata, "Ethernet0", SAI_HOSTIF_NAME_SIZE);
sai_hostif_api->create_hostif(&hostif_oid, switch_id, 3, hostif_attrs);
```

After this call, a Linux netdev named `Ethernet0` appears in the kernel. Packets arriving on the physical port that are destined for the CPU (control-plane traffic) are delivered through this netdev, and packets the CPU sends out through `Ethernet0` are transmitted on the physical port.


## Router Interfaces (IntfsOrch)

### The L2-to-L3 Transition

A freshly initialized port is a **Layer 2** object — it can participate in bridging (VLANs, MAC learning, spanning tree) but the ASIC will not route IP packets through it. To make a port participate in IP routing, the ASIC needs a **Router Interface (RIF)** — a `SAI_OBJECT_TYPE_ROUTER_INTERFACE` — placed on top of the port.

The RIF is what connects the port to the router's IP forwarding engine. It tells the ASIC: "this port has an IP identity; packets arriving here should be routed, not just bridged."

### What Triggers RIF Creation

Assigning an IP address to an interface is what triggers the creation of a RIF. When an operator runs:

```bash
config interface ip add Ethernet0 10.0.0.1/31
```

This writes to CONFIG_DB's `INTERFACE` table. The `intfmgrd` manager daemon picks up the change, assigns the IP address in the Linux kernel, and writes the interface entry to APPL_DB's `INTF_TABLE`. `IntfsOrch` then creates the RIF in the ASIC:

```
CONFIG_DB                         APPL_DB                        ASIC
INTERFACE|Ethernet0|10.0.0.1/31   INTF_TABLE:Ethernet0
                          ──►       → IntfsOrch creates RIF     ──►  SAI_OBJECT_TYPE_ROUTER_INTERFACE
 intfmgrd                                                              type: PORT
                                                                       port_id: <port_oid>
                                                                       vr_id: <default_vr_oid>
```

### RIF Types

`IntfsOrch` creates RIFs using the following SAI types, depending on the underlying interface:

| SAI RIF Type | Underlying Object | When It Is Used |
|---|---|---|
| `PORT` | A physical port OID | IP address assigned to a physical interface (e.g., `Ethernet0`). |
| `PORT` | A LAG OID | IP address assigned to a LAG interface (e.g., `PortChannel1`). SAI uses the same `PORT` type — the `PORT_ID` attribute simply points to the LAG OID instead of a physical port OID. |
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

The `SRC_MAC_ADDRESS` attribute is important: when the ASIC routes a packet out through this RIF, it rewrites the packet's source MAC to this value (and the destination MAC to the next hop's MAC, learned via ARP/NDP). This is the standard IP routing behavior — each hop rewrites the L2 header while preserving the L3 header.


## Neighbors and Next Hops (NeighOrch)

### What a Neighbor Is

A **neighbor** is a device directly reachable on a connected link — one IP hop away. The switch needs to know the neighbor's MAC address so it can construct the correct L2 header when forwarding packets toward it. This IP-to-MAC binding is called an **adjacency**.

- **IPv4** uses ARP (Address Resolution Protocol) to discover neighbors.
- **IPv6** uses NDP (Neighbor Discovery Protocol).

### How Neighbors Are Learned

Neighbors reach `NeighOrch` through two paths:

**Dynamic neighbors** (the common case) — The Linux kernel learns a neighbor through ARP or NDP. The `neighsyncd` sync daemon (in the SWSS container) listens for kernel neighbor netlink events and writes each learned neighbor to APPL_DB:

```
Kernel ARP table                     APPL_DB
10.0.0.2 → aa:bb:cc:dd:ee:ff        NEIGH_TABLE:Ethernet0:10.0.0.2
  (learned via ARP)      ──►           family: IPv4
                        neighsyncd     neigh: aa:bb:cc:dd:ee:ff
```

**Static neighbors** — An operator configures a fixed neighbor entry in CONFIG_DB's `NEIGH` table. The `nbrmgrd` manager daemon processes it and writes it to APPL_DB's `NEIGH_TABLE`, following the same path as dynamic entries from that point on.

### SAI Objects: Neighbor Entry and Next Hop

`NeighOrch` creates **two** SAI objects for each neighbor — this is a critical detail for understanding the forwarding chain:

1. **Neighbor Entry** (`SAI_OBJECT_TYPE_NEIGHBOR_ENTRY`) — Tells the ASIC the MAC address to use when sending packets to this IP on this RIF. This is an entry-key object (not OID-based), keyed by `{switch_id, rif_oid, ip_address}`.

2. **Next Hop** (`SAI_OBJECT_TYPE_NEXT_HOP`) — An OID-based object that represents a forwarding destination. Routes and next-hop group members reference this object. Its key attributes are the neighbor's IP address and the RIF it is reachable through.

Why two objects? Because they serve different purposes in the ASIC:
- The **neighbor entry** populates the ASIC's **adjacency table** — it answers "what MAC do I rewrite the packet with?"
- The **next hop** is a **forwarding target** — it answers "where do I send packets?" and is what route entries and NHG members point to.

### SAI Calls

```c
/* 1. Create the neighbor entry — programs the adjacency table */
sai_neighbor_entry_t nbr_entry;
nbr_entry.switch_id        = switch_id;
nbr_entry.rif_id           = rif_oid;               /* the RIF on Ethernet0 */
nbr_entry.ip_address       = sai_ip(10.0.0.2);      /* neighbor IP */

sai_attribute_t nbr_attr;
nbr_attr.id                = SAI_NEIGHBOR_ENTRY_ATTR_DST_MAC_ADDRESS;
memcpy(nbr_attr.value.mac, "aa:bb:cc:dd:ee:ff", 6); /* learned via ARP */
sai_neighbor_api->create_neighbor_entry(&nbr_entry, 1, &nbr_attr);

/* 2. Create the next hop — a target that routes can point to */
sai_attribute_t nh_attrs[3];
nh_attrs[0].id        = SAI_NEXT_HOP_ATTR_TYPE;
nh_attrs[0].value.s32 = SAI_NEXT_HOP_TYPE_IP;
nh_attrs[1].id        = SAI_NEXT_HOP_ATTR_IP;
nh_attrs[1].value.ipaddr = sai_ip(10.0.0.2);        /* same neighbor IP */
nh_attrs[2].id        = SAI_NEXT_HOP_ATTR_ROUTER_INTERFACE_ID;
nh_attrs[2].value.oid = rif_oid;                     /* same RIF */
sai_next_hop_api->create_next_hop(&nh_oid, switch_id, 3, nh_attrs);
```

The `nh_oid` returned by the second call is the forwarding target that the rest of the system references. For a single-path route, `RouteOrch` sets `SAI_ROUTE_ENTRY_ATTR_NEXT_HOP_ID` directly to this OID. For multi-path ECMP routes, `RouteOrch` or `NhgOrch` creates a next-hop group member with `SAI_NEXT_HOP_GROUP_MEMBER_ATTR_NEXT_HOP_ID` pointing to this OID — the member is the join object that attaches the next hop to the group (see the [next-hop group diagram](20_load_balancing.md)).


## Putting It All Together

To see how the entire chain is built, consider a concrete scenario: an operator configures `Ethernet0` with IP `10.0.0.1/31`, the switch learns neighbor `10.0.0.2` via ARP, and BGP advertises a route to `10.1.0.0/24` via `10.0.0.2`.

**Step 1 — Port** (boot time, `PortsOrch`):

The ASIC's physical port for `Ethernet0` is configured with speed, MTU, and admin state. A host interface is created so the CPU can send and receive control traffic on this port. At this point, the port is Layer 2 only.

**Step 2 — Router Interface** (IP assignment, `IntfsOrch`):

The operator runs `config interface ip add Ethernet0 10.0.0.1/31`. This triggers `intfmgrd` → APPL_DB → `IntfsOrch`, which creates a `SAI_OBJECT_TYPE_ROUTER_INTERFACE` of type `PORT` on the port's OID. The port is now Layer 3 — the ASIC will route IP packets through it.

**Step 3 — Neighbor + Next Hop** (ARP resolution, `NeighOrch`):

The kernel sends an ARP request for `10.0.0.2` and receives a reply with MAC `aa:bb:cc:dd:ee:ff`. `neighsyncd` writes this to APPL_DB. `NeighOrch` creates a `SAI_OBJECT_TYPE_NEIGHBOR_ENTRY` (for MAC rewriting) and a `SAI_OBJECT_TYPE_NEXT_HOP` (as a forwarding target).

**Step 4 — Route** (BGP update, `RouteOrch`):

FRR receives a BGP update for `10.1.0.0/24` via `10.0.0.2`. `fpmsyncd` writes it to APPL_DB. `RouteOrch` looks up the next-hop OID for `10.0.0.2` (created in step 3) and creates a `SAI_OBJECT_TYPE_ROUTE_ENTRY` pointing to it.

The resulting SAI object chain in the ASIC:

```
SAI_ROUTE_ENTRY { dest: 10.1.0.0/24 }
    NEXT_HOP_ID ──► SAI_NEXT_HOP { ip: 10.0.0.2, rif: rif_oid }
                                          │
                         ┌────────────────┘
                         ▼
               SAI_ROUTER_INTERFACE { type: PORT, port: port_oid }
                         │
                         ▼
               SAI_PORT { speed: 100G, admin: up }

SAI_NEIGHBOR_ENTRY { rif: rif_oid, ip: 10.0.0.2 }
    DST_MAC ──► aa:bb:cc:dd:ee:ff   (used to rewrite L2 header on egress)
```

When a packet destined for `10.1.0.0/24` arrives at the switch, the ASIC:
1. Matches the destination IP against the route entry → finds the next-hop OID.
2. Follows the next hop to the RIF → determines the egress port.
3. Looks up the neighbor entry for `10.0.0.2` on that RIF → gets the destination MAC.
4. Rewrites the L2 header (source MAC from the RIF, destination MAC from the neighbor), decrements the TTL, and sends the packet out `Ethernet0`.


## Summary

| SAI Object | Created By | Triggered When | Key Attributes |
|---|---|---|---|
| Port | ASIC init + `PortsOrch` configures | Switch boot | Speed, MTU, admin state, lanes |
| Host Interface | `PortsOrch` | Switch boot | Type (netdev), port OID, name |
| Router Interface | `IntfsOrch` | IP address assigned to interface | Type, port/VLAN OID, virtual router, source MAC |
| Neighbor Entry | `NeighOrch` | ARP/NDP learned or static config | RIF, IP address, destination MAC |
| Next Hop | `NeighOrch` | Same as neighbor | Type (IP), IP address, RIF |

The dependency chain flows strictly downward: removing a port requires first removing its RIF, which requires first removing all neighbors on it, which requires first removing all next hops (and by extension, all NHG members and routes that reference them). This bottom-up creation and top-down teardown order is fundamental to SAI programming.

---

**Previous**: [← Flex Counter Groups Reference](16_flex_counter_groups_reference.md) · **Next**: [The BGP Container and FRR →](18_bgp_container.md)
