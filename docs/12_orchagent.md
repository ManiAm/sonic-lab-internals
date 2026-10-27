# Orchagent Deep Dive

> **Prerequisite**: [The SWSS Container](11_swss_container.md) — understand the three process categories (managers, sync daemons, orchagent) and how they interact.

Orchagent is the most critical and complex process in SONiC. As shown in the [SWSS container diagram](11_swss_container.md#whats-inside-swss), it sits at the convergence point of both manager daemons and sync daemons — consuming intent from APPL_DB, CONFIG_DB, and STATE_DB, resolving cross-feature dependencies, and programming the ASIC by writing to ASIC_DB through the sairedis library.

## How an Orch Works

Orchagent is built from multiple independent modules called **Orchs**. Each Orch handles one specific feature or network object type. Before listing them all, it is important to understand the pattern they share — every Orch follows the same four-step lifecycle.

### 1. Registration

At startup, each Orch registers:
- Which **database** to listen to (APPL_DB, CONFIG_DB, etc.)
- Which **table(s)** to subscribe to
- Which **IPC pattern** to use — [ConsumerStateTable](10_ipc_mechanisms.md#pattern-4-producerstatetable--consumerstatetable-hash-based) for APPL_DB, [SubscriberStateTable](10_ipc_mechanisms.md#pattern-1-subscriberstatetable-key-space-notifications) for CONFIG_DB

```cpp
// Simplified example from orch.cpp
RouteOrch::RouteOrch(DBConnector *db, string tableName)
    : Orch(db, tableName)  // tableName = "ROUTE_TABLE"
{
    // Now subscribed to APPL_DB:ROUTE_TABLE events
}
```

### 2. Consumer Abstraction

The Orch base class wraps each subscribed table into a **Consumer** object. The Consumer handles all Redis interaction details — connecting, subscribing, reading data, and deserializing — so the Orch itself never deals with raw Redis commands.

An Orch that watches a single table has one Consumer. An Orch that watches multiple tables has one Consumer **per table**, all stored in `m_consumerMap` — a `std::map<string, shared_ptr<Executor>>` keyed by table name. For example, IntfsOrch subscribes to both `INTF_TABLE` and `SAG_TABLE`, so its `m_consumerMap` has two entries:

```cpp
// orchdaemon.cpp — IntfsOrch watches two APPL_DB tables
vector<table_name_with_pri_t> intf_tables = {
    { APP_INTF_TABLE_NAME,  IntfsOrch::intfsorch_pri },
    { APP_SAG_TABLE_NAME,   IntfsOrch::intfsorch_pri }
};
gIntfsOrch = new IntfsOrch(m_applDb, intf_tables, vrf_orch, m_chassisAppDb);
```

The Orch base constructor calls `addConsumer()` for each table name. That function inspects the database ID and creates the right IPC type automatically, then inserts the Consumer into `m_consumerMap`.

Every Consumer in the map is also a `Selectable`, which is how OrchDaemon's [main select loop](#the-main-select-loop) knows when any of them has new data. When the loop wakes an Orch, it iterates `m_consumerMap` and calls `doTask()` for each Consumer that has pending entries.

### 3. Task Queue (m_toSync)

When new messages arrive, the Consumer places them in a **task queue** called `m_toSync`. Each entry is a [`KeyOpFieldsValuesTuple`](10_ipc_mechanisms.md#the-common-message-format) — the common message format shared by every IPC consumer in `swsscommon`.

The queue is a `std::multimap<std::string, KeyOpFieldsValuesTuple>`, keyed by the table entry key. A multimap (rather than a plain map) allows multiple operations on the same key to coexist — for example, a `DEL` followed by a `SET` on the same route.

Each tuple contains three fields:

- **Key**: The table entry key (e.g., `10.0.0.0/24` for a route)
- **Operation**: `SET` (create/update) or `DEL` (delete)
- **Field-value pairs**: The attributes (e.g., `nexthop=10.0.0.1, ifname=Ethernet0`)

### 4. doTask() — The Processing Loop

Each Orch implements a `doTask()` method that processes entries from the queue:

```cpp
void RouteOrch::doTask(Consumer &consumer)
{
    auto it = consumer.m_toSync.begin();
    while (it != consumer.m_toSync.end())
    {
        KeyOpFieldsValuesTuple t = it->second;
        string key = kfvKey(t);
        string op = kfvOp(t);
        auto fields = kfvFieldsValues(t);

        if (op == SET_COMMAND)
        {
            if (addRoute(key, fields))
            {
                it = consumer.m_toSync.erase(it);  // Success: remove from queue
            }
            else
            {
                it++;  // Retry later (dependency not met yet)
            }
        }
        else if (op == DEL_COMMAND)
        {
            removeRoute(key);
            it = consumer.m_toSync.erase(it);
        }
    }
}
```

**Key behavior**:
- If processing succeeds → the entry is removed from the queue.
- If processing fails (e.g., a dependency is not ready) → the entry stays in the queue for retry on the next iteration.
- This retry mechanism is how orchagent handles ordering issues — if a route arrives before its next-hop interface exists, the entry remains queued until the dependency is resolved.

## The Main Select Loop

All Orchs are registered in an **ordered list** (`m_orchList`) inside `OrchDaemon`. Orchagent's main function runs a single-threaded event loop that iterates this list on every pass:

```
forever:
    wait for a Redis notification (or 1-second timeout)
    pop the notification data into the correct consumer's m_toSync
    for each Orch in m_orchList (in fixed order):
        orch->doTask()
            for each table in m_consumerMap (alphabetical):
                if this table's m_toSync has entries:
                    process them
```

All Orchs share this single thread — changes are applied sequentially, which avoids race conditions but means ordering matters. Each Orch must complete its `doTask()` quickly to avoid starving the others. The loop blocks until Redis signals that at least one subscribed table has new data, then gives every Orch with pending work a chance to run, in `m_orchList` order.

**The order of `m_orchList` matters.** If Orch A depends on objects created by Orch B, then B must appear before A in the list. For example, `PortsOrch` runs before `IntfsOrch` because you cannot create a router interface on a port that does not exist yet. The full dependency chain for L3 forwarding is:

```
SwitchOrch → PortsOrch → IntfsOrch → NeighOrch → NhgOrch → RouteOrch
```

Each Orch depends on SAI objects created by the ones to its left. If any link is missing, the downstream Orchs queue their work in `m_toSync` and retry on the next iteration (as described in [doTask()](#4-dotask--the-processing-loop) above).


## Worked Example: Two Orchs

Consider two Orchs registered in `m_orchList`. Each subscribes to three CONFIG_DB tables — two unique and one shared:

```
AlphaOrch (m_orchList position 3)
  m_consumerMap:
    "ALPHA_CFG"  → Executor  (SubscriberStateTable on CONFIG_DB:ALPHA_CFG)
    "ALPHA_DATA" → Executor  (SubscriberStateTable on CONFIG_DB:ALPHA_DATA)
    "SHARED_TBL" → Executor  (SubscriberStateTable on CONFIG_DB:SHARED_TBL)

BetaOrch (m_orchList position 5)
  m_consumerMap:
    "BETA_CFG"   → Executor  (SubscriberStateTable on CONFIG_DB:BETA_CFG)
    "BETA_DATA"  → Executor  (SubscriberStateTable on CONFIG_DB:BETA_DATA)
    "SHARED_TBL" → Executor  (SubscriberStateTable on CONFIG_DB:SHARED_TBL)
```

Six Executor objects in total — one per table per orch. Note that `SHARED_TBL` appears in **both** maps: each orch has its own independent Executor for the same Redis table. At startup, OrchDaemon collects all six into its `Select` object:

```cpp
for (Orch *o : m_orchList)
    m_select->addSelectables(o->getSelectables());
```

`getSelectables()` iterates `m_consumerMap` — a `std::map` sorted alphabetically by table name. So executors are added in `m_orchList` order first, then alphabetically within each orch:

```
1. AlphaOrch → ALPHA_CFG, ALPHA_DATA, SHARED_TBL
2. BetaOrch  → BETA_CFG,  BETA_DATA,  SHARED_TBL
```

This order matters. Each executor's creation timestamp determines its initial position in the `Select` priority queue. When multiple executors have data at the same time, `Select` picks the one with the **oldest timestamp** first — which means executors from earlier orchs (and earlier alphabetically within the same orch) are processed first.

The main loop then runs:

```cpp
while (true)
{
    Selectable *s;
    m_select->select(&s, SELECT_TIMEOUT);   // blocks until one executor has data

    auto *c = (Executor *)s;
    c->execute();                            // pop Redis data → m_toSync

    for (Orch *o : m_orchList)               // sweep every orch
        o->doTask();                         // process any consumer with pending entries
}
```

`select()` blocks until at least one executor has new data, then returns **one** executor per call. After popping that executor's data into `m_toSync`, the loop sweeps **every** Orch in `m_orchList` order — giving all consumers with pending entries a chance to run.

> **Takeaway**: `select()` returns one executor per loop iteration. When multiple executors are ready, it picks the one with the oldest timestamp — which follows `m_orchList` order first, then alphabetical table-name order within the same orch.

Four scenarios illustrate how this works in practice:

| # | Scenario | What happens |
|---|----------|-------------|
| 1 | [Unique table](#scenario-1--a-unique-table-changes) | One executor fires, one orch processes, the other skips |
| 2 | [Shared table](#scenario-2--the-shared-table-changes) | Both orchs' executors fire independently, processed one per iteration |
| 3 | [Two tables, same orch](#scenario-3--two-tables-in-the-same-orch-change-at-the-same-time) | Each table gets its own iteration, ordered by timestamp |
| 4 | [Processing fails](#scenario-4--processing-fails-and-the-entry-stays-in-m_tosync) | Failed entry stays in `m_toSync`, retried on the next event |

### Scenario 1 — A unique table changes

An operator modifies `ALPHA_CFG` in CONFIG_DB. Only AlphaOrch subscribes to this table, so only one executor wakes up:

```
ALPHA_CFG changes in CONFIG_DB
       │
       ▼
select() returns AlphaOrch's ALPHA_CFG executor
       │
       ▼
c->execute()  → pops data into AlphaOrch's m_toSync["ALPHA_CFG"]
       │
       ▼
for (Orch *o : m_orchList):
  AlphaOrch->doTask()
    ├── "ALPHA_CFG"  → has data → PROCESS ✓
    ├── "ALPHA_DATA" → empty    → skip
    └── "SHARED_TBL" → empty    → skip
  BetaOrch->doTask()
    ├── "BETA_CFG"   → empty    → skip
    ├── "BETA_DATA"  → empty    → skip
    └── "SHARED_TBL" → empty    → skip
```

One executor, one loop iteration, done. BetaOrch runs its sweep but has nothing to do.

### Scenario 2 — The shared table changes

An operator modifies `SHARED_TBL`. Both orchs subscribe to it, so **both** executors receive the Redis key-space notification independently:

```
SHARED_TBL changes in CONFIG_DB
       │
       │  Redis publishes a key-space notification.
       │  Both AlphaOrch's and BetaOrch's SHARED_TBL executors
       │  receive it — they are independent SubscriberStateTables
       │  on the same Redis channel.
       │
       ▼
╔═══════════════════════════════════════════════════════════════╗
║ Iteration 1                                                   ║
╚═══════════════════════════════════════════════════════════════╝
select() returns AlphaOrch's SHARED_TBL executor (older timestamp)
       │
       ▼
c->execute()  → pops data into AlphaOrch's m_toSync["SHARED_TBL"]
       │
       ▼
for (Orch *o : m_orchList):
  AlphaOrch->doTask()
    ├── "ALPHA_CFG"  → empty    → skip
    ├── "ALPHA_DATA" → empty    → skip
    └── "SHARED_TBL" → has data → PROCESS ✓
  BetaOrch->doTask()
    ├── "BETA_CFG"   → empty    → skip
    ├── "BETA_DATA"  → empty    → skip
    └── "SHARED_TBL" → empty    → skip          ← not yet popped

╔═══════════════════════════════════════════════════════════════╗
║ Iteration 2                                                   ║
╚═══════════════════════════════════════════════════════════════╝
select() returns immediately — BetaOrch's SHARED_TBL executor
is still pending
       │
       ▼
c->execute()  → pops data into BetaOrch's m_toSync["SHARED_TBL"]
       │
       ▼
for (Orch *o : m_orchList):
  AlphaOrch->doTask()
    └── all empty → skip
  BetaOrch->doTask()
    ├── "BETA_CFG"   → empty    → skip
    ├── "BETA_DATA"  → empty    → skip
    └── "SHARED_TBL" → has data → PROCESS ✓
```

`select()` returns one executor per iteration. Since both executors received the notification, the loop runs twice — once for each. The two orchs process the shared data independently; they never see each other's `m_toSync`.

### Scenario 3 — Two tables in the same orch change at the same time

Assume both `ALPHA_CFG` and `ALPHA_DATA` have data waiting at the same time. Each executor is popped in its own loop iteration:

```
ALPHA_CFG and ALPHA_DATA both have data

╔═══════════════════════════════════════════════════════════════╗
║ Iteration 1                                                   ║
╚═══════════════════════════════════════════════════════════════╝
select() returns AlphaOrch's ALPHA_CFG executor
       │
       ▼
c->execute()  → pops ALPHA_CFG data into m_toSync["ALPHA_CFG"]
       │
       ▼
AlphaOrch->doTask()
  ├── "ALPHA_CFG"  → has data → PROCESS ✓
  ├── "ALPHA_DATA" → empty    → skip
  └── "SHARED_TBL" → empty    → skip

╔═══════════════════════════════════════════════════════════════╗
║ Iteration 2                                                   ║
╚═══════════════════════════════════════════════════════════════╝
select() returns AlphaOrch's ALPHA_DATA executor
       │
       ▼
c->execute()  → pops ALPHA_DATA data into m_toSync["ALPHA_DATA"]
       │
       ▼
AlphaOrch->doTask()
  ├── "ALPHA_CFG"  → empty    → skip
  ├── "ALPHA_DATA" → has data → PROCESS ✓
  └── "SHARED_TBL" → empty    → skip
```

Each table is popped and fully processed in its own iteration. The processing order follows the `select()` rules described in the [setup](#worked-example-two-orchs): earliest timestamp first.

### Scenario 4 — Processing fails and the entry stays in m_toSync

AlphaOrch processes an `ALPHA_CFG` entry, but it depends on a SAI object that does not exist yet (e.g., a RIF that another orch has not created). The Orch's `doTask(Consumer&)` skips the entry — it stays in `m_toSync` for retry:

```
ALPHA_CFG changes in CONFIG_DB

╔═══════════════════════════════════════════════════════════════╗
║ Iteration 1                                                   ║
╚═══════════════════════════════════════════════════════════════╝
select() returns AlphaOrch's ALPHA_CFG executor
       │
       ▼
c->execute()  → pops data into AlphaOrch's m_toSync["ALPHA_CFG"]
       │
       ▼
for (Orch *o : m_orchList):
  AlphaOrch->doTask()
    ├── "ALPHA_CFG"  → has data → FAILS (dependency missing) → stays in m_toSync
    ├── "ALPHA_DATA" → empty          → skip
    └── "SHARED_TBL" → empty          → skip
  BetaOrch->doTask()
    ├── "BETA_CFG"   → empty          → skip
    ├── "BETA_DATA"  → empty          → skip
    └── "SHARED_TBL" → empty          → skip
```

The entry is now stuck in `m_toSync["ALPHA_CFG"]`. What triggers the next retry?

**Not timeout.** When `select()` times out (after 1 second with no events), the main loop calls `flush()` to push any buffered SAI operations to ASIC_DB — but it does **not** call `doTask()`. Retries are not timer-driven.

**Any new event.** The for-loop sweep runs after **every** `execute()` call, regardless of which executor fired. So when *any* executor in the entire system receives new data — even an unrelated table in BetaOrch — the sweep calls `doTask()` on all orchs, and AlphaOrch's stuck entry gets another chance:

```
Some time later, BETA_CFG changes in CONFIG_DB

╔═══════════════════════════════════════════════════════════════╗
║ Iteration 2                                                   ║
╚═══════════════════════════════════════════════════════════════╝
select() returns BetaOrch's BETA_CFG executor
       │
       ▼
c->execute()  → pops data into BetaOrch's m_toSync["BETA_CFG"]
       │
       ▼
for (Orch *o : m_orchList):          ← sweeps ALL orchs
  AlphaOrch->doTask()
    ├── "ALPHA_CFG"  → has data (retry) → dependency now exists → PROCESS ✓
    ├── "ALPHA_DATA" → empty → skip
    └── "SHARED_TBL" → empty → skip
  BetaOrch->doTask()
    ├── "BETA_CFG"   → has data → PROCESS ✓
    ├── "BETA_DATA"  → empty → skip
    └── "SHARED_TBL" → empty → skip
```

The retry succeeds because the dependency (e.g., the RIF) was created by a different orch in an earlier iteration. The for-loop sweep after every `execute()` is the retry mechanism — it gives **every** orch with pending `m_toSync` entries a chance to run, even if the current event had nothing to do with them.

## SAI Interaction

When an Orch's `doTask()` needs to program the hardware, it calls SAI APIs:

```cpp
// Inside RouteOrch::addRoute()
sai_route_entry_t route_entry;
route_entry.destination = prefix;  // e.g., 10.0.0.0/24

sai_attribute_t attr;
attr.id = SAI_ROUTE_ENTRY_ATTR_NEXT_HOP_ID;
attr.value.oid = next_hop_oid;

sai_status_t status = sai_route_api->create_route_entry(&route_entry, 1, &attr);
```

These calls do not reach the ASIC directly. The **sairedis** library serializes each SAI call into a Redis entry in ASIC_DB. The syncd process in the SYNCD container reads those entries and executes the actual vendor SDK calls against the hardware.

> For the full details on sairedis serialization, syncd processing, and error handling, see [SAI and the Syncd Container](14_sai_and_syncd.md).

## Batch Processing and EntityBulker

The individual SAI call shown above works correctly for a single route, but it becomes a bottleneck when thousands of routes arrive at once — after a BGP session comes up or a reboot. Calling `create_route_entry()` one at a time means each route incurs the full cost of sairedis serialization, ASIC_DB write, syncd processing, and hardware programming before the next route begins. At scale, this per-route overhead dominates total convergence time.

Orchagent addresses this with two layers of batching: a **pop batch** that controls how many entries it reads from APPL_DB in one pass, and an **EntityBulker** that collects the resulting SAI operations and issues them as bulk hardware calls.

### The Pop Batch (`-b` Flag)

When the main select loop wakes orchagent, each Orch's Consumer calls `pops()` to drain pending entries from its APPL_DB queue. The `-b` flag (passed on the orchagent command line) sets the maximum number of entries drained per call. The default in SONiC is **1,024**:

```text
/usr/bin/orchagent -d /var/log/swss -b 1024 -s
```

This means `RouteOrch::doTask()` receives up to 1,024 routes in a single invocation. Without this flag, the consumer would drain entries one at a time (or at the `DEFAULT_POP_BATCH_SIZE` of 128 defined in [ConsumerStateTable](10_ipc_mechanisms.md#pattern-4-producerstatetable--consumerstatetable-hash-based)).

### EntityBulker — Deferring SAI Calls

Inside `doTask()`, orchagent does not call SAI immediately for each route. Instead, it collects the operations into an **EntityBulker** — a template class in the sairedis library that buffers SAI create, set, and remove operations until the batch is complete.

The flow within a single `doTask()` invocation:

1. **Iterate**: `RouteOrch::doTask()` loops through all 1,024 entries, calling `addRoute()` for each.

2. **Defer**: Each `addRoute()` does not call `sai_route_api->create_route_entry()` directly. Instead, it pushes the operation into the `EntityBulker<sai_route_api_t>` buffer.

3. **Flush**: After the loop completes, `EntityBulker::flush()` fires. It issues **bulk SAI calls** — `sai_bulk_create_route_entry()` — which sairedis serializes into `BULK_CREATE` entries on ASIC_DB. Syncd then executes these as a single vendor SDK call against the ASIC.

This deferred-flush pattern means 1,024 routes produce a small number of bulk hardware calls instead of 1,024 individual ones. The reduction in per-route overhead is substantial: each bulk call amortizes the syncd processing, ASIC table lookup, and sync-mode acknowledgment across hundreds of routes.

### The SAI Bulk Size (`-k` Flag)

`-k` sets the maximum number of entries in one SAI bulk call (`gMaxBulkSize`). When the flag is omitted, the default is **1,000**. EntityBulker uses that value when `flush()` splits the buffered operations into `sai_bulk_*` calls.

`-b` and `-k` are both orchagent command-line options, and they control different layers:

- **`-b`** — how many APPL_DB entries one `doTask()` drains.
- **`-k`** — how many of those entries go into one SAI bulk call.

A stock SONiC start passes `-b 1024` and omits `-k`, so a full pop of 1,024 routes flushes as two bulk calls:

- One bulk of **1,000** routes
- One bulk of the remaining **24** routes

Raising `-b` above the current `-k` does not enlarge each SAI call. It produces more of them per `doTask()`. Raising `-k` (for example `-k 65536`) raises the cap, up to whatever limit the vendor SAI accepts.

## The Notification Thread

Orchagent has a **dedicated notification thread** (separate from the main select loop) that handles asynchronous notifications from syncd:

| Event              | Description |
|--------------------|-------------|
| Port state change  | Link up/down from the optical/PHY layer |
| FDB event          | MAC address learned or aged out |
| Queue PFC deadlock | PFC watchdog detection |
| BFD session state  | BFD up/down transition |

These arrive via [NotificationConsumer](10_ipc_mechanisms.md#pattern-2-notificationconsumer--notificationproducer) and are processed in a separate thread to avoid blocking the main orchestration loop.

```
orchagent notification thread consumes the event
    ^
    │
NotificationProducer → publishes to ASIC_DB notification channel
    ^
    │
syncd notification handler
    ^
    │
Vendor SDK fires callback into syncd
    ^
    │
ASIC detects event (e.g., link down)
```

## CRM — Critical Resource Monitoring

CRM is SONiC's built-in system for tracking **ASIC table usage** — how many entries of each resource type are currently occupied and how many remain available. It is not a Linux kernel feature and not an ASIC-vendor feature; it is a SONiC-layer abstraction implemented as `CrmOrch`, a module inside orchagent.

### How CrmOrch Differs from Other Orchs

Most Orchs are **event-driven**: they wake when data arrives in their subscribed table, process the entries, and go idle. CrmOrch is **timer-driven**: it wakes on a configurable polling interval (default **300 seconds**), queries the ASIC for current resource usage, and publishes the results — regardless of whether any configuration changed. It does subscribe to the CONFIG_DB `CRM` table for threshold and interval settings, but its primary work runs on a timer, not on database events.

### The Data Flow

```text
CONFIG_DB                                     COUNTERS_DB
  CRM table               ┌──────────┐         CRM:STATS keys
  (polling interval,  ──► │ CrmOrch  │ ──►     (used / available
   threshold config)      │ (timer)  │          per resource type)
                          └────┬─────┘
                               │
                               ▼
                           SAI API
                     sai_object_type_
                     get_availability()
```

1. **Configuration.** An operator sets the polling interval and optional thresholds in CONFIG_DB — for example, `sudo crm config polling interval 1` changes the timer from 300 s to 1 s. CrmOrch reads these values on startup and updates them whenever the CONFIG_DB `CRM` table changes.

2. **Polling — two counters, two sources.** The two columns in CRM output come from different places:

    - **Available count** — read from the ASIC via standard SAI switch attributes (e.g., `SAI_SWITCH_ATTR_AVAILABLE_IPV4_ROUTE_ENTRY`). Every vendor SAI must implement these; the vendor library queries actual hardware table occupancy. These are lightweight, read-only queries that do not interfere with forwarding.

    - **Used count** — tracked in software by orchagent. Each Orch increments CRM's internal counter when it creates a SAI object and decrements it on removal. SAI defines `AVAILABLE` attributes but not `USED` attributes, because some ASIC-internal entries (default routes, SDK-created adjacencies) would skew the count. Software tracking keeps it consistent with what orchagent actually programmed.

    In practice, `used + available ≈ total capacity` (e.g., `37 + 147,419 = 147,456` IPv4 route entries on the DX010), but exact equality is not guaranteed since the two numbers come from different sources.

3. **Publishing.** CrmOrch writes both counters to COUNTERS_DB under `CRM:STATS` keys. The `crm` CLI tool (a Python script in the `sonic-utilities` package) reads these keys and formats the output:

    ```text
    admin@sonic:~$ crm show resources all

    Resource Name           Used Count    Available Count
    --------------------  ------------  -----------------
    ipv4_route                      37             147419
    ipv6_route                       3              16381
    ipv4_nexthop                     1              32765
    ipv6_nexthop                     0              32765
    ipv4_neighbor                    1               8191
    ipv6_neighbor                    0               4095
    nexthop_group_member             0              16384
    nexthop_group                    0                256
    fdb_entry                        0               8191
    ipmc_entry                       0               4096
    snat_entry                       0               1024
    dnat_entry                       0               1024
    ```

4. **Threshold alerts.** CRM can raise syslog warnings when a resource crosses a configured threshold. Thresholds can be defined as a percentage, an absolute used count, or an absolute free count, each with low and high watermarks. This is how operators detect that an ASIC table is approaching capacity before routes or neighbors start being silently dropped.

### What CRM Tracks

CRM monitors every major ASIC table type. The exact set of supported resources depends on the vendor SAI implementation — not every ASIC exposes every counter.

| Resource category | Examples |
|-------------------|------------------|
| Forwarding tables | IPv4 routes, IPv6 routes |
| Adjacencies       | IPv4 neighbors, IPv6 neighbors |
| Next-hop groups   | ECMP groups and their members |
| ACL resources     | ACL tables, ACL entries, ACL counters |
| L2 tables         | FDB (MAC address) entries |
| Multicast         | IPMC entries |
| NAT               | SNAT entries, DNAT entries |

### Why CRM Matters

CRM answers a question that no other SONiC component does: **how full is the ASIC?** The software databases (APPL_DB, ASIC_DB) track *intent* — what should be programmed. CRM tracks *reality* — what the hardware actually holds. This distinction makes it essential for three purposes:

- **Capacity planning** — detecting when you are approaching table limits before entries start being dropped.

- **Benchmarking** — the [BGP route-download benchmark](../benchmark/README.md) uses CRM's IPv4 route counter as the hardware-verified measurement source, polling it twice per second to track programming progress in real time.

- **Troubleshooting** — confirming that routes visible in software databases are actually present in hardware.

---

**Previous**: [← The SWSS Container](11_swss_container.md) · **Next**: [The Orch Catalog →](13_orch_catalog.md)
