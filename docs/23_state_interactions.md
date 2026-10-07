# State Interactions and Data Flows

> **Prerequisites**: This document ties together concepts from all prior documents. You should be familiar with the [Core Redis Databases](08_redis_databases.md), [IPC Mechanisms](10_ipc_mechanisms.md), [SWSS](11_swss_container.md), [Orchagent](12_orchagent.md), and [SAI/Syncd](13_sai_and_syncd.md).

This document traces end-to-end data flows through SONiC for common operations. Understanding these flows is essential for debugging and development.

## Flow 1: Route Programming (BGP Route Learned)

When a new route is learned from a BGP peer:

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 1: BGP UPDATE received                                                              │
│                                                                                          │
│ External BGP peer sends UPDATE for prefix 10.1.0.0/24 via next-hop 10.0.0.1              │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 2: bgpd processes the update                                                        │
│                                                                                          │
│ bgpd applies import policies, path selection, and notifies zebra of the new best path    │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 3: zebra installs the route                                                         │
│                                                                                          │
│ zebra verifies next-hop reachability, then:                                              │
│ a) Installs route in Linux kernel via netlink                                            │
│ b) Sends route to fpmsyncd via FPM TCP socket                                            │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 4: fpmsyncd writes to APPL_DB                                                       │
│                                                                                          │
│ ROUTE_TABLE:10.1.0.0/24 → { "nexthop": "10.0.0.1", "ifname": "Ethernet0" }               │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 5: orchagent processes the route                                                    │
│                                                                                          │
│ RouteOrch receives the event:                                                            │
│ → Looks up next-hop 10.0.0.1 (must already exist in NEIGH_TABLE)                         │
│ → Resolves to a SAI next-hop object                                                      │
│ → Calls sai_route_api->create_route_entry()                                              │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 6: sairedis serializes to ASIC_DB                                                   │
│                                                                                          │
│ ASIC_STATE:SAI_OBJECT_TYPE_ROUTE_ENTRY:{...}                                             │
│ → { "SAI_ROUTE_ENTRY_ATTR_NEXT_HOP_ID": "oid:0x..." }                                    │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 7: syncd programs the ASIC                                                          │
│                                                                                          │
│ syncd reads from ASIC_DB queue, translates VID→RID, calls vendor SAI implementation,     │
│ which programs the route into the ASIC's forwarding table                                │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 8: Traffic is now hardware-forwarded                                                │
│                                                                                          │
│ Packets destined to 10.1.0.0/24 are forwarded by the ASIC without CPU involvement        │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

## Flow 2: Port Link Down Event

When a physical link goes down (cable unplugged, remote end failure):

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 1: ASIC/PHY detects loss of signal                                                  │
│                                                                                          │
│ The physical layer detects the link is down (cable pulled, remote end failure)           │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 2: Vendor SDK fires a callback in syncd                                             │
│                                                                                          │
│ The ASIC's SDK invokes a registered callback to report the port state change             │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 3: syncd publishes a notification                                                   │
│                                                                                          │
│ syncd sends a port-state-change event to orchagent (via NotificationProducer → Redis)    │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 4: orchagent receives the event                                                     │
│                                                                                          │
│ orchagent's notification thread:                                                         │
│ a) Updates APPL_DB: PORT_TABLE:Ethernet0 → oper_status=down                              │
│ b) Calls SAI to update kernel host-interface state                                       │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 5: syncd updates the kernel interface                                               │
│                                                                                          │
│ syncd sets the kernel interface down: ip link set Ethernet0 down                         │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 6: Kernel broadcasts netlink IF_DOWN                                                │
│                                                                                          │
│ Multiple daemons react in parallel:                                                      │
│ → neighsyncd: flushes neighbors on this interface                                        │
│ → teamsyncd: updates LAG member state                                                    │
│ → zebra (FRR): withdraws routes via this interface, sends BGP WITHDRAW to peers          │
│ → lldpmgrd: disables LLDP on this port                                                   │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 7: Databases and user-facing tools update                                           │
│                                                                                          │
│ STATE_DB and APPL_DB reflect the new port state; CLI/SNMP/telemetry shows interface down │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

## Flow 3: Port Initialization at Boot

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 1: database container starts                                                        │
│                                                                                          │
│ Redis is available for all other services                                                │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 2: swss container starts                                                            │
│                                                                                          │
│ portsyncd and orchagent launch inside the container                                      │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 3: portsyncd reads port configuration                                               │
│                                                                                          │
│ → Reads PORT table from CONFIG_DB (port lanes, speeds, aliases)                          │
│ → Publishes port info to APPL_DB: PORT_TABLE:Ethernet0, Ethernet4, ...                   │
│ → Subscribes to netlink for interface events                                             │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 4: orchagent initializes ports in hardware                                          │
│                                                                                          │
│ → Receives APPL_DB events                                                                │
│ → Waits until portsyncd signals "all ports parsed"                                       │
│ → Calls sai_port_api->create_port() for each port                                        │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 5: syncd creates ports and host interfaces                                          │
│                                                                                          │
│ syncd creates ports in the ASIC and creates kernel host-interfaces for each port         │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 6: Kernel generates netlink events                                                  │
│                                                                                          │
│ New interfaces appear in the kernel; portsyncd receives netlink confirmations            │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 7: portsyncd marks initialization complete                                          │
│                                                                                          │
│ After all ports confirmed, writes PORT_TABLE|EthernetX → { "state": "ok" } to STATE_DB   │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 8: Applications start using ports                                                   │
│                                                                                          │
│ Services subscribed to STATE_DB begin their work:                                        │
│ → teamsyncd: can now form LAGs                                                           │
│ → vlanmgrd: can now assign ports to VLANs                                                │
│ → intfmgrd: can now configure IP addresses                                               │
│ → lldpmgrd: can now enable LLDP on ports                                                 │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

## Flow 4: VLAN Configuration

```bash
admin@sonic:~$ config vlan add 100
admin@sonic:~$ config vlan member add 100 Ethernet4 --untagged
```

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 1: CLI writes to CONFIG_DB                                                          │
│                                                                                          │
│ VLAN|Vlan100 → { "vlanid": "100" }                                                       │
│ VLAN_MEMBER|Vlan100|Ethernet4 → { "tagging_mode": "untagged" }                           │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 2: vlanmgrd receives CONFIG_DB events                                               │
│                                                                                          │
│ → Checks STATE_DB: is Ethernet4 initialized? (PORT_TABLE|Ethernet4 state=ok)             │
│ → Creates VLAN device in kernel (ip link add link ... name Vlan100 type vlan id 100)     │
│ → Adds Ethernet4 as member (bridge vlan add dev Ethernet4 vid 100)                       │
│ → Writes to APPL_DB: VLAN_TABLE:Vlan100, VLAN_MEMBER_TABLE:Vlan100:Ethernet4             │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 3: orchagent (VlanOrch) processes APPL_DB events                                    │
│                                                                                          │
│ → Creates SAI VLAN object                                                                │
│ → Creates SAI VLAN member (port + VLAN association)                                      │
│ → Writes to ASIC_DB                                                                      │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 4: syncd programs the ASIC                                                          │
│                                                                                          │
│ → Creates VLAN in hardware forwarding tables                                             │
│ → Associates port to VLAN                                                                │
│ → Traffic on Ethernet4 is now switched in VLAN 100                                       │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

## Flow 5: ARP/Neighbor Resolution

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 1: Kernel sends ARP request                                                         │
│                                                                                          │
│ Switch needs to reach 10.0.0.1 (next-hop for a route); kernel sends ARP on the interface │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 2: ARP reply received                                                               │
│                                                                                          │
│ ARP reply from 10.0.0.1 (MAC: aa:bb:cc:dd:ee:ff); kernel updates its neighbor table      │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 3: neighsyncd writes to APPL_DB                                                     │
│                                                                                          │
│ neighsyncd receives netlink neighbor event and writes:                                   │
│ NEIGH_TABLE:Ethernet0:10.0.0.1 → { "family": "IPv4", "neigh": "aa:bb:cc:dd:ee:ff" }      │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 4: orchagent (NeighOrch) processes the neighbor                                     │
│                                                                                          │
│ → Creates SAI neighbor entry                                                             │
│ → Creates SAI next-hop entry (for routing to use)                                        │
│ → Writes to ASIC_DB                                                                      │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 5: syncd programs the neighbor into the ASIC                                        │
│                                                                                          │
│ L2 rewrite entry is created; routes pointing to 10.0.0.1 can now be forwarded in HW      │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 6: Pending routes are unblocked                                                     │
│                                                                                          │
│ Any routes in orchagent's retry queue waiting for this next-hop are re-processed         │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

## Debugging with These Flows

Knowing these flows helps you pinpoint exactly where things break:

| Symptom                             | Where to Look                   |
|-------------------------------------|---------------------------------|
| Route not in hardware               | Check APPL_DB → ASIC_DB → syncd logs |
| Port not coming up                  | Check syncd notifications → portsyncd → STATE_DB |
| Config change not taking effect     | Check CONFIG_DB → appropriate *mgrd logs |
| Neighbor not resolving              | Check kernel ARP → neighsyncd → APPL_DB |
| Pending entries (`_TABLE` prefixes) | Orchagent stuck or overloaded |
| SAI errors in syslog                | Meta layer validation failure or SDK error |

### Quick Diagnostic Commands

```bash
# Check if entries are pending in APPL_DB (orchagent not processing)
redis-cli -n 0 keys '_*'

# Check ASIC_DB queue (syncd not processing)
redis-cli -n 1 keys '_*'

# Check port initialization state
redis-cli -n 6 hgetall "PORT_TABLE|Ethernet0"

# Check current route in APPL_DB
redis-cli -n 0 hgetall "ROUTE_TABLE:10.1.0.0/24"

# Check if route reached ASIC_DB
redis-cli -n 1 keys '*ROUTE*10.1.0.0*'
```

---

**Previous**: [← Warm Reboot Deep Dive](22_warm_reboot.md) · **Next**: [Logging →](24_logging.md)
