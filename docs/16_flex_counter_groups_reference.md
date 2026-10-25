# Flex Counter Groups — SAI Stat Reference

> This is a companion reference to [Flex Counters](15_flex_counters.md). It lists every SAI stat ID that SONiC polls for each counter group.


## PORT_STAT

Per-port traffic, error, and protocol counters. Polled by `PortsOrch` from the `port_stat_ids` array.

Default interval: **1 s**.

| SAI stat ID | Description | Type |
|---|---|---|
| `SAI_PORT_STAT_IF_IN_OCTETS` | Total bytes received | Cumulative |
| `SAI_PORT_STAT_IF_IN_UCAST_PKTS` | Unicast packets received | Cumulative |
| `SAI_PORT_STAT_IF_IN_NON_UCAST_PKTS` | Non-unicast (multicast + broadcast) packets received | Cumulative |
| `SAI_PORT_STAT_IF_IN_DISCARDS` | Ingress packets dropped | Cumulative |
| `SAI_PORT_STAT_IF_IN_ERRORS` | Receive errors | Cumulative |
| `SAI_PORT_STAT_IF_IN_UNKNOWN_PROTOS` | Packets with unknown protocol received | Cumulative |
| `SAI_PORT_STAT_IF_OUT_OCTETS` | Total bytes transmitted | Cumulative |
| `SAI_PORT_STAT_IF_OUT_UCAST_PKTS` | Unicast packets transmitted | Cumulative |
| `SAI_PORT_STAT_IF_OUT_NON_UCAST_PKTS` | Non-unicast packets transmitted | Cumulative |
| `SAI_PORT_STAT_IF_OUT_DISCARDS` | Egress packets dropped | Cumulative |
| `SAI_PORT_STAT_IF_OUT_ERRORS` | Transmit errors | Cumulative |
| `SAI_PORT_STAT_IF_OUT_QLEN` | Current output queue length | Current |
| `SAI_PORT_STAT_IF_IN_MULTICAST_PKTS` | Multicast packets received | Cumulative |
| `SAI_PORT_STAT_IF_IN_BROADCAST_PKTS` | Broadcast packets received | Cumulative |
| `SAI_PORT_STAT_IF_OUT_MULTICAST_PKTS` | Multicast packets transmitted | Cumulative |
| `SAI_PORT_STAT_IF_OUT_BROADCAST_PKTS` | Broadcast packets transmitted | Cumulative |
| `SAI_PORT_STAT_ETHER_RX_OVERSIZE_PKTS` | Oversized packets received | Cumulative |
| `SAI_PORT_STAT_ETHER_TX_OVERSIZE_PKTS` | Oversized packets transmitted | Cumulative |
| `SAI_PORT_STAT_ETHER_IN_PKTS_64_OCTETS` | Rx packets of exactly 64 bytes | Cumulative |
| `SAI_PORT_STAT_ETHER_IN_PKTS_65_TO_127_OCTETS` | Rx packets 65–127 bytes | Cumulative |
| `SAI_PORT_STAT_ETHER_IN_PKTS_128_TO_255_OCTETS` | Rx packets 128–255 bytes | Cumulative |
| `SAI_PORT_STAT_ETHER_IN_PKTS_256_TO_511_OCTETS` | Rx packets 256–511 bytes | Cumulative |
| `SAI_PORT_STAT_ETHER_IN_PKTS_512_TO_1023_OCTETS` | Rx packets 512–1023 bytes | Cumulative |
| `SAI_PORT_STAT_ETHER_IN_PKTS_1024_TO_1518_OCTETS` | Rx packets 1024–1518 bytes | Cumulative |
| `SAI_PORT_STAT_ETHER_IN_PKTS_1519_TO_2047_OCTETS` | Rx packets 1519–2047 bytes | Cumulative |
| `SAI_PORT_STAT_ETHER_IN_PKTS_2048_TO_4095_OCTETS` | Rx packets 2048–4095 bytes | Cumulative |
| `SAI_PORT_STAT_ETHER_IN_PKTS_4096_TO_9216_OCTETS` | Rx packets 4096–9216 bytes | Cumulative |
| `SAI_PORT_STAT_ETHER_IN_PKTS_9217_TO_16383_OCTETS` | Rx packets 9217–16383 bytes | Cumulative |
| `SAI_PORT_STAT_ETHER_OUT_PKTS_64_OCTETS` | Tx packets of exactly 64 bytes | Cumulative |
| `SAI_PORT_STAT_ETHER_OUT_PKTS_65_TO_127_OCTETS` | Tx packets 65–127 bytes | Cumulative |
| `SAI_PORT_STAT_ETHER_OUT_PKTS_128_TO_255_OCTETS` | Tx packets 128–255 bytes | Cumulative |
| `SAI_PORT_STAT_ETHER_OUT_PKTS_256_TO_511_OCTETS` | Tx packets 256–511 bytes | Cumulative |
| `SAI_PORT_STAT_ETHER_OUT_PKTS_512_TO_1023_OCTETS` | Tx packets 512–1023 bytes | Cumulative |
| `SAI_PORT_STAT_ETHER_OUT_PKTS_1024_TO_1518_OCTETS` | Tx packets 1024–1518 bytes | Cumulative |
| `SAI_PORT_STAT_ETHER_OUT_PKTS_1519_TO_2047_OCTETS` | Tx packets 1519–2047 bytes | Cumulative |
| `SAI_PORT_STAT_ETHER_OUT_PKTS_2048_TO_4095_OCTETS` | Tx packets 2048–4095 bytes | Cumulative |
| `SAI_PORT_STAT_ETHER_OUT_PKTS_4096_TO_9216_OCTETS` | Tx packets 4096–9216 bytes | Cumulative |
| `SAI_PORT_STAT_ETHER_OUT_PKTS_9217_TO_16383_OCTETS` | Tx packets 9217–16383 bytes | Cumulative |
| `SAI_PORT_STAT_PFC_0_TX_PKTS` – `SAI_PORT_STAT_PFC_7_TX_PKTS` | PFC pause frames transmitted per priority (0–7) | Cumulative |
| `SAI_PORT_STAT_PFC_0_RX_PKTS` – `SAI_PORT_STAT_PFC_7_RX_PKTS` | PFC pause frames received per priority (0–7) | Cumulative |
| `SAI_PORT_STAT_PAUSE_RX_PKTS` | Global (802.3x) pause frames received | Cumulative |
| `SAI_PORT_STAT_PAUSE_TX_PKTS` | Global (802.3x) pause frames transmitted | Cumulative |
| `SAI_PORT_STAT_ETHER_STATS_TX_NO_ERRORS` | Packets transmitted without errors | Cumulative |
| `SAI_PORT_STAT_IP_IN_UCAST_PKTS` | IP unicast packets received | Cumulative |
| `SAI_PORT_STAT_ETHER_STATS_JABBERS` | Jabber frames (oversized + FCS errors) | Cumulative |
| `SAI_PORT_STAT_ETHER_STATS_FRAGMENTS` | Fragment frames (undersized + FCS errors) | Cumulative |
| `SAI_PORT_STAT_ETHER_STATS_UNDERSIZE_PKTS` | Undersized packets (< 64 bytes) | Cumulative |
| `SAI_PORT_STAT_IP_IN_RECEIVES` | Total IP packets received | Cumulative |
| `SAI_PORT_STAT_IF_IN_FEC_CORRECTABLE_FRAMES` | FEC correctable frame errors | Cumulative |
| `SAI_PORT_STAT_IF_IN_FEC_NOT_CORRECTABLE_FRAMES` | FEC uncorrectable frame errors | Cumulative |
| `SAI_PORT_STAT_IF_IN_FEC_SYMBOL_ERRORS` | FEC symbol errors | Cumulative |
| `SAI_PORT_STAT_IF_IN_FEC_CODEWORD_ERRORS_S0` – `SAI_PORT_STAT_IF_IN_FEC_CODEWORD_ERRORS_S15` | FEC codeword errors per symbol slot (S0–S15) | Cumulative |
| `SAI_PORT_STAT_IF_IN_FEC_CORRECTED_BITS` | Total FEC corrected bits | Cumulative |
| `SAI_PORT_STAT_TRIM_PACKETS` | Packets trimmed due to failed admission | Cumulative |
| `SAI_PORT_STAT_DROPPED_TRIM_PACKETS` | Trimmed packets that failed retransmission | Cumulative |
| `SAI_PORT_STAT_TX_TRIM_PACKETS` | Trimmed packets successfully retransmitted | Cumulative |
| `SAI_PORT_STAT_DOT3_STATS_ALIGNMENT_ERRORS` | Alignment errors | Cumulative |
| `SAI_PORT_STAT_DOT3_STATS_FCS_ERRORS` | Frame Check Sequence errors | Cumulative |
| `SAI_PORT_STAT_DOT3_STATS_SINGLE_COLLISION_FRAMES` | Single-collision frames | Cumulative |
| `SAI_PORT_STAT_DOT3_STATS_MULTIPLE_COLLISION_FRAMES` | Multiple-collision frames | Cumulative |
| `SAI_PORT_STAT_DOT3_STATS_SQE_TEST_ERRORS` | SQE test errors | Cumulative |
| `SAI_PORT_STAT_DOT3_STATS_DEFERRED_TRANSMISSIONS` | Deferred transmissions | Cumulative |
| `SAI_PORT_STAT_DOT3_STATS_LATE_COLLISIONS` | Late collisions | Cumulative |
| `SAI_PORT_STAT_DOT3_STATS_EXCESSIVE_COLLISIONS` | Excessive collisions | Cumulative |
| `SAI_PORT_STAT_DOT3_STATS_INTERNAL_MAC_TRANSMIT_ERRORS` | Internal MAC transmit errors | Cumulative |
| `SAI_PORT_STAT_DOT3_STATS_CARRIER_SENSE_ERRORS` | Carrier sense errors | Cumulative |
| `SAI_PORT_STAT_DOT3_STATS_FRAME_TOO_LONGS` | Frames exceeding maximum size | Cumulative |
| `SAI_PORT_STAT_DOT3_STATS_INTERNAL_MAC_RECEIVE_ERRORS` | Internal MAC receive errors | Cumulative |
| `SAI_PORT_STAT_DOT3_STATS_SYMBOL_ERRORS` | Symbol errors | Cumulative |

> **Source**: `port_stat_ids` in [`portsorch.cpp`](https://github.com/sonic-net/sonic-swss/blob/master/orchagent/portsorch.cpp)


## PORT_BUFFER_DROP

Per-port ingress and egress buffer drop counters. Polled by `PortsOrch` from the `port_buffer_drop_stat_ids` array.

Default interval: **60 s**.

| SAI stat ID | Description | Type |
|---|---|---|
| `SAI_PORT_STAT_IN_DROPPED_PKTS` | Packets dropped at ingress due to buffer limits | Cumulative |
| `SAI_PORT_STAT_OUT_DROPPED_PKTS` | Packets dropped at egress due to buffer limits | Cumulative |

> **Source**: `port_buffer_drop_stat_ids` in [`portsorch.cpp`](https://github.com/sonic-net/sonic-swss/blob/master/orchagent/portsorch.cpp)


## QUEUE_STAT

Per-queue traffic counters on egress queues. Polled by `PortsOrch` from the `queue_stat_ids` array.

Default interval: **10 s**.

| SAI stat ID | Description | Type |
|---|---|---|
| `SAI_QUEUE_STAT_PACKETS` | Packets transmitted from this queue | Cumulative |
| `SAI_QUEUE_STAT_BYTES` | Bytes transmitted from this queue | Cumulative |
| `SAI_QUEUE_STAT_DROPPED_PACKETS` | Packets dropped from this queue | Cumulative |
| `SAI_QUEUE_STAT_DROPPED_BYTES` | Bytes dropped from this queue | Cumulative |
| `SAI_QUEUE_STAT_TRIM_PACKETS` | Packets trimmed on this queue | Cumulative |
| `SAI_QUEUE_STAT_DROPPED_TRIM_PACKETS` | Trimmed packets that failed retransmission | Cumulative |
| `SAI_QUEUE_STAT_TX_TRIM_PACKETS` | Trimmed packets successfully retransmitted | Cumulative |

> **Source**: `queue_stat_ids` in [`portsorch.cpp`](https://github.com/sonic-net/sonic-swss/blob/master/orchagent/portsorch.cpp)


## QUEUE_WATERMARK_STAT

Peak shared buffer usage per egress queue since the last clear. Polled by `PortsOrch` from the `queueWatermarkStatIds` array.

Default interval: **60 s**.

| SAI stat ID | Description | Type |
|---|---|---|
| `SAI_QUEUE_STAT_SHARED_WATERMARK_BYTES` | Peak shared buffer occupancy in bytes | Watermark |

> **Source**: `queueWatermarkStatIds` in [`portsorch.cpp`](https://github.com/sonic-net/sonic-swss/blob/master/orchagent/portsorch.cpp)


## PG_WATERMARK_STAT

Peak ingress priority group buffer usage since the last clear. Polled by `PortsOrch` from the `ingressPriorityGroupWatermarkStatIds` array.

Default interval: **60 s**.

| SAI stat ID | Description | Type |
|---|---|---|
| `SAI_INGRESS_PRIORITY_GROUP_STAT_XOFF_ROOM_WATERMARK_BYTES` | Peak XOFF headroom occupancy in bytes | Watermark |
| `SAI_INGRESS_PRIORITY_GROUP_STAT_SHARED_WATERMARK_BYTES` | Peak shared buffer occupancy in bytes | Watermark |

> **Source**: `ingressPriorityGroupWatermarkStatIds` in [`portsorch.cpp`](https://github.com/sonic-net/sonic-swss/blob/master/orchagent/portsorch.cpp)


## PG_DROP_STAT

Per-priority-group ingress drop counters. Polled by `PortsOrch` from the `ingressPriorityGroupDropStatIds` array.

Default interval: **10 s**.

| SAI stat ID | Description | Type |
|---|---|---|
| `SAI_INGRESS_PRIORITY_GROUP_STAT_DROPPED_PACKETS` | Packets dropped at this priority group | Cumulative |

> **Source**: `ingressPriorityGroupDropStatIds` in [`portsorch.cpp`](https://github.com/sonic-net/sonic-swss/blob/master/orchagent/portsorch.cpp)


## BUFFER_POOL_WATERMARK_STAT

Peak buffer pool occupancy since the last clear. Polled by `BufferOrch` from the `bufferPoolWatermarkStatIds` array.

Default interval: **60 s**.

| SAI stat ID | Description | Type |
|---|---|---|
| `SAI_BUFFER_POOL_STAT_WATERMARK_BYTES` | Peak pool occupancy in bytes | Watermark |
| `SAI_BUFFER_POOL_STAT_XOFF_ROOM_WATERMARK_BYTES` | Peak XOFF headroom occupancy in bytes | Watermark |

> **Source**: `bufferPoolWatermarkStatIds` in [`bufferorch.cpp`](https://github.com/sonic-net/sonic-swss/blob/master/orchagent/bufferorch.cpp)


## RIF_STAT

Per-router-interface L3 traffic and error counters. Polled by `IntfsOrch` from the `rifStatIds` array.

Default interval: **1 s**.

| SAI stat ID | Description | Type |
|---|---|---|
| `SAI_ROUTER_INTERFACE_STAT_IN_PACKETS` | L3 packets received | Cumulative |
| `SAI_ROUTER_INTERFACE_STAT_IN_OCTETS` | L3 bytes received | Cumulative |
| `SAI_ROUTER_INTERFACE_STAT_IN_ERROR_PACKETS` | L3 receive error packets | Cumulative |
| `SAI_ROUTER_INTERFACE_STAT_IN_ERROR_OCTETS` | L3 receive error bytes | Cumulative |
| `SAI_ROUTER_INTERFACE_STAT_OUT_PACKETS` | L3 packets transmitted | Cumulative |
| `SAI_ROUTER_INTERFACE_STAT_OUT_OCTETS` | L3 bytes transmitted | Cumulative |
| `SAI_ROUTER_INTERFACE_STAT_OUT_ERROR_PACKETS` | L3 transmit error packets | Cumulative |
| `SAI_ROUTER_INTERFACE_STAT_OUT_ERROR_OCTETS` | L3 transmit error bytes | Cumulative |

> **Source**: `rifStatIds` in [`intfsorch.cpp`](https://github.com/sonic-net/sonic-swss/blob/master/orchagent/intfsorch.cpp)


## ACL

Per-ACL-rule packet and byte counters. Polled by `AclOrch` using SAI ACL counter attributes.

Default interval: **10 s**.

| SAI attribute | Description | Type |
|---|---|---|
| `SAI_ACL_COUNTER_ATTR_PACKETS` | Packets matching this ACL rule | Cumulative |
| `SAI_ACL_COUNTER_ATTR_BYTES` | Bytes matching this ACL rule | Cumulative |

> **Note**: ACL counters use SAI attributes rather than stat IDs. Each ACL rule creates a counter object with `SAI_ACL_COUNTER_ATTR_ENABLE_PACKET_COUNT` and `SAI_ACL_COUNTER_ATTR_ENABLE_BYTE_COUNT`.
>
> **Source**: `aclCounterLookup` in [`aclorch.cpp`](https://github.com/sonic-net/sonic-swss/blob/master/orchagent/aclorch.cpp)


## TUNNEL_STAT

Per-tunnel encap/decap traffic counters (VxLAN tunnels). Polled by `VxlanOrch` from the `tunnel_stat_ids` array.

Default interval: **10 s**.

| SAI stat ID | Description | Type |
|---|---|---|
| `SAI_TUNNEL_STAT_IN_OCTETS` | Bytes received (decapsulated) | Cumulative |
| `SAI_TUNNEL_STAT_IN_PACKETS` | Packets received (decapsulated) | Cumulative |
| `SAI_TUNNEL_STAT_OUT_OCTETS` | Bytes transmitted (encapsulated) | Cumulative |
| `SAI_TUNNEL_STAT_OUT_PACKETS` | Packets transmitted (encapsulated) | Cumulative |

> **Source**: `tunnel_stat_ids` in [`vxlanorch.cpp`](https://github.com/sonic-net/sonic-swss/blob/master/orchagent/vxlanorch.cpp)


## FLOW_CNT_TRAP

Per-trap packet and byte counters for control-plane traffic (CoPP traps). Polled via `CoppOrch` using SAI generic counter stats.

Default interval: **10 s**.

| SAI stat ID | Description | Type |
|---|---|---|
| `SAI_COUNTER_STAT_PACKETS` | Packets hitting this trap | Cumulative |
| `SAI_COUNTER_STAT_BYTES` | Bytes hitting this trap | Cumulative |

> **Source**: `flow_counter_stat_ids` in [`flow_counter_handler.cpp`](https://github.com/sonic-net/sonic-swss/blob/master/orchagent/flex_counter/flow_counter_handler.cpp)


## MACSEC_SA

Per-MACsec Security Association encryption/decryption counters. Polled by `MACsecOrch`.

Default interval: **10 s**.

### Ingress SA stats

| SAI stat ID | Description | Type |
|---|---|---|
| `SAI_MACSEC_SA_STAT_OCTETS_ENCRYPTED` | Encrypted bytes (ingress view) | Cumulative |
| `SAI_MACSEC_SA_STAT_OCTETS_PROTECTED` | Integrity-protected bytes | Cumulative |
| `SAI_MACSEC_SA_STAT_IN_PKTS_UNCHECKED` | Packets not checked | Cumulative |
| `SAI_MACSEC_SA_STAT_IN_PKTS_DELAYED` | Packets delayed (replay protection) | Cumulative |
| `SAI_MACSEC_SA_STAT_IN_PKTS_LATE` | Packets late (replay window exceeded) | Cumulative |
| `SAI_MACSEC_SA_STAT_IN_PKTS_INVALID` | Packets with invalid ICV | Cumulative |
| `SAI_MACSEC_SA_STAT_IN_PKTS_NOT_VALID` | Packets that failed validation | Cumulative |
| `SAI_MACSEC_SA_STAT_IN_PKTS_NOT_USING_SA` | Packets not using this SA | Cumulative |
| `SAI_MACSEC_SA_STAT_IN_PKTS_UNUSED_SA` | Packets with unused SA | Cumulative |
| `SAI_MACSEC_SA_STAT_IN_PKTS_OK` | Successfully decrypted packets | Cumulative |

### Egress SA stats

| SAI stat ID | Description | Type |
|---|---|---|
| `SAI_MACSEC_SA_STAT_OCTETS_ENCRYPTED` | Encrypted bytes | Cumulative |
| `SAI_MACSEC_SA_STAT_OCTETS_PROTECTED` | Integrity-protected bytes | Cumulative |
| `SAI_MACSEC_SA_STAT_OUT_PKTS_ENCRYPTED` | Packets encrypted | Cumulative |
| `SAI_MACSEC_SA_STAT_OUT_PKTS_PROTECTED` | Packets integrity-protected | Cumulative |

> **Source**: `macsec_sa_ingress_stats`, `macsec_sa_egress_stats` in [`macsecorch.cpp`](https://github.com/sonic-net/sonic-swss/blob/master/orchagent/macsecorch.cpp)


## MACSEC_FLOW

Per-MACsec flow (SecY-level) traffic counters. Polled by `MACsecOrch`.

Default interval: **10 s**.

### Ingress flow stats

| SAI stat ID | Description | Type |
|---|---|---|
| `SAI_MACSEC_FLOW_STAT_OTHER_ERR` | Other errors | Cumulative |
| `SAI_MACSEC_FLOW_STAT_OCTETS_UNCONTROLLED` | Uncontrolled port bytes | Cumulative |
| `SAI_MACSEC_FLOW_STAT_OCTETS_CONTROLLED` | Controlled port bytes | Cumulative |
| `SAI_MACSEC_FLOW_STAT_UCAST_PKTS_UNCONTROLLED` | Uncontrolled unicast packets | Cumulative |
| `SAI_MACSEC_FLOW_STAT_UCAST_PKTS_CONTROLLED` | Controlled unicast packets | Cumulative |
| `SAI_MACSEC_FLOW_STAT_MULTICAST_PKTS_UNCONTROLLED` | Uncontrolled multicast packets | Cumulative |
| `SAI_MACSEC_FLOW_STAT_MULTICAST_PKTS_CONTROLLED` | Controlled multicast packets | Cumulative |
| `SAI_MACSEC_FLOW_STAT_BROADCAST_PKTS_UNCONTROLLED` | Uncontrolled broadcast packets | Cumulative |
| `SAI_MACSEC_FLOW_STAT_BROADCAST_PKTS_CONTROLLED` | Controlled broadcast packets | Cumulative |
| `SAI_MACSEC_FLOW_STAT_CONTROL_PKTS` | Control packets | Cumulative |
| `SAI_MACSEC_FLOW_STAT_PKTS_UNTAGGED` | Untagged packets | Cumulative |
| `SAI_MACSEC_FLOW_STAT_IN_TAGGED_CONTROL_PKTS` | Tagged control packets received | Cumulative |
| `SAI_MACSEC_FLOW_STAT_IN_PKTS_NO_TAG` | Packets without MACsec tag | Cumulative |
| `SAI_MACSEC_FLOW_STAT_IN_PKTS_BAD_TAG` | Packets with bad MACsec tag | Cumulative |
| `SAI_MACSEC_FLOW_STAT_IN_PKTS_NO_SCI` | Packets without SCI | Cumulative |
| `SAI_MACSEC_FLOW_STAT_IN_PKTS_UNKNOWN_SCI` | Packets with unknown SCI | Cumulative |
| `SAI_MACSEC_FLOW_STAT_IN_PKTS_OVERRUN` | Packets overrun | Cumulative |

### Egress flow stats

| SAI stat ID | Description | Type |
|---|---|---|
| `SAI_MACSEC_FLOW_STAT_OTHER_ERR` | Other errors | Cumulative |
| `SAI_MACSEC_FLOW_STAT_OCTETS_UNCONTROLLED` | Uncontrolled port bytes | Cumulative |
| `SAI_MACSEC_FLOW_STAT_OCTETS_CONTROLLED` | Controlled port bytes | Cumulative |
| `SAI_MACSEC_FLOW_STAT_OUT_OCTETS_COMMON` | Common output bytes | Cumulative |
| `SAI_MACSEC_FLOW_STAT_UCAST_PKTS_UNCONTROLLED` | Uncontrolled unicast packets | Cumulative |
| `SAI_MACSEC_FLOW_STAT_UCAST_PKTS_CONTROLLED` | Controlled unicast packets | Cumulative |
| `SAI_MACSEC_FLOW_STAT_MULTICAST_PKTS_UNCONTROLLED` | Uncontrolled multicast packets | Cumulative |
| `SAI_MACSEC_FLOW_STAT_MULTICAST_PKTS_CONTROLLED` | Controlled multicast packets | Cumulative |
| `SAI_MACSEC_FLOW_STAT_BROADCAST_PKTS_UNCONTROLLED` | Uncontrolled broadcast packets | Cumulative |
| `SAI_MACSEC_FLOW_STAT_BROADCAST_PKTS_CONTROLLED` | Controlled broadcast packets | Cumulative |
| `SAI_MACSEC_FLOW_STAT_CONTROL_PKTS` | Control packets | Cumulative |
| `SAI_MACSEC_FLOW_STAT_PKTS_UNTAGGED` | Untagged packets | Cumulative |
| `SAI_MACSEC_FLOW_STAT_OUT_PKTS_TOO_LONG` | Packets exceeding maximum SecY MTU | Cumulative |

> **Source**: `macsec_flow_ingress_stats`, `macsec_flow_egress_stats` in [`macsecorch.cpp`](https://github.com/sonic-net/sonic-swss/blob/master/orchagent/macsecorch.cpp)

---

**Previous**: [← Flex Counters](15_flex_counters.md) · **Next**: [The BGP Container and FRR →](17_bgp_container.md)
