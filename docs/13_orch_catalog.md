# The Orch Catalog

> **Prerequisites**: [Orchagent Deep Dive](12_orchagent.md) — Orch architecture, the select loop, task queues, and SAI interaction.

The tables below list every Orch instantiated by `OrchDaemon::init()`, grouped by function.

## Core Data Plane

These Orchs handle the objects that every packet depends on — ports, L2/L3 forwarding entries, and next-hop resolution.

| Orch Class  | DB      | Tables | What It Handles |
|-------------|---------|---|---|
| `PortsOrch` | APPL_DB | PORT_TABLE, VLAN_TABLE, VLAN_MEMBER_TABLE, LAG_TABLE, LAG_MEMBER_TABLE, SEND_TO_INGRESS_PORT_TABLE | Physical ports, VLANs, LAGs, host interfaces |
| `IntfsOrch` | APPL_DB | INTF_TABLE, SAG_TABLE | Router interfaces (L3), Static Anycast Gateway |
| `NeighOrch` | APPL_DB | NEIGH_TABLE | ARP/NDP neighbors, adjacencies |
| `RouteOrch` | APPL_DB | ROUTE_TABLE, LABEL_ROUTE_TABLE | IPv4/IPv6 routes, MPLS label routes, ECMP |
| `FdbOrch`   | APPL_DB | FDB_TABLE, VXLAN_FDB_TABLE, MCLAG_FDB_TABLE | MAC forwarding database |
| `NhgOrch`   | APPL_DB | NEXTHOP_GROUP_TABLE | Next-hop groups (ECMP) |
| `VRFOrch`   | APPL_DB, STATE_DB | VRF_TABLE, VRF_OBJECT_TABLE | VRF lifecycle and object tracking |

## Policy, QoS & Buffers

These Orchs enforce traffic policy — which packets are permitted, how they are queued, and how buffer resources are allocated.

| Orch Class    | DB | Tables | What It Handles |
|---------------|---|---|---|
| `AclOrch`     | CONFIG_DB, APPL_DB | ACL_TABLE, ACL_TABLE_TYPE, ACL_RULE (both DBs) | Access Control Lists |
| `QosOrch`     | CONFIG_DB | TC_TO_QUEUE_MAP, DSCP_TO_TC_MAP, DOT1P_TO_TC_MAP, SCHEDULER, WRED_PROFILE, QUEUE, PORT_QOS_MAP, and 7 more map tables | QoS maps, scheduling, WRED, PFC |
| `BufferOrch`  | APPL_DB | BUFFER_POOL_TABLE, BUFFER_PROFILE_TABLE, BUFFER_QUEUE_TABLE, BUFFER_PG_TABLE, BUFFER_PORT_INGRESS/EGRESS_PROFILE_LIST_TABLE | Buffer pools, profiles, PG/queue assignment |
| `CoppOrch`    | APPL_DB | COPP_TABLE | Control-plane policing trap groups |
| `PolicerOrch` | CONFIG_DB | POLICER, PORT_STORM_CONTROL | Traffic policers, storm control |
| `PbhOrch`     | CONFIG_DB | PBH_TABLE, PBH_RULE, PBH_HASH, PBH_HASH_FIELD | Policy-based hashing |

## Tunneling & Overlay

These Orchs manage tunnel encapsulation/decapsulation and virtual-network overlays.

| Orch Class | DB | Tables | What It Handles |
|---|---|---|---|
| `TunnelDecapOrch` | APPL_DB, CONFIG_DB, STATE_DB | TUNNEL_DECAP_TABLE, TUNNEL_DECAP_TERM_TABLE | IP-in-IP tunnel decapsulation |
| `VxlanTunnelOrch` | STATE_DB, APPL_DB | VXLAN_TUNNEL_TABLE | VxLAN tunnel endpoints |
| `VxlanTunnelMapOrch` | APPL_DB | VXLAN_TUNNEL_MAP_TABLE | VxLAN tunnel-to-VLAN mapping |
| `VxlanVrfMapOrch` | APPL_DB | VXLAN_VRF_TABLE | VxLAN-to-VRF mapping (L3 VxLAN) |
| `EvpnNvoOrch` | APPL_DB | VXLAN_EVPN_NVO_TABLE | EVPN Network Virtualization Overlay |
| `EvpnRemoteVniOrch` | APPL_DB | VXLAN_REMOTE_VNI_TABLE | Remote VxLAN VNI endpoints |
| `VNetOrch` | APPL_DB | VNET_TABLE | Virtual network definitions |
| `VNetRouteOrch` | APPL_DB | VNET_ROUTE_TABLE, VNET_ROUTE_TUNNEL_TABLE | VNET routes and tunnel routes |
| `VNetCfgRouteOrch` | CONFIG_DB | VNET_ROUTE, VNET_ROUTE_TUNNEL | VNET static routes (from config) |
| `NvgreTunnelOrch` | CONFIG_DB | NVGRE_TUNNEL | NVGRE tunnel endpoints |
| `NvgreTunnelMapOrch` | CONFIG_DB | NVGRE_TUNNEL_MAP | NVGRE tunnel-to-VSID mapping |

## Monitoring, Telemetry & Mirroring

These Orchs track resource usage, protocol health, and mirror traffic for analysis.

| Orch Class | DB | Tables | What It Handles |
|---|---|---|---|
| `CrmOrch` | CONFIG_DB | CRM | Critical resource monitoring thresholds |
| `MirrorOrch` | CONFIG_DB, STATE_DB | MIRROR_SESSION (config), MIRROR_SESSION_TABLE (state) | Port mirroring / ERSPAN |
| `BfdOrch` | APPL_DB, STATE_DB | BFD_SESSION_TABLE | BFD session management |
| `IcmpOrch` | APPL_DB, STATE_DB | ICMP_ECHO_SESSION_TABLE | ICMP echo session monitoring |
| `MonitorOrch` | STATE_DB | VNET_MONITOR_TABLE | VNET endpoint health probing |
| `BfdMonitorOrch` | STATE_DB | BFD_SESSION_TABLE | BFD-triggered VNET failover |
| `SflowOrch` | APPL_DB | SFLOW_TABLE, SFLOW_SESSION_TABLE, SFLOW_SAMPLE_RATE_TABLE | sFlow sampling and collectors |
| `TwampOrch` | CONFIG_DB, STATE_DB | TWAMP_SESSION (config), TWAMP_SESSION_TABLE (state) | TWAMP performance measurement |

## Security & Protocol Features

| Orch Class | DB | Tables | What It Handles |
|---|---|---|---|
| `MACsecOrch` | APPL_DB, STATE_DB | MACSEC_PORT_TABLE, MACSEC_EGRESS/INGRESS_SC_TABLE, MACSEC_EGRESS/INGRESS_SA_TABLE | MACsec encryption on ports |
| `NatOrch` | APPL_DB, STATE_DB | NAT_DNAT_POOL_TABLE, NAT_TABLE, NAPT_TABLE, NAT_TWICE_TABLE, NAPT_TWICE_TABLE, NAT_GLOBAL_TABLE | Static and dynamic NAT/NAPT |
| `StpOrch` | APPL_DB, STATE_DB | STP_VLAN_INSTANCE_TABLE, STP_PORT_STATE_TABLE, STP_FASTAGEING_FLUSH_TABLE, STP_INST_PORT_FLUSH_TABLE | Spanning Tree Protocol |
| `Srv6Orch` | APPL_DB, CONFIG_DB | SRV6_SID_LIST_TABLE, SRV6_MY_SID_TABLE, PIC_CONTEXT_TABLE (appl), SRV6_MY_SIDS (config) | SRv6 segment routing |

## Specialized Next-Hop Groups

> The primary `NhgOrch` (standard ECMP) is listed under [Core Data Plane](#core-data-plane). The Orchs below handle specialized next-hop group variants.

| Orch Class | DB | Tables | What It Handles |
|---|---|---|---|
| `FgNhgOrch` | CONFIG_DB | FG_NHG, FG_NHG_PREFIX, FG_NHG_MEMBER | Fine-grained ECMP (consistent hashing) |
| `CbfNhgOrch` | APPL_DB | CLASS_BASED_NEXT_HOP_GROUP_TABLE | Class-based forwarding NHGs |
| `NhgMapOrch` | APPL_DB | FC_TO_NHG_INDEX_MAP_TABLE | Forwarding-class-to-NHG index map |
| `L2NhgOrch` | APPL_DB | L2_NEXTHOP_GROUP_TABLE | L2 next-hop groups |

## Dual-ToR, Multi-Homing & MCLAG

| Orch Class | DB | Tables | What It Handles |
|---|---|---|---|
| `MuxOrch` | CONFIG_DB | MUX_CABLE, PEER_SWITCH | Dual-ToR MUX cable configuration |
| `MuxCableOrch` | APPL_DB, STATE_DB | MUX_CABLE_TABLE | Dual-ToR MUX cable switching |
| `MuxStateOrch` | STATE_DB | HW_MUX_CABLE_TABLE | Dual-ToR hardware MUX state |
| `EvpnMhOrch` | APPL_DB, CONFIG_DB | EVPN_DF_TABLE (appl), EVPN_ETHERNET_SEGMENT (config) | EVPN multi-homing DF election |
| `ShlOrch` | APPL_DB | EVPN_SPLIT_HORIZON_TABLE | EVPN split-horizon filtering |
| `IsoGrpOrch` | APPL_DB | ISOLATION_GROUP_TABLE | Port isolation groups |
| `MlagOrch` | CONFIG_DB | MCLAG_DOMAIN, MCLAG_INTERFACE | MCLAG domain and interface config |

## Switch Configuration & Counters

| Orch Class | DB | Tables | What It Handles |
|---|---|---|---|
| `SwitchOrch` | CONFIG_DB, APPL_DB | ASIC_SENSORS, SWITCH_HASH, SWITCH_TRIMMING, SWITCH_FAST_LINKUP, SUPPRESS_ASIC_SDK_HEALTH_EVENT (config), SWITCH_TABLE (appl) | Global switch attributes |
| `FlexCounterOrch` | CONFIG_DB | FLEX_COUNTER_TABLE, DEVICE_METADATA | Flex counter group enable/disable |
| `WatermarkOrch` | CONFIG_DB | WATERMARK_TABLE, FLEX_COUNTER_TABLE | Watermark telemetry intervals |
| `DebugCounterOrch` | CONFIG_DB | DEBUG_COUNTER, DEBUG_COUNTER_DROP_REASON, DEBUG_DROP_MONITOR | Debug drop counters |
| `PfcWdSwOrch` | CONFIG_DB | PFC_WD | PFC watchdog detection and mitigation |
| `BgpGlobalStateOrch` | CONFIG_DB | BGP_DEVICE_GLOBAL | BGP device-level global settings |
| `FlowCounterRouteOrch` | CONFIG_DB | FLOW_COUNTER_ROUTE_PATTERN | Per-route flow counter patterns |
| `ChassisOrch` | CONFIG_DB, APPL_DB | PASS_THROUGH_ROUTE_TABLE | Chassis pass-through route forwarding |

## Platform-Specific (Conditionally Loaded)

| Orch Class | DB | Tables | What It Handles |
|---|---|---|---|
| `FabricPortsOrch` | APPL_DB | FABRIC_PORT_TABLE, FABRIC_MONITOR_TABLE | Fabric port monitoring (VOQ chassis) |
| `DTelOrch` | CONFIG_DB | DTEL, DTEL_REPORT_SESSION, DTEL_INT_SESSION, DTEL_QUEUE_REPORT, DTEL_EVENT | Dataplane telemetry (Memory only) |
| `HFTelOrch` | CONFIG_DB, STATE_DB | HIGH_FREQUENCY_TELEMETRY_PROFILE, HIGH_FREQUENCY_TELEMETRY_GROUP | High-frequency telemetry |
| `P4Orch` | APPL_DB | P4RT_TABLE | P4Runtime programmable pipeline |
| `DashEniFwdOrch` | CONFIG_DB, APPL_DB | DASH_ENI_FORWARD_TABLE | DASH ENI forwarding (SmartSwitch only) |

> **Note**: DPU switch types load additional DASH-specific Orchs (`DashOrch`, `DashVnetOrch`, `DashRouteOrch`, `DashAclOrch`, `DashHaOrch`, `DashTunnelOrch`, `DashMeterOrch`, `DashPortMapOrch`, `DashHaFlowOrch`) — all subscribing to `DPU_APPL_DB` tables. Fabric switch types load only `FabricPortsOrch` and `FlexCounterOrch`.

---

**Previous**: [← Orchagent Deep Dive](12_orchagent.md) · **Next**: [SAI and Syncd →](14_sai_and_syncd.md)
