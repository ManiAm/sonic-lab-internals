# Load Balancing in SONiC

> **Prerequisites**: [Orchagent Deep Dive](12_orchagent.md) — understand how Orchs consume APPL_DB and program SAI. [SAI and Syncd](13_sai_and_syncd.md) — understand how SAI objects map to ASIC hardware. [BGP Container](14_bgp_container.md) — understand the FRR integration and `bgpcfgd`.

For a comprehensive treatment of data center fabric load balancing — ECMP fundamentals, hash polarization, adaptive routing, and RDMA-specific constraints — see [DC-Load-Balancing](https://github.com/ManiAm/DC-Load-Balancing). This document focuses on how SONiC implements ECMP-based load balancing end-to-end: which SAI object types the ASIC exposes, which orchagent modules consume them, and how the control-plane pipeline (FRR → kernel → fpmsyncd → APPL_DB → orchagent → SAI) carries routes and weights into hardware.


## SAI Next-Hop Group Types

Every form of multi-path forwarding in SONiC ultimately programs a **SAI next-hop group** object. SAI defines several group types in `sainexthopgroup.h`, each representing a different forwarding variant. The table below lists every type defined in the SAI header, the SONiC orchagent module that uses it, and its purpose. Each type or family of related types is covered in a dedicated section later in this document.

| SAI Group Type | SONiC Orch | Purpose |
|---|---|---|
| **Dynamic Unordered ECMP** | `routeorch`, `nhgorch` | Standard ECMP. Members are unordered; the ASIC hashes and selects among them. This is the default type. |
| **Dynamic Ordered ECMP** | `routeorch`, `vnetorch` | Like standard ECMP, but members are **sorted by priority** (via `SAI_NEXT_HOP_GROUP_MEMBER_ATTR_SEQUENCE_ID`). Used when `ordered_ecmp` is enabled and the ASIC advertises support at init time. |
| **Fine-Grain ECMP** | `fgnhgorch` | Software-managed, fixed-size bucket array. Supports bank-scoped failover. |
| **Class-Based** | `cbfnhgorch` | Members are selected by **forwarding class** rather than (or in combination with) hash. Uses a `NEXT_HOP_GROUP_MAP` to map forwarding-class values to member indices. |
| **ECMP With Members** | `WcmpManager` (P4RT) | Group-level member list and weight list in a single bulk SAI call. Used by the P4Runtime path for weighted ECMP (WCMP). |
| **Protection** | — | Primary/standby failover group with **software-controlled** switchover. |
| **HW Protection** | — | Primary/standby failover group with **hardware-controlled** switchover. |
| **Bridge Port** | `l2nhgorch` | L2 next-hop group for bridge-port forwarding. |

The SAI enum values for each group type are defined in `sainexthopgroup.h`:

```c
typedef enum _sai_next_hop_group_type_t
{
    SAI_NEXT_HOP_GROUP_TYPE_DYNAMIC_UNORDERED_ECMP,
    SAI_NEXT_HOP_GROUP_TYPE_DYNAMIC_ORDERED_ECMP,
    SAI_NEXT_HOP_GROUP_TYPE_FINE_GRAIN_ECMP,
    SAI_NEXT_HOP_GROUP_TYPE_CLASS_BASED,
    SAI_NEXT_HOP_GROUP_TYPE_ECMP_WITH_MEMBERS,
    SAI_NEXT_HOP_GROUP_TYPE_PROTECTION,
    SAI_NEXT_HOP_GROUP_TYPE_HW_PROTECTION,
    SAI_NEXT_HOP_GROUP_TYPE_BRIDGE_PORT,

    SAI_NEXT_HOP_GROUP_TYPE_ECMP = SAI_NEXT_HOP_GROUP_TYPE_DYNAMIC_UNORDERED_ECMP,
} sai_next_hop_group_type_t;
```

## Hash Configuration

Before any ECMP group type can distribute traffic, the ASIC needs to know how to hash packets into buckets. SONiC exposes three knobs — seed, offset, and algorithm — as fields in `SWITCH_TABLE:switch` (APPL_DB). `switchorch` reads these fields and programs the corresponding SAI switch attributes.

| SWITCH_TABLE Field | SAI Attribute | Type | Default | Description |
|---|---|---|---|---|
| `ecmp_hash_seed` | `SAI_SWITCH_ATTR_ECMP_DEFAULT_HASH_SEED` | uint32 | 0 | Value mixed into the hash computation to decorrelate results across switches. |
| `ecmp_hash_offset` | `SAI_SWITCH_ATTR_ECMP_DEFAULT_HASH_OFFSET` | uint8 | 0 | Number of bits to rotate the hash output before bucket selection. |
| `ecmp_hash_algorithm` | `SAI_SWITCH_ATTR_ECMP_DEFAULT_HASH_ALGORITHM` | enum | CRC | Algorithm used to compute the hash (CRC, XOR, random, CRC_CCITT, etc.). |

Equivalent `lag_hash_seed` and `lag_hash_offset` fields exist for LAG hashing and follow the same pattern.

### Seed Assignment

The seed is not chosen randomly — it is a **deterministic value derived from the switch's role in the fabric**. At image build time, the Jinja2 template `switch.json.j2` (in `dockers/docker-orchagent/`) maps `DEVICE_METADATA.localhost.type` to a fixed seed:

```jinja2
{% if "ToRRouter" in DEVICE_METADATA.localhost.type %}
{% set hash_seed = 0 %}
{% elif "LeafRouter" in DEVICE_METADATA.localhost.type %}
{% set hash_seed = 10 %}
{% elif "SpineRouter" in DEVICE_METADATA.localhost.type %}
{% set hash_seed = 25 %}
{% elif "FabricSpineRouter" in DEVICE_METADATA.localhost.type %}
{% set hash_seed = 40 %}
{% elif "UpperSpineRouter" in DEVICE_METADATA.localhost.type %}
{% set hash_seed = 50 %}
...
```

The full mapping:

| Device Role | Base Seed |
|---|---|
| ToRRouter | 0 |
| LeafRouter | 10 |
| SpineRouter | 25 |
| FabricSpineRouter | 40 |
| UpperSpineRouter | 50 |
| LowerRegionalHub | 60 |
| FabricRegionalHub | 70 |
| UpperRegionalHub | 80 |

On multi-ASIC platforms, the `namespace_id` is added to the base seed so that each ASIC within the same chassis receives a unique value (`hash_seed_value = hash_seed + namespace_id`).

This role-based scheme guarantees that every tier in the fabric uses a different seed — a ToR, its leaf, and its spine will never produce the same hash for the same packet — without requiring the operator to configure anything manually.

### Offset Assignment

The hash offset is assigned by the same template. Only `LeafRouter` devices receive a non-zero offset (10 for both ECMP and LAG); all other roles default to 0.

### How switchorch Programs These Values

`switchorch` maintains a static map from `SWITCH_TABLE` field names to SAI attributes:

```cpp
// switchorch.cpp — attribute map (abridged)
const map<string, sai_switch_attr_t> switch_attribute_map = {
    {"ecmp_hash_seed",   SAI_SWITCH_ATTR_ECMP_DEFAULT_HASH_SEED},
    {"lag_hash_seed",    SAI_SWITCH_ATTR_LAG_DEFAULT_HASH_SEED},
    {"ecmp_hash_offset", SAI_SWITCH_ATTR_ECMP_DEFAULT_HASH_OFFSET},
    {"lag_hash_offset",  SAI_SWITCH_ATTR_LAG_DEFAULT_HASH_OFFSET},
};
```

When `switchorch` receives a `SWITCH_TABLE` update containing `ecmp_hash_seed`, it parses the value as a uint32 and calls `sai_switch_api->set_switch_attribute()` with `SAI_SWITCH_ATTR_ECMP_DEFAULT_HASH_SEED`. The same pattern applies to offset and algorithm.


## Dynamic Unordered ECMP

This is the default and most widely used group type. No special configuration is required — every multi-path route in SONiC programs a `DYNAMIC_UNORDERED_ECMP` group unless a more specific type is configured. Two SONiC modules create groups of this type: `routeorch` (implicitly, as part of route programming) and `nhgorch` (explicitly, for controller-managed groups).

### Route Ingestion (fpmsyncd)

FRR computes multi-path routes and pushes them to the Linux kernel via the Forwarding Plane Manager (FPM) protocol. `fpmsyncd` listens for these netlink route messages and translates them into APPL_DB entries:

```text
ROUTE_TABLE:10.0.0.0/24
    nexthop:  10.1.1.1,10.1.2.1,10.1.3.1
    ifname:   Ethernet0,Ethernet4,Ethernet8
```

### ASIC Programming (routeorch)

`routeorch` subscribes to `ROUTE_TABLE` in APPL_DB. When a multi-path route arrives, it:

1. Creates a `NextHopGroupKey` from the comma-separated next-hop and interface strings.
2. Resolves each next hop to a SAI next-hop OID via `neighOrch`.
3. Creates a SAI next-hop group of type `DYNAMIC_UNORDERED_ECMP` (or `DYNAMIC_ORDERED_ECMP` if the ASIC supports it — see the next section).
4. Creates a SAI next-hop group member for each path.
5. Points the route entry at the group OID.

```cpp
// routeorch.cpp — selecting group type based on ASIC capability
nhg_attr.value.s32 = m_switchOrch->checkOrderedEcmpEnable()
    ? SAI_NEXT_HOP_GROUP_TYPE_DYNAMIC_ORDERED_ECMP
    : SAI_NEXT_HOP_GROUP_TYPE_ECMP;
```

The resulting SAI objects for a three-path route:

```c
// Group — TYPE is the only mandatory create-time attribute
group.TYPE = SAI_NEXT_HOP_GROUP_TYPE_DYNAMIC_UNORDERED_ECMP
create_next_hop_group(&group_oid, ...)

// One member per path
member.NEXT_HOP_GROUP_ID = group_oid       // parent group (mandatory)
member.NEXT_HOP_ID       = nexthop_oid     // resolved via neighOrch (mandatory)
member.WEIGHT             = 1              // relative weight (default 1 → equal-cost)
create_next_hop_group_member(&member_oid, ...)

// Read-only attributes (queryable after creation)
group.NEXT_HOP_COUNT       → 3            // current member count
group.NEXT_HOP_MEMBER_LIST → [m1, m2, m3] // member OIDs
```

Dynamic group types also support optional attributes for advanced scenarios: `ARS_OBJECT_ID` (Adaptive Routing and Switching for flowlet-based rebalancing), `HASH_ALGORITHM` (per-group hash override), and `HIERARCHICAL_NEXTHOP` (whether the group mixes tunnel and IP next hops, default true). Every member type supports an optional `COUNTER_ID` for per-member hit tracking.

### NHG Orch (Explicit Groups)

While `routeorch` creates next-hop groups implicitly as part of route programming (driven by `ROUTE_TABLE`), `nhgorch` manages groups that are **explicitly defined** through `NEXTHOP_GROUP_TABLE` in APPL_DB. This separation allows external applications or controllers to create and manage next-hop groups independently of the routing stack.

`nhgorch` creates `DYNAMIC_UNORDERED_ECMP` groups and manages member creation, updates, and deletion through the SAI bulk API:

```cpp
// nhgorch.cpp — default NHG type
nhg_attr.value.s32 = SAI_NEXT_HOP_GROUP_TYPE_ECMP;
```

Unlike `routeorch`, which recreates a group when its membership changes, `nhgorch` supports `updateWeight()` on individual members, allowing runtime weight adjustments without tearing down and rebuilding the group.


## Dynamic Ordered ECMP

Dynamic Ordered ECMP extends the standard unordered model by sorting members according to a priority value. Each member carries a `SEQUENCE_ID` attribute, and the ASIC evaluates members in sequence-ID order rather than treating them as an unordered set. This is useful when the forwarding policy requires deterministic member selection priority — for example, preferring a local next hop over a remote tunnel endpoint.

### Capability Detection

Not all ASICs support this type. At startup, `switchorch` queries the ASIC's supported group types:

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

The result is published to STATE_DB as `SWITCH_CAPABILITY_TABLE|ordered_ecmp_capable`.

### Effect on the Pipeline

When ordered ECMP is supported, `routeorch` creates every multi-path group as `DYNAMIC_ORDERED_ECMP` instead of `DYNAMIC_UNORDERED_ECMP` (see the `checkOrderedEcmpEnable()` call in the [Dynamic Unordered ECMP](#dynamic-unordered-ecmp) section). Each group member then receives a `SEQUENCE_ID` that controls its priority. `vnetorch` also uses this type for VxLAN overlay ECMP groups.

The only structural difference from unordered ECMP is the `SEQUENCE_ID` on each member:

```c
group.TYPE = SAI_NEXT_HOP_GROUP_TYPE_DYNAMIC_ORDERED_ECMP
create_next_hop_group(&group_oid, ...)

// SEQUENCE_ID determines evaluation order (lower = higher priority)
member.NEXT_HOP_GROUP_ID = group_oid
member.NEXT_HOP_ID       = local_nh_oid
member.SEQUENCE_ID        = 1              // preferred path
member.WEIGHT             = 1
create_next_hop_group_member(...)

member.NEXT_HOP_GROUP_ID = group_oid
member.NEXT_HOP_ID       = tunnel_nh_oid
member.SEQUENCE_ID        = 2              // fallback path
member.WEIGHT             = 1
create_next_hop_group_member(...)
```


## Weighted ECMP (W-ECMP)

SONiC supports weighted ECMP end-to-end as a global toggle. The underlying SAI group type is still `DYNAMIC_UNORDERED_ECMP`, but each member's `WEIGHT` attribute is set to a value derived from the BGP link-bandwidth extended community, producing an unequal traffic split.

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

`set extcommunity bandwidth num-multipaths` instructs FRR to attach the BGP link-bandwidth extended community to each outgoing route advertisement. The bandwidth value is set proportionally based on the number of equal-cost multipaths the advertising router has toward that prefix. A peer receiving the advertisement uses these bandwidth values to derive per-path weights, producing an unequal traffic split.

### Weight Propagation Through fpmsyncd

The route ingestion pipeline described in [Dynamic Unordered ECMP](#dynamic-unordered-ecmp) carries equal-cost routes without weights. When W-ECMP is active, FRR additionally programs per-next-hop weights into the kernel. `fpmsyncd` extracts these weights alongside the next hops.

> **Kernel weight offset**: The Linux kernel stores next-hop weights as zero-based values (a weight of 0 means "weight 1"). `fpmsyncd` adds 1 when reading from the kernel so the value written to APPL_DB reflects the true weight.

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

### ASIC Programming (routeorch)

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


## Fine-Grain ECMP (FG-ECMP)

Fine-Grain ECMP is implemented by `fgnhgorch`. It uses `SAI_NEXT_HOP_GROUP_TYPE_FINE_GRAIN_ECMP`, which gives software full control over a fixed-size bucket array with explicit per-bucket member assignment.

### Configuration

FG-ECMP is configured per destination prefix through three CONFIG_DB tables:

| Table | Key | Fields | Purpose |
|---|---|---|---|
| `FG_NHG` | Group name | `bucket_size`, `match_mode` | Defines a named FG-ECMP group with its bucket count and matching strategy. |
| `FG_NHG_PREFIX` | IP prefix | `FG_NHG` (group name) | Binds a destination prefix to an FG-ECMP group. |
| `FG_NHG_MEMBER` | Next-hop IP | `FG_NHG`, `bank` | Assigns a next hop to a group and a bank for scoped failover. |

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

### ASIC Programming (fgnhgorch)

`fgnhgorch` creates a SAI group with type `FINE_GRAIN_ECMP` and a `CONFIGURED_SIZE` equal to `bucket_size`:

```c
// Group — CONFIGURED_SIZE sets the bucket array length
group.TYPE            = SAI_NEXT_HOP_GROUP_TYPE_FINE_GRAIN_ECMP
group.CONFIGURED_SIZE = 60                 // requested bucket count
create_next_hop_group(&group_oid, ...)
group.REAL_SIZE       → 64                 // actual ASIC allocation (read-only, may round up)

// Members — INDEX pins each member to a specific bucket position
member.NEXT_HOP_GROUP_ID = group_oid
member.NEXT_HOP_ID       = nexthop_oid
member.INDEX              = 0              // explicit position in the bucket array
create_next_hop_group_member(...)
```

```cpp
// fgnhgorch.cpp — creating a fine-grain ECMP group
nhg_attr.value.s32 = SAI_NEXT_HOP_GROUP_TYPE_FINE_GRAIN_ECMP;
```

When a member fails, `fgnhgorch` rewrites only the buckets belonging to that member and redistributes them to other members **within the same bank**. Members in other banks are untouched.


## Class-Based Forwarding (CBF)

Class-Based Forwarding steers traffic by **forwarding class** rather than hash. It is implemented by `cbfnhgorch` using `SAI_NEXT_HOP_GROUP_TYPE_CLASS_BASED`.

### Configuration

CBF uses two APPL_DB tables:

| Table | Key | Fields | Purpose |
|---|---|---|---|
| `CLASS_BASED_NEXT_HOP_GROUP_TABLE` | Group name | `members`, `selection_map` | Defines a CBF group with its member NHGs and the map that selects among them. |
| `FC_TO_NHG_INDEX_MAP_TABLE` | Map name | `fc → index` pairs | Maps each forwarding-class value to a member index in the group. |

### ASIC Programming (cbfnhgorch)

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

Protection groups provide **primary/standby failover** for next hops. SAI defines two variants — one with software-controlled switchover and one with hardware-controlled switchover. Neither is currently consumed by a dedicated SONiC orchagent module; they are available for vendor-specific or platform-specific implementations that program SAI directly.

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

When the control plane detects that the primary path has failed (for example, via a BFD session going down), it sets `SET_SWITCHOVER` to `true`, causing the ASIC to redirect all traffic to the standby member. Each member can optionally reference a `MONITORED_OBJECT` (such as a BFD session OID) whose state the control plane uses to drive the switchover decision.

### Hardware Protection

A group of type `SAI_NEXT_HOP_GROUP_TYPE_HW_PROTECTION` follows the same primary/standby model, but the ASIC manages failover autonomously — typically driven by hardware-level link-state or BFD offload, without requiring a software trigger.

The key difference from software protection is the admin-role override. Each member supports an `ADMIN_ROLE` attribute with three modes:

| Admin Role | Behavior |
|---|---|
| `AUTO` | Hardware decides which member is active based on monitored-object state (default). |
| `PRIMARY` | Force this member to the active role regardless of monitored state. |
| `STANDBY` | Force this member to standby regardless of monitored state. |

This allows operators to perform maintenance drains or manual traffic steering while retaining automatic failover as the default behavior.


## Bridge Port (L2 Next-Hop Groups)

`l2nhgorch` manages Layer 2 next-hop groups using `SAI_NEXT_HOP_GROUP_TYPE_BRIDGE_PORT`:

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

These groups provide L2 ECMP across bridge ports rather than IP next hops. Where an IP ECMP group selects among routed next-hop OIDs, a bridge-port group selects among bridge-port OIDs, distributing traffic across multiple L2 paths within a VLAN or bridge domain.


## Summary: SONiC ECMP Variant Coverage

| ECMP Variant | SONiC Module | SAI Group Type | CONFIG_DB / APPL_DB Tables | Key Capability |
|---|---|---|---|---|
| Standard ECMP | `routeorch` | `DYNAMIC_UNORDERED_ECMP` | `ROUTE_TABLE` (APPL_DB) | Default multi-path forwarding |
| Ordered ECMP | `routeorch`, `vnetorch` | `DYNAMIC_ORDERED_ECMP` | `ROUTE_TABLE` (APPL_DB) | Priority-based member ordering via `SEQUENCE_ID` |
| Weighted ECMP | `routeorch` | `DYNAMIC_UNORDERED_ECMP` + weight | `BGP_DEVICE_GLOBAL` (CONFIG_DB), `ROUTE_TABLE` (APPL_DB) | Per-member weight via BGP link-bandwidth |
| NHG (explicit groups) | `nhgorch` | `DYNAMIC_UNORDERED_ECMP` | `NEXTHOP_GROUP_TABLE` (APPL_DB) | Explicitly managed groups with runtime weight updates |
| WCMP (P4RT) | `WcmpManager` | `ECMP_WITH_MEMBERS` | `P4RT_TABLE` (APPL_DB) | Bulk member+weight programming, watch-port pruning |
| Fine-Grained ECMP | `fgnhgorch` | `FINE_GRAIN_ECMP` | `FG_NHG`, `FG_NHG_PREFIX`, `FG_NHG_MEMBER` (CONFIG_DB) | Bank-scoped failover, fixed bucket array |
| Class-Based Forwarding | `cbfnhgorch` | `CLASS_BASED` | `CLASS_BASED_NEXT_HOP_GROUP_TABLE`, `FC_TO_NHG_INDEX_MAP_TABLE` (APPL_DB) | Forwarding-class steering |
| Software Protection | — | `PROTECTION` | — | Primary/standby failover, software-triggered switchover |
| Hardware Protection | — | `HW_PROTECTION` | — | Primary/standby failover, hardware-autonomous switchover |
| L2 ECMP | `l2nhgorch` | `BRIDGE_PORT` | `L2_NEXTHOP_GROUP_TABLE` (APPL_DB) | L2 bridge-port load balancing |

---

**Previous**: [← The Route-Download Benchmark](15_benchmark.md) · **Next**: [The PMON Container →](17_pmon_container.md)
