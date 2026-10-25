# Ports and Host Interfaces

> **Prerequisites**: [Orchagent Deep Dive](12_orchagent.md) — the select loop, `m_orchList` ordering, and `doTask()`. [The SAI Object Model](14_sai_object_model.md) — object IDs, entry keys, and the four operations.

Before the switch can route IP packets, it must first initialize its physical ports and create the Linux network devices that let the CPU communicate with the ASIC. This document covers `PortsOrch` — the orchagent module responsible for port configuration and host-interface creation.


## Port Objects in SAI

Unlike most SAI objects that orchagent creates on demand, port objects **already exist** when the switch initializes.

During `sai_switch_api->create_switch()`, the SAI implementation discovers the ASIC's physical ports and pre-creates a `SAI_OBJECT_TYPE_PORT` for each one. `PortsOrch` retrieves the full list via `SAI_SWITCH_ATTR_PORT_LIST`:

```c
sai_attribute_t attr;
attr.id = SAI_SWITCH_ATTR_PORT_LIST;
attr.value.objlist.count = port_count;
attr.value.objlist.list  = port_oid_array;
sai_switch_api->get_switch_attribute(switch_id, 1, &attr);
```

`PortsOrch` then configures each pre-existing port with the desired attributes:

| SAI Attribute | Purpose | Example |
|---|---|---|
| `SAI_PORT_ATTR_ADMIN_STATE` | Enable or disable the port | `true` |
| `SAI_PORT_ATTR_SPEED` | Link speed in Mbps | `100000` (100G) |
| `SAI_PORT_ATTR_MTU` | Maximum transmission unit | `9100` |
| `SAI_PORT_ATTR_FEC_MODE` | Forward error correction | `RS` |
| `SAI_PORT_ATTR_HW_LANE_LIST` | Physical SerDes (serializer/deserializer) lanes | `{0, 1, 2, 3}` |


## Port Initialization Pipeline

Port configuration flows through a multi-stage pipeline before reaching the ASIC:

```
CONFIG_DB                    APPL_DB                      ASIC
PORT|Ethernet8               PORT_TABLE:Ethernet8
  speed: 100000     ──►        speed: 100000      ──►    SAI port configured
  mtu: 9100        portmgrd    mtu: 9100          PortsOrch  (admin_state, speed,
  admin_status: up  portsyncd  admin_status: up              mtu, fec, lanes)
```

Two processes participate in this stage:

- **`portmgrd`** (manager daemon) — subscribes to CONFIG_DB's `PORT` table, applies admin state and MTU to the Linux kernel, and writes processed state to APPL_DB.
- **`portsyncd`** (sync daemon) — reads the `PORT` table from CONFIG_DB and publishes it to APPL_DB's `PORT_TABLE`. It also listens for kernel netlink events (notifications from the Linux kernel to user-space programs about network state changes) to track port link-up/down transitions.

`PortsOrch` consumes `PORT_TABLE` from APPL_DB and calls `sai_port_api->set_port_attribute()` to configure each port in the ASIC.


## The PortInitDone Signal

Orchagent cannot process routes, interfaces, or neighbors until all ports are ready. The initialization handshake works as follows:

1. `portsyncd` reads every entry from the CONFIG_DB `PORT` table and writes them to APPL_DB.
2. Once all ports have been written, `portsyncd` publishes a **`PortInitDone`** flag to APPL_DB.
3. Orchagent's main thread blocks until it sees `PortInitDone`, then begins processing all other APPL_DB tables.

This guarantees that port OIDs are available before any downstream Orch (IntfsOrch, NeighOrch, etc.) tries to reference them.


## Host Interfaces

For each physical port, `PortsOrch` creates a **host interface** (`SAI_OBJECT_TYPE_HOSTIF`). This SAI object creates a Linux network device (netdev) in the kernel and links it to the corresponding ASIC port:

```c
sai_attribute_t hostif_attrs[3];
hostif_attrs[0].id        = SAI_HOSTIF_ATTR_TYPE;
hostif_attrs[0].value.s32 = SAI_HOSTIF_TYPE_NETDEV;
hostif_attrs[1].id        = SAI_HOSTIF_ATTR_OBJ_ID;
hostif_attrs[1].value.oid = port_oid;             /* link to the SAI port */
hostif_attrs[2].id        = SAI_HOSTIF_ATTR_NAME;
strncpy(hostif_attrs[2].value.chardata, "Ethernet8", SAI_HOSTIF_NAME_SIZE);
sai_hostif_api->create_hostif(&hostif_oid, switch_id, 3, hostif_attrs);
```

After this call, a Linux netdev named `Ethernet8` appears in the kernel. It looks like a normal network interface — it has a MAC address, an MTU, you can assign IP addresses to it, and user-space processes can open sockets on it. But it is **not** a traditional NIC driver interface. It is a virtual netdev created by SAI to bridge between the ASIC and the CPU.

### What Flows Through a Host Interface

**Data-plane traffic never touches host interfaces.** When the ASIC forwards packets at line rate — millions of packets per second — it does so entirely in hardware. Packets are matched against route entries, rewritten, and sent out egress ports without ever reaching the CPU or the Linux kernel.

Only **control-plane traffic** — packets the ASIC deliberately redirects to the CPU — flows through host interfaces. How the ASIC decides which packets to redirect, and how SONiC rate-limits them to protect the CPU, is covered in the [Punting](19_punting.md) document.

### What This Means for tcpdump

Because only punted packets reach the kernel, running `tcpdump -i Ethernet8` captures **only control-plane traffic** — ARP, BGP, LLDP, ICMP, and similar. The data-plane packets being forwarded at line rate through the same physical port are invisible to `tcpdump` because they never leave the ASIC.

| Traffic type | Path | Visible to `tcpdump`? |
|---|---|---|
| Data plane (forwarded at line rate) | Ingress port → ASIC → egress port | No |
| Control plane (punted to CPU) | ASIC → host interface → kernel | Yes |
| CPU-originated (e.g., BGP update) | Kernel → host interface → ASIC → wire | Yes |


## Summary

| SAI Object | Created By | Triggered When | Key Attributes |
|---|---|---|---|
| Port | ASIC init + `PortsOrch` configures | Switch boot | Speed, MTU, admin state, lanes |
| Host Interface | `PortsOrch` | Switch boot | Type (netdev), port OID, name |

At this point, the switch's physical ports are initialized and the CPU can exchange control-plane traffic with the ASIC through host interfaces. But the ports are still Layer 2 (L2) objects — they can bridge traffic but cannot route IP packets. The next document, [The Forwarding Chain](18_forwarding_chain.md), covers how SONiC promotes ports to Layer 3 and programs the ASIC to route packets hop by hop.

---

**Previous**: [← Flex Counter Groups Reference](16_flex_counter_groups_reference.md) · **Next**: [The Forwarding Chain →](18_forwarding_chain.md)
