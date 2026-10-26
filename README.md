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

### SWSS & Orchagent

| #  | Topic | Description |
|----|-------|-------------|
| 11 | [The SWSS Container](docs/11_swss_container.md) | Manager daemons, sync daemons, and orchagent overview |
| 12 | [Orchagent Deep Dive](docs/12_orchagent.md) | Orch architecture, task queues, SAI interaction, sync vs async mode |
| 13 | [The Orch Catalog](docs/13_orch_catalog.md) | Every Orch module — DB tables, responsibilities, grouped by function |

### SAI & Syncd

| #  | Topic | Description |
|----|-------|-------------|
| 14 | [SAI and Syncd](docs/14_sai_and_syncd.md) | The SAI API, meta layer, syncd processing, VID/RID |
| 15 | [The SAI Object Model](docs/15_sai_object_model.md) | Object identification, attribute semantics, the group+member pattern, capability queries, bulk operations, stats, and notifications |
| 16 | [Flex Counters](docs/16_flex_counters.md) | FlexCounterOrch, FLEX_COUNTER_DB, syncd polling, counter groups, and COUNTERS_DB |
| 17 | [Flex Counter Groups Reference](docs/17_flex_counter_groups_reference.md) | Every SAI stat ID polled by each counter group — ports, queues, PGs, buffers, LAGs, tunnels, ACLs, and MACsec |

### Data-Plane Programming

| #  | Topic | Description |
|----|-------|-------------|
| 18 | [Ports and Host Interfaces](docs/18_ports_and_host_interfaces.md) | SAI port objects, the port initialization pipeline, PortInitDone, host interfaces, data-plane vs control-plane traffic, and tcpdump |
| 19 | [The Forwarding Chain](docs/19_forwarding_chain.md) | Router interfaces, source MAC, ARP/NDP neighbors, next-hop creation, and IntfsOrch / NeighOrch |
| 20 | [Punting](docs/20_punting.md) | Packets from ASIC to CPU — fast path vs slow path, SAI trap objects, trap groups, CoPP rate limiting, coppmgrd, and CoppOrch |

### Routing & Forwarding

| #  | Topic | Description |
|----|-------|-------------|
| 21 | [The BGP Container and FRR](docs/21_bgp_container.md) | FRRouting, zebra, fpmsyncd, route programming, RIB/FIB mapping, unified/split mode |
| 22 | [The BGP Route-Download Benchmark](docs/22_benchmark.md) | Measuring route programming rate end-to-end, pipeline stages, tooling, and measured results |
| 23 | [Load Balancing](docs/23_load_balancing.md) | ECMP in SONiC — SAI next-hop group types, routeorch, weighted ECMP (WCMP), fine-grained ECMP, class-based forwarding, and the full weight pipeline |
| 24 | [SAI Next-Hop Group Types](docs/24_nhg_types.md) | Per-type deep dive — Dynamic ECMP, Fine-Grain ECMP, W-ECMP, Class-Based Forwarding, Protection Groups, and Bridge Port groups |

### Platform & Hardware

| #  | Topic | Description |
|----|-------|-------------|
| 25 | [The PMON Container](docs/25_pmon_container.md) | Platform Monitor — Platform API, vendor plugins, xcvrd, psud, thermalctld, ledd, and hardware monitoring |
| 26 | [Platform Configuration](docs/26_platform_configuration.md) | The device/ hierarchy, ONIE platform strings, HwSKU folders, port_config.ini, platform.json, and how platform files seed CONFIG_DB |
| 27 | [Host Services](docs/27_host_services.md) | System health monitoring (healthd), monit, watchdog control, and other host-level systemd services |

### Configuration & Lifecycle

| #  | Topic | Description |
|----|-------|-------------|
| 28 | [Configuration Management](docs/28_configuration_management.md) | config_db.json, CLI, YANG validation, save, load, patch, replace, and reload |
| 29 | [Config Reload](docs/29_config_reload.md) | CONFIG_DB flush and reload, service stop/start order, delayed service start, config reload vs alternatives |
| 30 | [Reboot Types](docs/30_reboot_types.md) | Cold, soft, fast, warm, and express reboot comparison |
| 31 | [Warm Reboot Deep Dive](docs/31_warm_reboot.md) | Pre-shutdown state saving, kexec kernel transition, reconciliation, warmboot-finalizer, container-level warm restart |

### Observability & Troubleshooting

| #  | Topic | Description |
|----|-------|-------------|
| 32 | [State Interactions](docs/32_state_interactions.md) | End-to-end data flows for routing, port events, VLAN, ARP |
| 33 | [Logging](docs/33_logging.md) | Syslog, rsyslog routing, SWSS logging macros, SAI recording, log rotation, runtime tuning, techsupport, core dumps |
| 34 | [Troubleshooting](docs/34_troubleshooting.md) | Debugging techniques for common SONiC problems |
