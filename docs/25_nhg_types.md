# SAI Next-Hop Group Types

> **Prerequisites**: [Load Balancing in SONiC](24_load_balancing.md) — understand SAI next-hop group objects, hash configuration, route programming through `routeorch`, NHG reuse, and member lifecycle before diving into individual group types.

This document covers each SAI next-hop group type in detail: its purpose, configuration (where applicable), and the SAI calls that program it into the ASIC. The [Weighted ECMP](#weighted-ecmp-w-ecmp) section is also included here; although its underlying SAI group type is Dynamic Unordered ECMP, its weight-handling pipeline spans `bgpcfgd`, `fpmsyncd`, and `routeorch` and is best understood alongside the other group types. For the shared route-ingestion and ASIC-programming pipeline, see [Route Programming (routeorch)](24_load_balancing.md#route-programming-routeorch).


## Dynamic Unordered ECMP

This is the default and most widely used group type. No special configuration is required — every multi-path route creates a `DYNAMIC_UNORDERED_ECMP` group unless a more specific type applies. Members form an unordered set; the ASIC hashes each packet and selects a member.

> The word "dynamic" in SAI's naming refers to **membership flexibility** — members can be added or removed at runtime without recreating the group. This contrasts with types like Fine-Grain ECMP, where members are pinned to fixed bucket positions, or ECMP With Members, where the full member list is specified at group creation. It has no relation to adaptive or dynamic routing, which reacts to real-time congestion.

### SAI Calls

```c
/* Group — no extra attributes needed */
sai_attribute_t grp_attr;
grp_attr.id        = SAI_NEXT_HOP_GROUP_ATTR_TYPE;
grp_attr.value.s32 = SAI_NEXT_HOP_GROUP_TYPE_DYNAMIC_UNORDERED_ECMP;
sai_next_hop_group_api->create_next_hop_group(&group_oid, switch_id, 1, &grp_attr);

/* Member (repeated for each path) — WEIGHT is the only member attribute */
sai_attribute_t mbr_attrs[3];
mbr_attrs[0].id        = SAI_NEXT_HOP_GROUP_MEMBER_ATTR_NEXT_HOP_GROUP_ID;
mbr_attrs[0].value.oid = group_oid;
mbr_attrs[1].id        = SAI_NEXT_HOP_GROUP_MEMBER_ATTR_NEXT_HOP_ID;
mbr_attrs[1].value.oid = nh_oid;             /* resolved via neighOrch */
mbr_attrs[2].id        = SAI_NEXT_HOP_GROUP_MEMBER_ATTR_WEIGHT;
mbr_attrs[2].value.u32 = 1;                  /* equal-cost: all members weight 1 */
sai_next_hop_group_api->create_next_hop_group_member(&member_oid, switch_id, 3, mbr_attrs);

/* Route entry — points the prefix at the group */
sai_attribute_t rt_attr;
rt_attr.id        = SAI_ROUTE_ENTRY_ATTR_NEXT_HOP_ID;
rt_attr.value.oid = group_oid;
sai_route_api->create_route_entry(&route_entry, 1, &rt_attr);
```

The route entry creation above is identical for every group type — it simply points a prefix at the group OID — so subsequent sections omit it.

> **Optional group and member attributes**: Both dynamic group types support optional group-level attributes for advanced scenarios: `ARS_OBJECT_ID` (Adaptive Routing and Switching), `HASH_ALGORITHM` (per-group hash override), and `HIERARCHICAL_NEXTHOP` (whether the group mixes tunnel and IP next hops; default true). Every member type supports an optional `COUNTER_ID` for per-member hit tracking.


## Dynamic Ordered ECMP

Dynamic Ordered ECMP extends the unordered model by sorting members according to a priority value. Each member carries a `SEQUENCE_ID` attribute, and the ASIC evaluates members in sequence-ID order rather than treating them as an unordered set. This is useful when the forwarding policy requires deterministic member selection priority — for example, preferring a local next hop over a remote tunnel endpoint. `vnetorch` uses this type for VxLAN overlay groups.

Ordered ECMP requires two conditions to both be true:

1. **Configuration** — the `ordered_ecmp` field in `SWITCH_TABLE:switch` (APPL_DB) must be `"true"`. The boot-time template `switch.json.j2` sets this to `"true"` only for `LeafRouter` devices; all other roles get `"false"`.

2. **ASIC capability** — not all ASICs support this type. When `switchorch` receives `ordered_ecmp: "true"`, it probes the ASIC to confirm support. Only if the ASIC confirms does `m_orderedEcmpEnable` become `true`.

If either condition is false, `routeorch` falls back to `DYNAMIC_UNORDERED_ECMP`.

The capability probe at startup:

```cpp
// switchorch.cpp — probing ASIC capabilities at startup
auto status = sai_query_attribute_enum_values_capability(
    gSwitchId, SAI_OBJECT_TYPE_NEXT_HOP_GROUP,
    SAI_NEXT_HOP_GROUP_ATTR_TYPE, &values);
if (status == SAI_STATUS_SUCCESS) {
    for (size_t i = 0; i < values.count; i++) {
        if (values.list[i] == SAI_NEXT_HOP_GROUP_TYPE_DYNAMIC_ORDERED_ECMP) {
            m_orderedEcmpEnable = true;
        }
    }
}
```

The result is published to STATE_DB as `SWITCH_CAPABILITY_TABLE|ordered_ecmp_capable`. When `routeorch` creates a group, it checks this flag to decide the type:

```cpp
// routeorch.cpp — selecting group type based on ASIC capability
nhg_attr.value.s32 = m_switchOrch->checkOrderedEcmpEnable()
    ? SAI_NEXT_HOP_GROUP_TYPE_DYNAMIC_ORDERED_ECMP
    : SAI_NEXT_HOP_GROUP_TYPE_ECMP;
    // SAI_NEXT_HOP_GROUP_TYPE_ECMP is an alias for DYNAMIC_UNORDERED_ECMP
```

### SAI Calls

```c
/* Group — same structure as unordered, only the type constant differs */
sai_attribute_t grp_attr;
grp_attr.id        = SAI_NEXT_HOP_GROUP_ATTR_TYPE;
grp_attr.value.s32 = SAI_NEXT_HOP_GROUP_TYPE_DYNAMIC_ORDERED_ECMP;
sai_next_hop_group_api->create_next_hop_group(&group_oid, switch_id, 1, &grp_attr);

/* Member — adds SEQUENCE_ID for priority ordering (lower value = higher priority) */
sai_attribute_t mbr_attrs[4];
mbr_attrs[0].id        = SAI_NEXT_HOP_GROUP_MEMBER_ATTR_NEXT_HOP_GROUP_ID;
mbr_attrs[0].value.oid = group_oid;
mbr_attrs[1].id        = SAI_NEXT_HOP_GROUP_MEMBER_ATTR_NEXT_HOP_ID;
mbr_attrs[1].value.oid = local_nh_oid;       /* resolved via neighOrch */
mbr_attrs[2].id        = SAI_NEXT_HOP_GROUP_MEMBER_ATTR_SEQUENCE_ID;
mbr_attrs[2].value.u32 = 1;                  /* ← preferred path (unique to ordered ECMP) */
mbr_attrs[3].id        = SAI_NEXT_HOP_GROUP_MEMBER_ATTR_WEIGHT;
mbr_attrs[3].value.u32 = 1;
sai_next_hop_group_api->create_next_hop_group_member(&member_oid, switch_id, 4, mbr_attrs);

/* Second member — lower priority (fallback) */
mbr_attrs[1].value.oid = tunnel_nh_oid;
mbr_attrs[2].value.u32 = 2;                  /* ← fallback path */
sai_next_hop_group_api->create_next_hop_group_member(&member_oid, switch_id, 4, mbr_attrs);
```


## Fine-Grain ECMP (FG-ECMP)

Fine-Grain ECMP gives software full control over a fixed-size bucket array with explicit per-bucket member assignment. It is implemented by `fgnhgorch` using `SAI_NEXT_HOP_GROUP_TYPE_FINE_GRAIN_ECMP`. When a route arriving through `ROUTE_TABLE` matches a prefix in `FG_NHG_PREFIX`, `routeorch` delegates it to `fgnhgorch` (step 3 in the [ASIC programming](24_load_balancing.md#asic-programming-routeorch) pipeline).

### Configuration

FG-ECMP is configured per destination prefix through three CONFIG_DB tables:

| Table           | Key         | Fields                      | Purpose |
|-----------------|-------------|-----------------------------|---------|
| `FG_NHG`        | Group name  | `bucket_size`, `match_mode` | Defines a named FG-ECMP group with its bucket count and matching strategy. |
| `FG_NHG_PREFIX` | IP prefix   | `FG_NHG` (group name)       | Binds a destination prefix to an FG-ECMP group. |
| `FG_NHG_MEMBER` | Next-hop IP | `FG_NHG`, `bank`            | Assigns a next hop to a group and a bank for scoped failover. |

Example:

```text
FG_NHG|group1
    bucket_size: 60

FG_NHG_PREFIX|10.0.0.0/24
    FG_NHG: group1

FG_NHG_MEMBER|10.1.1.1
    FG_NHG: group1
    bank: 0

FG_NHG_MEMBER|10.1.2.1
    FG_NHG: group1
    bank: 0

FG_NHG_MEMBER|10.1.3.1
    FG_NHG: group1
    bank: 1
```

### SAI Calls

```c
/* Group — adds CONFIGURED_SIZE for the fixed bucket array (unique to FG-ECMP) */
sai_attribute_t grp_attrs[2];
grp_attrs[0].id        = SAI_NEXT_HOP_GROUP_ATTR_TYPE;
grp_attrs[0].value.s32 = SAI_NEXT_HOP_GROUP_TYPE_FINE_GRAIN_ECMP;
grp_attrs[1].id        = SAI_NEXT_HOP_GROUP_ATTR_CONFIGURED_SIZE;
grp_attrs[1].value.u32 = 60;                 /* ← requested bucket count (unique to FG-ECMP) */
sai_next_hop_group_api->create_next_hop_group(&group_oid, switch_id, 2, grp_attrs);
/* After creation, REAL_SIZE (read-only) returns actual ASIC allocation, e.g. 64 */

/* Member — adds INDEX to pin each member to a specific bucket position */
sai_attribute_t mbr_attrs[3];
mbr_attrs[0].id        = SAI_NEXT_HOP_GROUP_MEMBER_ATTR_NEXT_HOP_GROUP_ID;
mbr_attrs[0].value.oid = group_oid;
mbr_attrs[1].id        = SAI_NEXT_HOP_GROUP_MEMBER_ATTR_NEXT_HOP_ID;
mbr_attrs[1].value.oid = nh_oid;             /* resolved via neighOrch */
mbr_attrs[2].id        = SAI_NEXT_HOP_GROUP_MEMBER_ATTR_INDEX;
mbr_attrs[2].value.u32 = 0;                  /* ← explicit bucket position (unique to FG-ECMP) */
sai_next_hop_group_api->create_next_hop_group_member(&member_oid, switch_id, 3, mbr_attrs);
```

When a member fails, `fgnhgorch` rewrites only the buckets belonging to that member and redistributes them to other members **within the same bank**. Members in other banks are untouched.


## Weighted ECMP (W-ECMP)

> **Note**: W-ECMP is not a separate SAI next-hop group type. The underlying group type is `DYNAMIC_UNORDERED_ECMP`, but each member's `WEIGHT` attribute is set to a value derived from the BGP link-bandwidth extended community, producing an unequal traffic distribution. This section is included here because the weight-handling pipeline is tightly coupled to how next-hop groups are programmed.

Standard ECMP splits traffic equally across all paths. Weighted ECMP (W-ECMP) allows an **unequal** split — for example, sending twice as much traffic down a path with twice the capacity. SONiC supports W-ECMP as a global toggle.

### Configuration

The feature is controlled by a single boolean in CONFIG_DB:

```text
BGP_DEVICE_GLOBAL|STATE
    wcmp_enabled = "true" | "false"   (default "false")
```

The YANG model (`sonic-bgp-device-global.yang`) defines this leaf:

```yang
leaf wcmp_enabled {
    description "Enables/Disables Weighted-Equal Cost-Multipath using BGP link bandwidth";
    type boolean;
    default "false";
}
```

CLI commands:

```text
config bgp device-global w-ecmp enabled      # enable W-ECMP
config bgp device-global w-ecmp disabled     # disable W-ECMP
show bgp device-global                        # display current state
```

`show bgp device-global` output when W-ECMP is enabled:

```text
TSA       W-ECMP
--------  --------
disabled  enabled
```

### Control-Plane Pipeline

When `wcmp_enabled` changes in CONFIG_DB, the `bgpcfgd` daemon (`DeviceGlobalCfgMgr` in `managers_device_global.py`) renders an FRR Jinja2 template and pushes it into the running BGP daemon. The template (`bgpd/wcmp/bgpd.wcmp.conf.j2`) toggles a single FRR directive on the outbound route-maps for both address families:

```text
route-map TO_BGP_PEER_V4 permit 100
  set extcommunity bandwidth num-multipaths     ← when wcmp_enabled == true
exit
route-map TO_BGP_PEER_V6 permit 100
  set extcommunity bandwidth num-multipaths     ← when wcmp_enabled == true
exit
```

`set extcommunity bandwidth num-multipaths` instructs FRR to attach the BGP link-bandwidth extended community (a BGP attribute that conveys available bandwidth for a prefix) to each outgoing route advertisement. The bandwidth value is set proportionally based on the number of equal-cost multipaths the advertising router has toward that prefix. A peer receiving the advertisement uses these bandwidth values to derive per-path weights, producing an unequal traffic split.

### Weight Propagation Through fpmsyncd

The route-ingestion pipeline described in [Route Ingestion](24_load_balancing.md#route-ingestion-fpmsyncd) carries equal-cost routes without weights. When W-ECMP is active, FRR includes per-next-hop weights in the route updates it sends to `fpmsyncd` over the FPM socket. `fpmsyncd` extracts these weights alongside the next hops.

> **Netlink weight offset**: The FPM socket carries route updates in netlink message format. In this format, next-hop weights are zero-based (a weight of 0 means "weight 1"). `fpmsyncd` adds 1 when parsing these messages so the value written to APPL_DB reflects the true weight.

This correction applies both to individual next-hop weights and to nexthop-group messages:

```cpp
// fpmsyncd/routesync.cpp — extracting per-next-hop weight (individual)
uint8_t weight = rtnl_route_nh_get_weight(nexthop);
if (weight == 0)
{
    weight = 1;
}

// fpmsyncd/routesync.cpp — extracting weights from nexthop group messages (NHA_GROUP)
weight_list += to_string(nha_grp[i].weight + 1);
```

`fpmsyncd` writes the route into APPL_DB's `ROUTE_TABLE` with a comma-separated `weight` field:

```text
ROUTE_TABLE:10.0.0.0/24
    nexthop:  10.1.1.1,10.1.2.1
    ifname:   Ethernet0,Ethernet4
    weight:   5,2
```

### ASIC Programming

`routeorch` parses the weight field and constructs a `NextHopGroupKey` that includes per-member weights:

```cpp
// orchagent/nexthopgroupkey.h — constructor that pairs next hops with weights
NextHopGroupKey(const std::string &nexthops, const std::string &weights)
{
    std::vector<std::string> nhv = tokenize(nexthops, NHG_DELIMITER);
    std::vector<std::string> wtv = tokenize(weights, NHG_DELIMITER);
    bool set_weight = wtv.size() == nhv.size();
    for (uint32_t i = 0; i < nhv.size(); i++)
    {
        NextHopKey nh(nhv[i]);
        nh.weight = set_weight ? (uint32_t)std::stoi(wtv[i]) : 0;
        m_nexthops.insert(nh);
    }
}
```

When creating a next-hop group member, `routeorch` sets `SAI_NEXT_HOP_GROUP_MEMBER_ATTR_WEIGHT` only when the weight is non-zero. When the weight is omitted (zero), SAI defaults to weight 1, making the behavior identical to standard equal-cost ECMP:

```cpp
// orchagent/routeorch.cpp — programming weight into SAI
if (weight)
{
    nhgm_attr.id = SAI_NEXT_HOP_GROUP_MEMBER_ATTR_WEIGHT;
    nhgm_attr.value.s32 = weight;
    nhgm_attrs.push_back(nhgm_attr);
}
```


## ECMP With Members (P4RT WCMP)

> **Naming clarification**: The P4Runtime path uses the term "WCMP" (Weighted-Cost Multi-Path) for its weighted ECMP groups. This is a different mechanism from the BGP-based [Weighted ECMP (W-ECMP)](#weighted-ecmp-w-ecmp) described above: P4RT WCMP uses a dedicated SAI group type (`ECMP_WITH_MEMBERS`) with bulk member creation, while W-ECMP applies weights to standard `DYNAMIC_UNORDERED_ECMP` groups through the BGP pipeline.

SONiC exposes weighted ECMP through the P4Runtime interface via the `WcmpManager` (in `orchagent/p4orch/`). Unlike the `routeorch` path, which creates a group and then adds individual member objects one at a time, this type accepts the full member list and weight list as **group-level attributes** in a single bulk SAI call:

```c
// Everything is specified at group creation — no separate member objects
group.TYPE                         = SAI_NEXT_HOP_GROUP_TYPE_ECMP_WITH_MEMBERS
group.NEXT_HOP_LIST                = [nh_oid_1, nh_oid_2, nh_oid_3]   // ordered next-hop OIDs
group.NEXT_HOP_MEMBER_WEIGHT_LIST  = [3, 2, 1]                        // per-member weights
group.NEXT_HOP_MEMBER_COUNTER_LIST = [ctr_1, ctr_2, ctr_3]            // per-member hit counters
create_next_hop_group(&group_oid, ...)
```

```cpp
// orchagent/p4orch/wcmp_manager.cpp — bulk weight programming
nhl.id   = SAI_NEXT_HOP_GROUP_ATTR_NEXT_HOP_LIST;
nhmwl.id = SAI_NEXT_HOP_GROUP_ATTR_NEXT_HOP_MEMBER_WEIGHT_LIST;
```

Each P4RT WCMP group member carries a `weight` (default 1) and an optional `watch_port`. When a `watch_port` goes operationally down, the member is **pruned** (temporarily removed from the group) and the remaining members absorb the traffic. When the port comes back up, the member is restored. This pruning is managed by `WcmpManager::updateWatchPort()`.


## Class-Based Forwarding (CBF)

Class-Based Forwarding steers traffic by **forwarding class** rather than hash. A forwarding class is a numeric label assigned to a packet (typically by an ingress ACL or QoS policy) that indicates the type of service or path the packet should take. CBF is implemented by `cbfnhgorch` using `SAI_NEXT_HOP_GROUP_TYPE_CLASS_BASED`.

### Configuration

CBF uses two APPL_DB tables:

| Table | Key | Fields | Purpose |
|---|---|---|---|
| `CLASS_BASED_NEXT_HOP_GROUP_TABLE` | Group name | `members`, `selection_map` | Defines a CBF group with its member NHGs and the map that selects among them. |
| `FC_TO_NHG_INDEX_MAP_TABLE` | Map name | `fc → index` pairs | Maps each forwarding-class value to a member index in the group. |

### SAI Calls

`cbfnhgorch` creates a SAI group with type `CLASS_BASED` and attaches a `NEXT_HOP_GROUP_MAP`:

```c
// Step 1 — create a forwarding-class → member-index map
map.TYPE              = SAI_NEXT_HOP_GROUP_MAP_TYPE_FORWARDING_CLASS_TO_INDEX
map.MAP_TO_VALUE_LIST = { fc=0 → idx=0, fc=1 → idx=0, fc=7 → idx=1 }
create_next_hop_group_map(&map_oid, ...)

// Step 2 — create the group with SELECTION_MAP pointing to that map
group.TYPE            = SAI_NEXT_HOP_GROUP_TYPE_CLASS_BASED
group.CONFIGURED_SIZE = 2                  // number of member slots
group.SELECTION_MAP   = map_oid            // forwarding-class → index lookup
create_next_hop_group(&group_oid, ...)

// Step 3 — members positioned by INDEX (can be individual NHs or nested ECMP groups)
member.NEXT_HOP_GROUP_ID = group_oid
member.NEXT_HOP_ID       = nhg_or_nh_oid
member.INDEX              = 0              // receives traffic for fc=0 and fc=1
create_next_hop_group_member(...)
```

```cpp
// cbf/cbfnhgorch.cpp — creating a class-based group
nhg_attr.value.u32 = SAI_NEXT_HOP_GROUP_TYPE_CLASS_BASED;
```

If a packet arrives with a forwarding class not present in the map, index 0 is selected by default. Members of a CBF group can be individual next hops or nested ECMP groups, enabling hierarchical forwarding policies.


## Protection Groups

Unlike the ECMP types above, which distribute traffic across multiple active paths, protection groups provide **primary/standby failover** — only one path carries traffic at a time, and a backup path takes over when the primary fails. SAI defines two variants: one with software-controlled switchover and one with hardware-controlled switchover. Neither is currently consumed by a dedicated SONiC orchagent module; they are available for vendor-specific or platform-specific implementations that program SAI directly.

### Software Protection

A group of type `SAI_NEXT_HOP_GROUP_TYPE_PROTECTION` contains exactly two members: one with `CONFIGURED_ROLE` set to `PRIMARY` and one set to `STANDBY`. Under normal operation, all traffic is forwarded through the primary member. The standby member is pre-programmed in the ASIC but receives no traffic.

```c
// Group creation
group.TYPE = SAI_NEXT_HOP_GROUP_TYPE_PROTECTION
create_next_hop_group(&group_oid, ...)

// Primary member
primary.NEXT_HOP_GROUP_ID = group_oid
primary.NEXT_HOP_ID       = primary_nh_oid
primary.CONFIGURED_ROLE    = PRIMARY
primary.MONITORED_OBJECT   = bfd_session_oid   // optional — drives failover decisions
create_next_hop_group_member(&primary_oid, ...)

// Standby member
standby.NEXT_HOP_GROUP_ID = group_oid
standby.NEXT_HOP_ID       = standby_nh_oid
standby.CONFIGURED_ROLE    = STANDBY
create_next_hop_group_member(&standby_oid, ...)

// Software-triggered failover
set_attribute(group_oid, SET_SWITCHOVER, true)

// Read-only observed state after switchover
primary.OBSERVED_ROLE → INACTIVE           // was active, now on standby
standby.OBSERVED_ROLE → ACTIVE             // now carrying traffic
```

When the control plane detects that the primary path has failed (for example, via a BFD — Bidirectional Forwarding Detection — session going down), it sets `SET_SWITCHOVER` to `true`, causing the ASIC to redirect all traffic to the standby member. Each member can optionally reference a `MONITORED_OBJECT` (such as a BFD session OID) whose state the control plane uses to drive the switchover decision.

### Hardware Protection

A group of type `SAI_NEXT_HOP_GROUP_TYPE_HW_PROTECTION` follows the same primary/standby model, but the ASIC manages failover autonomously — typically driven by hardware-level link-state detection or BFD offload — without requiring a software trigger.

The key difference from software protection is the admin-role override. Each member supports an `ADMIN_ROLE` attribute with three modes:

| Admin Role | Behavior |
|---|---|
| `AUTO` | Hardware decides which member is active based on monitored-object state (default). |
| `PRIMARY` | Force this member to the active role regardless of monitored state. |
| `STANDBY` | Force this member to standby regardless of monitored state. |

This allows operators to perform maintenance drains or manual traffic steering while retaining automatic failover as the default behavior.


## Bridge Port (L2 Next-Hop Groups)

All previous group types operate at Layer 3 (IP routing). For Layer 2 (bridging/switching) scenarios, `l2nhgorch` manages bridge-port next-hop groups using `SAI_NEXT_HOP_GROUP_TYPE_BRIDGE_PORT`:

```c
// Group creation
group.TYPE = SAI_NEXT_HOP_GROUP_TYPE_BRIDGE_PORT
create_next_hop_group(&group_oid, ...)

// Members reference bridge-port OIDs instead of IP next-hop OIDs
member.NEXT_HOP_GROUP_ID = group_oid
member.NEXT_HOP_ID       = bridge_port_oid
create_next_hop_group_member(...)
```

```cpp
// l2nhgorch.cpp — L2 bridge-port group
nhg_attr.value.s32 = SAI_NEXT_HOP_GROUP_TYPE_BRIDGE_PORT;
```

These groups provide Layer 2 ECMP — distributing traffic across multiple bridge-port paths within a VLAN or bridge domain — in contrast to the Layer 3 ECMP groups covered earlier, which select among routed IP next hops.

---

**Previous**: [← Load Balancing in SONiC](24_load_balancing.md) · **Next**: [The PMON Container →](26_pmon_container.md)
