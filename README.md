# SONiC Internals Lab

A beginner-friendly, step-by-step guide to understanding SONiC (Software for Open Networking in the Cloud) internals. This documentation covers the architecture, design principles, and internal workings of upstream SONiC.

## Prerequisites

- Basic Linux knowledge (filesystems, processes, networking)
- Redis fundamentals → covered in the companion project: [sonic-lab-redis](https://github.com/ManiAm/sonic-lab-redis)

## Documentation

Read in order — each document builds on the concepts from the previous ones.

### Foundations

| #  | Topic | Description |
|----|-------|-------------|
| 01 | [What is SONiC?](docs/01_what_is_sonic.md) | Switches and ASICs, disaggregation, SAI, containers, why Debian, and other open network operating systems |
| 02 | [Architecture Overview](docs/02_architecture_overview.md) | System layers, control plane vs data plane, container categories, and the programming pipeline |

### Container Lifecycle

| #  | Topic | Description |
|----|-------|-------------|
| 03 | [SONiC Container Architecture](docs/03_sonic_container.md) | What containers are, why SONiC uses them, and the trade-offs |
| 04 | [Container Build Time](docs/04_container_build_time.md) | Dockerfile templates, the image hierarchy, and build outputs |
| 05 | [Container Run Time](docs/05_container_run_time.md) | How systemd and host scripts start and control containers; the FEATURE table |
| 06 | [Inside a Running Container](docs/06_inside_a_running_container.md) | Entrypoint scripts, supervisord, logging, and health monitoring |

### Database & Communication

| #  | Topic | Description |
|----|-------|-------------|
| 07 | [The Database Container](docs/07_database_container.md) | Redis instances, multi-DB mode, Unix sockets, persistence |
| 08 | [Core Redis Databases](docs/08_redis_databases.md) | CONFIG_DB, APPL_DB, ASIC_DB, STATE_DB — what each stores and who uses it |
| 09 | [Container Communication](docs/09_container_communication.md) | How containers talk to each other and to the host |
| 10 | [IPC Mechanisms](docs/10_ipc_mechanisms.md) | The five messaging patterns daemons use to stay in sync |

### SWSS, Orchagent & SAI

| #  | Topic | Description |
|----|-------|-------------|
| 11 | [The SWSS Container](docs/11_swss_container.md) | Manager daemons, sync daemons, and orchagent overview |
| 12 | [Orchagent Deep Dive](docs/12_orchagent.md) | Orch architecture, task queues, SAI interaction, sync vs async mode |
| 13 | [SAI and Syncd](docs/13_sai_and_syncd.md) | Switch Abstraction Interface, meta layer, syncd processing, VID/RID |
| 14 | [The SAI Object Model](docs/14_sai_object_model.md) | Object identification, attribute semantics, the group+member pattern, capability queries, bulk operations, stats, and notifications |
| 15 | [Flex Counters](docs/15_flex_counters.md) | FlexCounterOrch, FLEX_COUNTER_DB, syncd polling, counter groups, and COUNTERS_DB |
| 16 | [Flex Counter Groups Reference](docs/16_flex_counter_groups_reference.md) | Every SAI stat ID polled by each counter group — ports, queues, PGs, buffers, LAGs, tunnels, ACLs, and MACsec |
| 17 | [Ports, Interfaces, and Neighbors](docs/17_ports_interfaces_neighbors.md) | The forwarding object chain — SAI ports, the L2→L3 transition (router interfaces), ARP/NDP neighbors, next-hop creation, and PortsOrch / IntfsOrch / NeighOrch |

### Routing & Forwarding

| #  | Topic | Description |
|----|-------|-------------|
| 18 | [The BGP Container and FRR](docs/18_bgp_container.md) | FRRouting, zebra, fpmsyncd, route programming, RIB/FIB mapping, unified/split mode |
| 19 | [The BGP Route-Download Benchmark](docs/19_benchmark.md) | Measuring route programming rate end-to-end, pipeline stages, tooling, and measured results |
| 20 | [Load Balancing](docs/20_load_balancing.md) | ECMP in SONiC — SAI next-hop group types, routeorch, weighted ECMP (WCMP), fine-grained ECMP, class-based forwarding, and the full weight pipeline |
| 21 | [SAI Next-Hop Group Types](docs/21_nhg_types.md) | Per-type deep dive — Dynamic ECMP, Fine-Grain ECMP, W-ECMP, Class-Based Forwarding, Protection Groups, and Bridge Port groups |

### Platform & Hardware

| #  | Topic | Description |
|----|-------|-------------|
| 22 | [The PMON Container](docs/22_pmon_container.md) | Platform Monitor — Platform API, vendor plugins, xcvrd, psud, thermalctld, ledd, and hardware monitoring |
| 23 | [Platform Configuration](docs/23_platform_configuration.md) | The device/ hierarchy, ONIE platform strings, HwSKU folders, port_config.ini, platform.json, and how platform files seed CONFIG_DB |
| 24 | [Host Services](docs/24_host_services.md) | System health monitoring (healthd), monit, watchdog control, and other host-level systemd services |

### Configuration & Lifecycle

| #  | Topic | Description |
|----|-------|-------------|
| 25 | [Configuration Management](docs/25_configuration_management.md) | config_db.json, CLI, YANG validation, save, load, patch, replace, and reload |
| 26 | [Config Reload](docs/26_config_reload.md) | CONFIG_DB flush and reload, service stop/start order, delayed service start, config reload vs alternatives |
| 27 | [Reboot Types](docs/27_reboot_types.md) | Cold, soft, fast, warm, and express reboot comparison |
| 28 | [Warm Reboot Deep Dive](docs/28_warm_reboot.md) | Pre-shutdown state saving, kexec kernel transition, reconciliation, warmboot-finalizer, container-level warm restart |

### Observability & Troubleshooting

| #  | Topic | Description |
|----|-------|-------------|
| 29 | [State Interactions](docs/29_state_interactions.md) | End-to-end data flows for routing, port events, VLAN, ARP |
| 30 | [Logging](docs/30_logging.md) | Syslog, rsyslog routing, SWSS logging macros, SAI recording, log rotation, runtime tuning, techsupport, core dumps |
| 31 | [Troubleshooting](docs/31_troubleshooting.md) | Debugging techniques for common SONiC problems |
