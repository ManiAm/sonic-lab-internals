# State Interactions and Data Flows

> **Prerequisites**: This document ties together concepts from all prior documents. You should be familiar with the [Core Redis Databases](08_redis_databases.md), [IPC Mechanisms](10_ipc_mechanisms.md), [SWSS](11_swss_container.md), [Orchagent](12_orchagent.md), and [SAI/Syncd](13_sai_and_syncd.md).

This document traces end-to-end data flows through SONiC for common operations. Understanding these flows is essential for debugging and development.

## Flow 1: Route Programming (BGP Route Learned)

When a new route is learned from a BGP peer:

```
┌────────────────────────────────────────────────────────────┐
│ Step 1: BGP UPDATE received                                 │
│                                                             │
│ External BGP peer sends a TCP packet containing a route     │
│ update for prefix 10.1.0.0/24 via next-hop 10.0.0.1       │
└─────────────────────────┬──────────────────────────────────┘
                          │
                          v
┌────────────────────────────────────────────────────────────┐
│ Step 2: bgpd processes the update                           │
│                                                             │
│ bgpd applies import policies, path selection, and notifies  │
│ zebra of the new best path                                  │
└─────────────────────────┬──────────────────────────────────┘
                          │
                          v
┌────────────────────────────────────────────────────────────┐
│ Step 3: zebra installs the route                            │
│                                                             │
│ zebra verifies next-hop reachability, then:                 │
│ a) Installs route in Linux kernel via netlink               │
│ b) Sends route to fpmsyncd via FPM TCP socket               │
└─────────────────────────┬──────────────────────────────────┘
                          │
                          v
┌────────────────────────────────────────────────────────────┐
│ Step 4: fpmsyncd writes to APPL_DB                          │
│                                                             │
│ ROUTE_TABLE:10.1.0.0/24 → { "nexthop": "10.0.0.1",       │
│                              "ifname": "Ethernet0" }        │
└─────────────────────────┬──────────────────────────────────┘
                          │
                          v
┌────────────────────────────────────────────────────────────┐
│ Step 5: orchagent processes the route                        │
│                                                             │
│ RouteOrch receives the event:                               │
│ - Looks up next-hop 10.0.0.1 (must already exist in        │
│   NEIGH_TABLE for the route to be programmable)             │
│ - Resolves to a SAI next-hop object                         │
│ - Calls sai_route_api->create_route_entry()                 │
└─────────────────────────┬──────────────────────────────────┘
                          │
                          v
┌────────────────────────────────────────────────────────────┐
│ Step 6: sairedis serializes to ASIC_DB                       │
│                                                             │
│ ASIC_STATE:SAI_OBJECT_TYPE_ROUTE_ENTRY:{...}                │
│   → { "SAI_ROUTE_ENTRY_ATTR_NEXT_HOP_ID": "oid:0x..." }   │
└─────────────────────────┬──────────────────────────────────┘
                          │
                          v
┌────────────────────────────────────────────────────────────┐
│ Step 7: syncd programs the ASIC                             │
│                                                             │
│ syncd reads from ASIC_DB queue, translates VID→RID,         │
│ calls vendor SAI implementation, which programs the route    │
│ into the ASIC's forwarding table                            │
└─────────────────────────┬──────────────────────────────────┘
                          │
                          v
┌────────────────────────────────────────────────────────────┐
│ Step 8: Traffic is now hardware-forwarded                    │
│                                                             │
│ Packets destined to 10.1.0.0/24 are forwarded by the ASIC  │
│ without CPU involvement                                     │
└────────────────────────────────────────────────────────────┘
```

## Flow 2: Port Link Down Event

When a physical link goes down (cable unplugged, remote end failure):

```
1. ASIC/PHY detects loss of signal
      │
      v
2. Vendor SDK fires a callback in syncd
      │
      v
3. syncd's notification handler:
   - Publishes port-state-change notification to orchagent
     (via NotificationProducer → Redis channel)
      │
      v
4. orchagent's notification thread receives the event:
   a) Updates APPL_DB: PORT_TABLE:Ethernet0 → oper_status=down
   b) Calls SAI to update kernel host-interface state
      │
      v
5. syncd updates kernel interface: ip link set Ethernet0 down
      │
      v
6. Kernel generates netlink broadcast (IF_DOWN)
      │
      ├──→ neighsyncd: flushes neighbors on this interface
      ├──→ teamsyncd: updates LAG member state
      ├──→ zebra (FRR): withdraws routes via this interface
      │         └──→ sends BGP WITHDRAW to peers
      └──→ lldpmgrd: disables LLDP on this port

7. STATE_DB and APPL_DB reflect the new port state

8. CLI/SNMP/telemetry shows interface as down
```

## Flow 3: Port Initialization at Boot

```
1. database container starts (Redis is available)
      │
      v
2. swss container starts
      │
      v
3. portsyncd starts:
   - Reads the PORT table from CONFIG_DB (port lanes, speeds, aliases)
   - Publishes port info to APPL_DB: PORT_TABLE:Ethernet0, Ethernet4, ...
   - Subscribes to netlink for interface events
      │
      v
4. orchagent receives APPL_DB events:
   - BUT waits until portsyncd signals "all ports parsed"
   - Then initializes ports in hardware via SAI
   - Calls sai_port_api->create_port() for each port
      │
      v
5. syncd creates ports in ASIC and creates kernel host-interfaces
      │
      v
6. Kernel generates netlink events for new interfaces
      │
      v
7. portsyncd receives netlink confirmations
   - After all ports confirmed: marks initialization complete
   - Writes PORT_TABLE|EthernetX → { "state": "ok" } to STATE_DB
      │
      v
8. Applications subscribed to STATE_DB start using ports:
   - teamsyncd: can now form LAGs
   - vlanmgrd: can now assign ports to VLANs
   - intfmgrd: can now configure IP addresses
   - lldpmgrd: can now enable LLDP on ports
```

## Flow 4: VLAN Configuration

```bash
admin@sonic:~$ config vlan add 100
admin@sonic:~$ config vlan member add 100 Ethernet4 --untagged
```

```
1. CLI writes to CONFIG_DB:
   VLAN|Vlan100 → { "vlanid": "100" }
   VLAN_MEMBER|Vlan100|Ethernet4 → { "tagging_mode": "untagged" }
      │
      v
2. vlanmgrd receives CONFIG_DB events:
   - Checks STATE_DB: is Ethernet4 initialized? (PORT_TABLE|Ethernet4 state=ok)
   - If yes: creates VLAN device in kernel (ip link add link ... name Vlan100 type vlan id 100)
   - Adds Ethernet4 as member (bridge vlan add dev Ethernet4 vid 100)
   - Writes to APPL_DB: VLAN_TABLE:Vlan100, VLAN_MEMBER_TABLE:Vlan100:Ethernet4
      │
      v
3. orchagent (VlanOrch) processes APPL_DB events:
   - Creates SAI VLAN object
   - Creates SAI VLAN member (port + VLAN association)
   - Writes to ASIC_DB
      │
      v
4. syncd programs the ASIC:
   - Creates VLAN in hardware forwarding tables
   - Associates port to VLAN
   - Traffic on Ethernet4 is now switched in VLAN 100
```

## Flow 5: ARP/Neighbor Resolution

```
1. Switch needs to reach 10.0.0.1 (next-hop for a route)
   Kernel sends ARP request on the appropriate interface
      │
      v
2. ARP reply received from 10.0.0.1 (MAC: aa:bb:cc:dd:ee:ff)
   Kernel updates its neighbor table
      │
      v
3. neighsyncd receives netlink neighbor event:
   - Writes to APPL_DB:
     NEIGH_TABLE:Ethernet0:10.0.0.1 → { "family": "IPv4",
                                          "neigh": "aa:bb:cc:dd:ee:ff" }
      │
      v
4. orchagent (NeighOrch) processes the neighbor:
   - Creates SAI neighbor entry
   - Creates SAI next-hop entry (for routing to use)
   - Writes to ASIC_DB
      │
      v
5. syncd programs the neighbor into ASIC:
   - L2 rewrite entry is created
   - Routes pointing to 10.0.0.1 can now be forwarded in hardware
      │
      v
6. Any routes in orchagent's retry queue that were waiting for this
   next-hop are now re-processed and programmed
```

## Debugging with These Flows

Knowing these flows helps you pinpoint exactly where things break:

| Symptom | Where to Look |
|---------|---------------|
| Route not in hardware | Check APPL_DB → ASIC_DB → syncd logs |
| Port not coming up | Check syncd notifications → portsyncd → STATE_DB |
| Config change not taking effect | Check CONFIG_DB → appropriate *mgrd logs |
| Neighbor not resolving | Check kernel ARP → neighsyncd → APPL_DB |
| Pending entries (`_TABLE` prefixes) | Orchagent stuck or overloaded |
| SAI errors in syslog | Meta layer validation failure or SDK error |

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

**Previous**: [← Warm Reboot Deep Dive](22_warm_reboot.md) · **Next**: [Troubleshooting →](24_troubleshooting.md)
