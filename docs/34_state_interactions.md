# State Interactions and Data Flows

> **Prerequisites**: This document ties together concepts from all prior documents. You should be familiar with the [Core Redis Databases](08_redis_databases.md), [IPC Mechanisms](10_ipc_mechanisms.md), [SWSS](11_swss_container.md), [Orchagent](12_orchagent.md), and [SAI/Syncd](14_sai_and_syncd.md).

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
│ → Adds the route to EntityBulker, which programs routes in bulk SAI calls                │
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
│ PortsOrch handles the notification in orchagent's main select loop:                      │
│ a) Updates oper_status=down in APPL_DB (PORT_TABLE:Ethernet0) and STATE_DB               │
│ b) Sets the host interface oper status to down via SAI                                   │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 5: The kernel netdev goes oper-down                                                 │
│                                                                                          │
│ syncd applies the host-interface attribute through the vendor SAI, which drops carrier   │
│ on the Ethernet0 netdev. Its oper state goes down; its admin state is untouched.         │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 6: Kernel broadcasts a netlink link-down event                                      │
│                                                                                          │
│ Multiple daemons react in parallel:                                                      │
│ → neighsyncd: flushes neighbors on this interface                                        │
│ → teamsyncd: updates LAG member state                                                    │
│ → zebra (FRR): removes routes via this interface and notifies bgpd                       │
│ → bgpd (FRR): sends BGP WITHDRAW to peers for routes that are no longer reachable        │
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
│ → Sets PortConfigDone in APPL_DB once every port is published                            │
│ → Subscribes to netlink for interface events                                             │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 4: orchagent initializes ports in hardware                                          │
│                                                                                          │
│ → Fetches the ports SAI pre-created during create_switch (SAI_SWITCH_ATTR_PORT_LIST)     │
│ → Waits for portsyncd's PortConfigDone in APPL_DB                                        │
│ → Configures each port (speed, FEC, MTU, ...) with sai_port_api->set_port_attribute()    │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 5: PortsOrch creates host interfaces                                                │
│                                                                                          │
│ PortsOrch (in orchagent) calls sai_hostif_api->create_hostif() for each port; syncd      │
│ passes the call to the vendor SAI, which creates the kernel netdev (e.g., Ethernet0)     │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 6: Kernel generates netlink events                                                  │
│                                                                                          │
│ New interfaces appear in the kernel; portsyncd receives an RTM_NEWLINK for each one      │
│ and writes PORT_TABLE|EthernetX → { "state": "ok" } to STATE_DB as each netdev appears   │
└──────────────────────────────────────────────┬───────────────────────────────────────────┘
                                               │
                                               v
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│ Step 7: portsyncd signals PortInitDone                                                   │
│                                                                                          │
│ Once every port has a netdev, portsyncd writes PortInitDone to APPL_DB; PortsOrch then   │
│ marks all ports ready, unblocking the Orchs that depend on them                          │
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
│ Step 3: orchagent (PortsOrch) processes APPL_DB events                                   │
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
sonic-db-cli APPL_DB KEYS '_*'

# Check ASIC_DB queue length (syncd not processing)
sonic-db-cli ASIC_DB LLEN ASIC_STATE_KEY_VALUE_OP_QUEUE

# Check port initialization state
sonic-db-cli STATE_DB HGETALL "PORT_TABLE|Ethernet0"

# Check current route in APPL_DB
sonic-db-cli APPL_DB HGETALL "ROUTE_TABLE:10.1.0.0/24"

# Check if route reached ASIC_DB
sonic-db-cli ASIC_DB KEYS '*ROUTE*10.1.0.0*'
```

---

**Previous**: [← Warm Reboot Deep Dive](33_warm_reboot.md) · **Next**: [Logging →](35_logging.md)
