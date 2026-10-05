# Container Communication

## Overview

Recall the [big picture diagram](02_architecture_overview.md#the-big-picture) from the Architecture Overview — it shows where containers, the kernel, and the hardware sit relative to each other. SONiC containers exchange information through three paths:

1. **Unix domain sockets** — for daemon-to-daemon communication within the same container.
2. **Redis** — for all structured communication between containers.
3. **The Linux kernel** — for containers to interact with the operating system and hardware (not with each other).

This chapter covers all three paths, then explains `swsscommon`, the shared library that makes Redis-based communication reliable enough for production use.

## 1. Unix Domain Sockets — Intra-Container Communication

A **Unix domain socket** is a special file on the local filesystem that two processes can open to exchange data, similar to a network connection but without any network overhead. Both sides must be on the same machine.

Within a single container, daemons sometimes need to talk directly to each other. They do this through Unix domain sockets. For example, inside the BGP container, FRR's `zebra` process talks to `fpmsyncd` through a Unix domain socket. Both daemons live in the same container, so there is no need to go through Redis — a local socket is simpler and faster. This pattern appears wherever multiple daemons in the same container need to coordinate.

Understanding Unix domain sockets now matters because the next section — Redis communication between containers — relies on the same mechanism to connect containers to the Redis server.

## 2. Redis — Container-to-Container Communication

There is no direct connection between any two containers in SONiC. The BGP container cannot call a function in the SWSS container. The SYNCD container cannot send a message to the PMON container. All structured communication between containers goes through Redis: a process in one container writes to a Redis table, and a process in another container receives a notification and reads the update.

```
BGP container                                          SWSS container
┌─────────────┐                                       ┌─────────────┐
│ fpmsyncd    │── writes to ──→ APPL_DB ──→ read by ──│ orchagent   │
└─────────────┘                                       └─────────────┘
```

In this example, `fpmsyncd` is a daemon inside the BGP container that takes routes computed by the FRR routing suite and writes them to APPL_DB. `orchagent` is the orchestration daemon inside the SWSS container that reads from APPL_DB and translates application state into hardware instructions. There is no socket, pipe, or shared memory between these two containers — Redis is the only bridge.

This is a direct application of two core SONiC design principles — **database-centric design** (all state lives in one shared store) and **modularity** (each subsystem runs in its own isolated container). Because all state exchange goes through Redis, containers remain fully decoupled. They can be restarted, upgraded, or replaced independently, and all system state is visible and inspectable in one place.

### How Containers Connect to Redis

Each container has its own isolated filesystem, so it cannot directly see the Redis process running inside the database container. The connection works through **shared volume mounts** — host directories that Docker makes accessible inside multiple containers.

Here is how it works step by step:

1. The database container creates Unix domain sockets (the same kind of special files described in Section 1) at `/var/run/redis/sonic-db/` on the host filesystem.
2. When every other container is started, Docker mounts that same host directory into the container using the `-v` flag.
3. Each container now sees the same socket files at the same path, so any process in any container can open these socket files to read from and write to Redis — even though the Redis server is running in a different container.

```
Host filesystem
/var/run/redis/sonic-db/
├── redis.sock            ← created by the database container
├── redis1.sock
├── redis2.sock
├── redis3.sock
└── database_config.json

mounted into every container via:
docker create -v /var/run/redis/sonic-db/:/var/run/redis/sonic-db/ ...
```

### Unix Sockets vs. TCP

Unix domain sockets are the default connection method and are preferred for single-box deployments — access is controlled through file permissions (no network-level ACLs needed), and they have slightly lower latency than TCP loopback.

SONiC also supports **TCP connections** to Redis. This is used in **modular chassis systems**, where the database container runs on a supervisor card and line cards connect to it over the network. In that setup, Unix sockets cannot work because the line cards are on separate machines and do not share a filesystem with the supervisor.

| Method          | How                                     | Default? | Use Case |
|-----------------|-----------------------------------------|----------|----------|
| **Unix Socket** | `/var/run/redis/sonic-db/redis<N>.sock` | Yes      | Same-host communication — faster, more secure |
| **TCP**         | `127.0.0.1:<port>`                      | No       | Cross-host communication (modular chassis systems) |

## 3. The Linux Kernel — Container-to-System Communication

Containers also interact with the **Linux kernel**, but this is not container-to-container or intra-container communication. It is how containers stay synchronized with the underlying operating system and hardware.

- **Netlink sockets** — The kernel notifies containers about network events such as route additions, neighbor discoveries, and link state changes. Multiple containers may independently listen to kernel events, but they are not communicating *with each other* — they are each independently listening to the kernel.

- **/sys filesystem** — Containers read hardware attributes (fan speeds, temperatures, transceiver data) exposed by kernel drivers.

### Network Namespaces and `--net=host`

Unlike typical Docker deployments where each container has its own isolated network stack, most SONiC containers run with `--net=host` — they share the host's network namespace. This means every container can directly see and interact with all host network interfaces (e.g., `Ethernet0`, `PortChannel1`). This is by design: networking daemons need direct access to the kernel's network stack to manage interfaces and listen for Netlink events.

---

## Summary

| Path               | Between                          | Example                                      |
|--------------------|----------------------------------|----------------------------------------------|
| Unix domain socket | Daemon ↔ Daemon (same container) | zebra ↔ fpmsyncd (both inside the BGP container) |
| Redis              | Container ↔ Container            | BGP writes routes to APPL_DB, orchagent (in SWSS) reads them |
| Netlink            | Kernel → Container               | Kernel notifies portsyncd (in SWSS) that a link went down |
| /sys filesystem    | Container → Hardware             | PMON reads temperature sensors via sysfs |

---

## The `swsscommon` Library

### What We Already Know

Sections 1 and 2 established a key fact: the Redis Unix socket is mounted into every container. Any process in any container can open that socket and issue standard Redis commands — `HSET`, `HGET`, `PUBLISH`, `SUBSCRIBE` — to read from and write to any Redis database. No special library is required.

> For a comprehensive coverage of Redis — data types, pub/sub, transactions, persistence, and more — see [sonic-lab-redis](https://github.com/ManiAm/sonic-lab-redis) project.

Many components do exactly this. Every shell script that runs `sonic-db-cli CONFIG_DB HGET ...` is issuing a plain Redis command over that socket. The CLI (`show interfaces status`), health-check scripts, and one-shot configuration loaders all talk to Redis directly. For simple reads and writes, raw Redis access works well.

### Where Raw Redis Falls Short

The trouble starts when a daemon in one container must *stay continuously in sync* with state that another container owns. Consider a concrete example: route programming.

`fpmsyncd` (in the BGP container) learns that the FRR routing suite has computed a new route to `10.0.0.0/24`. It needs to get that route into APPL_DB so that `orchagent` (in the SWSS container) can read it and program the ASIC. Using raw Redis, the most obvious approach would be:

1. `fpmsyncd` writes the route's fields to a Redis hash — next hop, interface, weight — one field at a time.
2. `fpmsyncd` publishes a notification on a Redis pub/sub channel to tell orchagent that new data is available.
3. `orchagent`, which is subscribed to that channel, receives the notification and reads the hash.

This seems straightforward, but it breaks in four ways:

**Problem 1 — Lost updates.** As discussed in the [Pub/Sub](https://github.com/ManiAm/sonic-lab-redis/blob/master/docs/07_redis_pub_sub.md) section of the Redis companion project, Redis pub/sub is fire-and-forget — messages are delivered only to subscribers connected at the moment of publishing, with no buffering or replay. This means if orchagent is busy processing a previous batch, or is in the middle of restarting, the notification is gone forever. Orchagent never learns that `10.0.0.0/24` was added. The route exists in APPL_DB but the ASIC is never programmed. The database and the hardware now permanently disagree, and nothing crashes to signal the problem.

**Problem 2 — Churn.** In networking, **churn** refers to rapid, repeated changes to the same piece of state — the word evokes a churning motion, the same thing turning over and over. A common cause is a **flapping** link: a cable with a loose connection that goes up, down, up, down many times per second. Each time the link bounces, the routing protocol recomputes the best path and the next hop for affected routes changes. Suppose this happens to `10.0.0.0/24` — its next hop changes a thousand times per second. Each change produces a pub/sub notification. Orchagent must process every single one, even though only the last value matters. The consumer falls behind, wastes CPU, and introduces latency for every other route in the system.

**Problem 3 — Half-written objects.** A route is not a single value — it is a hash with multiple fields (next hop, interface, weight). `fpmsyncd` writes these fields one at a time. If orchagent reads the hash between the first and second write, it sees a route with a next hop but no interface. It programs this incomplete object into the ASIC — a silent data-corruption bug that is hard to diagnose.

**Problem 4 — Locating the data.** Which Redis database holds this table? Which Unix socket serves that database? Is the key separator `|` or `:`? On a multi-ASIC platform, which namespace does the table belong to? Every daemon would need to hardcode these answers, and every daemon would need to be updated whenever the layout changes.

### The Solution: `swsscommon`

A shared library called **`swsscommon`** solves all these problems. It is included in every container's [base image](05_container_build_time.md#the-image-hierarchy) and is the standard way SONiC daemons communicate through Redis. It connects through the very same Redis Unix socket described in Section 2. It is not an alternative transport, but a layer of code that issues Redis commands with the reliability guarantees that raw Redis lacks.

The core idea: instead of delivering updates as transient pub/sub messages, `swsscommon` keeps pending work **in the database as stored state**.

- A **producer** records the changed key in a Redis set and stages its fields in a temporary hash.
- A **consumer** drains that set when it is ready.

This design directly addresses each of the four problems:

| Problem | How `swsscommon` solves it |
|---------|--------------------------|
| Lost updates | The pending set is ordinary stored data in Redis. If the consumer restarts, the set is still there when it comes back — nothing is lost. |
| Churn | A Redis set stores each key only once. A thousand changes to `10.0.0.0/24` still produce one entry in the set, carrying the latest value. The consumer does one unit of work instead of a thousand. |
| Half-written objects | The hand-off — moving fields from staging into the final hash and adding the key to the pending set — runs as a **Lua script inside Redis**. Redis executes Lua scripts atomically, so the object becomes visible all at once or not at all. |
| Locating data | `swsscommon` reads `database_config.json` at startup and resolves the correct database, socket, key separator, and namespace automatically. No daemon hardcodes these details. |

> The full set of communication patterns built on `swsscommon` — and which one to use when — is covered in [IPC Mechanisms](11_ipc_mechanisms.md).

### Clearing Up the Name

Before moving on, it helps to clear up a naming confusion.

**SWSS** stands for **SWitch State Service**. It was the first major SONiC component, and its daemons all needed the same helper code — connect to Redis, wrap a table, listen to Netlink. That shared code was originally just "the common part of SWSS," and when other components wanted it too, it was split into its own repository named `sonic-swss-common`. Its README still describes it as providing "functions needed by SWSS."

That description no longer limits it. Today more than sixty SONiC packages depend on `swsscommon`, including pmon's `xcvrd`, `psud`, and `thermalctld`, the `sonic-utilities` CLI (which runs on the host, not in any container), syncd, telemetry, SNMP, and DHCP. It is simply *the* SONiC database library. A name like `sonic-dbcommon` would fit better, but renaming it would break include paths, package names, and imports across a dozen repositories.

Keep these three apart:

| Name                           | What it is                                           |
|--------------------------------|------------------------------------------------------|
| **SWSS** (the concept)         | The Switch State Service — the architectural role of carrying state toward the ASIC |
| **`swss`** (the container)     | One running container — and note it is built from the image `docker-orchagent`, so even the container and image names disagree |
| **`swsscommon`** (the library) | A general-purpose database library used by nearly every SONiC component |

---

**Previous**: [← Core Redis Databases](09_redis_databases.md) · **Next**: [IPC Mechanisms →](11_ipc_mechanisms.md)
