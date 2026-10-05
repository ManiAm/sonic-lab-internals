# SONiC Container Architecture

This document introduces the container-based architecture SONiC uses to organize its subsystems. It covers what containers are, why SONiC chose them, and what trade-offs they bring. Detailed coverage of how container images are built and how containers are managed on a live switch is split into companion documents, linked at the end.

## What Is a Container?

A **container** is a lightweight, isolated environment that packages an application together with everything it needs to run — libraries, configuration files, and helper tools — so it behaves the same regardless of the host it runs on. Unlike a virtual machine, which runs an entire separate operating system on top of a hypervisor, a container shares the host's Linux kernel directly. This makes containers fast to start and adds minimal overhead compared to running the application directly on the host.

## SONiC Uses Docker

SONiC uses **Docker** as its container runtime. Docker builds container **images** (read-only filesystem snapshots) and runs **containers** (live instances created from those images). Each SONiC subsystem — BGP, LLDP, SNMP, the switch state service, and so on — runs in its own container.

## Key Terminology

| Term                | Meaning |
|---------------------|---------|
| **Image**           | A read-only template containing the filesystem, libraries, and binaries for a container |
| **Container**       | A running (or stopped) instance created from an image |
| **Dockerfile**      | A text file with step-by-step instructions for building an image |
| **Entrypoint**      | The command Docker executes automatically when a container starts |
| **Volume mount**    | A host directory made visible inside the container, so both sides see the same files |
| **systemd**         | The standard Linux service manager on the host. It decides when to start and stop containers, enforces dependency ordering between them, and handles automatic restarts. |
| **supervisord**     | A lightweight process manager that runs *inside* each container. It starts and watches the container's individual daemons, much like systemd manages services on the host — but without all the machine-level complexity systemd carries. |

## Why SONiC Uses Containers

SONiC chose containers for the following reasons:

- **Fault isolation.** Each container runs independently, so a crash or misconfiguration in one subsystem does not bring down the others — the *blast radius* of any failure is limited to the container it occurs in. If the SNMP container crashes, the switch continues forwarding traffic, BGP sessions stay up, and only SNMP monitoring is temporarily lost.

- **Complete dependency isolation.** Each container bundles its own libraries. The BGP routing suite can use one version of a library while the SNMP service uses another. No conflicts arise because each container's filesystem is independent. Without containers, upgrading a shared library for one daemon might break another — a common problem known as "dependency hell."

- **Independent upgrades without reboot.** You can upgrade the BGP container to a new routing software version without touching anything else. Stop the old container, start the new one. The ASIC continues forwarding traffic with the existing programmed state.

- **Resource limits.** Containers leverage cgroups to enforce CPU, memory, and I/O limits, so a runaway process in one container cannot starve the others.

- **Uniform lifecycle management.** Every container follows the same pattern: a Dockerfile defines its contents, an entrypoint script handles initialization, and supervisord (a lightweight process manager) manages the processes inside. Adding a new feature means adding a new container that follows the same recipe.

- **Build-time feature selection.** SONiC can include or exclude containers from the build image. A minimal spine switch might ship with only the database, swss, syncd, and BGP containers, while a full-featured leaf switch might include all 15+ containers. At runtime, individual containers can be enabled or disabled via the FEATURE table.

- **Kubernetes-ready future.** The SONiC community has explored using Kubernetes to orchestrate container updates across a fleet of switches — for example, rolling out a new telemetry container to thousands of switches without rebooting any of them. This work is experimental but the container-based architecture makes it feasible.

## What Containers Cost

Containers are not free. Here are the trade-offs SONiC accepts for this architecture:

| Cost                | Impact |
|---------------------|--------|
| **Disk footprint**  | Each container duplicates base OS layers (~100–300 MB per container, mitigated by shared layers) |
| **Memory overhead** | Each container has its own process namespace, supervisord, and rsyslog (~30–50 MB overhead per container) |
| **Complexity**      | Docker daemon, container networking, volume mounts — more moving parts than running bare processes on the host |
| **Startup time**    | Containers take longer to start than bare processes due to Docker create and start overhead |
| **Debugging**       | Must `docker exec` into containers to inspect them; logs are spread across containers rather than in one place |

For resource-constrained platforms (switches with as little as 4 GB of RAM), these costs matter. This is why SONiC allows disabling containers at build time or at runtime.


## Container Categories

Now that you know what containers are and why SONiC uses them, here is what actually runs on a SONiC switch. The containers fall into four groups based on their role.

### Core Containers

These containers must be running for the switch to function at all:

| Container    | Role |
|--------------|------|
| **database** | Runs Redis instances — the central data bus that all other containers communicate through. Must start before all others, since every container depends on Redis being available. |
| **swss**     | Switch State Service — contains orchagent (the orchestration agent that translates application state into hardware instructions) and manager daemons (which validate and transform configuration). Orchestrates state flow from `CONFIG_DB` through `APPL_DB` to `ASIC_DB`. |
| **syncd**    | Synchronization daemon — reads hardware-ready objects from `ASIC_DB` and programs the physical ASIC through the SAI API (the vendor-agnostic hardware abstraction introduced in [What is SONiC?](01_what_is_sonic.md)). |

### Feature Containers

These containers provide specific networking functions — routing, link aggregation, protocol discovery, etc. They read configuration from Redis and write their computed state back to Redis.

| Container       | Role |
|-----------------|------|
| **bgp**         | Routing protocols (FRR: BGP, OSPF, static routes) |
| **teamd**       | Link aggregation (LACP / port-channels) |
| **lldp**        | Link Layer Discovery Protocol — discovers directly connected neighbors |
| **dhcp_relay**  | Relays DHCP requests across VLANs or VRFs |
| **radv**        | Router Advertisement daemon — sends IPv6 router advertisements to hosts |
| **nat**         | Network Address Translation |
| **sflow**       | sFlow sampling agent — exports sampled traffic to a collector for visibility |
| **dhcp_server** | DHCP server for assigning IP addresses to connected devices |
| **macsec**      | MACsec link-layer encryption (conditionally enabled on spine routers) |
| **stp**         | Spanning Tree Protocol — prevents Layer 2 loops |
| **iccpd**       | Inter-Chassis Communication Protocol — enables MC-LAG (multi-chassis link aggregation) |
| **mux**         | Dual-ToR multiplexer (enabled only in DualToR high-availability deployments) |

### Monitoring and Management Containers

These containers provide visibility and operator interfaces. They mostly read from Redis to export state or serve management requests.

| Container          | Role |
|--------------------|------|
| **pmon**           | Platform monitor — tracks fans, PSUs, optics, and temperatures |
| **snmp**           | SNMP agent for network monitoring systems |
| **telemetry**      | gNMI streaming telemetry for real-time state export |
| **gnmi**           | gNMI server — provides a gRPC-based interface for configuration and state management |
| **mgmt-framework** | REST API and KLISH CLI (an alternative command-line shell) |
| **restapi**        | REST API endpoint for programmatic access (separate from mgmt-framework) |
| **eventd**         | System event logging and alerting |
| **bmp**            | BGP Monitoring Protocol — exports BGP RIB and peer state to a BMP collector (OpenBMP) for route analytics |
| **otel**           | OpenTelemetry collector — exports metrics, traces, and logs to observability backends |
| **p4rt**           | P4Runtime server — allows programming the forwarding pipeline using the P4 language |
| **sysmgr**         | System manager — coordinates system-level health checks and lifecycle events |

### SmartSwitch / DPU Containers

These containers are specific to SmartSwitch and DPU (Data Processing Unit) deployments. They are conditionally included based on platform type.

| Container    | Role |
|--------------|------|
| **dash-ha**  | DASH High Availability — manages failover and state synchronization for SmartSwitch DPU pipelines |
| **gbsyncd**  | Gearbox syncd — synchronizes state to gearbox PHY ASICs (external PHY devices that sit between the switch ASIC and the front-panel ports) |


## Build Time vs. Run Time

SONiC's container lifecycle splits cleanly into two phases. Confusing them is the most common source of misunderstanding for newcomers:

| Phase          | When it happens                                     | What it produces |
|----------------|-----------------------------------------------------|------------------|
| **Build time** | On a build server, when the SONiC image is compiled | Container images, systemd unit files, and per-container control scripts — all baked into the installable SONiC image |
| **Run time**   | On the switch, every boot                           | Live containers, runtime configuration generated from Redis, and running daemons |

These phases are covered in separate documents:

- **[Container Build Time](04_container_build_time.md)** — how Dockerfiles, the image hierarchy, and the build system produce container images

- **[Container Run Time](05_container_run_time.md)** — how systemd, the control scripts, and the FEATURE table manage containers from the host

- **[Inside a Running Container](06_inside_a_running_container.md)** — entrypoint, supervisord, logging, health monitoring, and failure recovery inside a container

---

**Previous**: [← Architecture Overview](02_architecture_overview.md) · **Next**: [Container Build Time →](04_container_build_time.md)
