# Configuration Management

> **Prerequisites**: [Core Redis Databases](08_redis_databases.md) (CONFIG_DB purpose) and [The SWSS Container](11_swss_container.md) (manager daemons that consume CONFIG_DB).

This document explains how configuration enters SONiC, how it is stored, validated, and applied to the system.

## CONFIG_DB: The Source of Truth

All user-intended configuration in SONiC lives in CONFIG_DB (Redis database #4). This includes:

- Port settings (speed, MTU, admin state)
- VLAN definitions and memberships
- Interface IP addresses
- BGP neighbors
- ACL rules
- QoS policies
- Platform settings

## config_db.json

CONFIG_DB has a persistent representation on disk: `/etc/sonic/config_db.json`. This JSON file is:

- Loaded at boot to populate CONFIG_DB.
- Written when the user runs `config save`.
- The backup/restore unit for device configuration.

### Structure

```json
{
    "PORT": {
        "Ethernet0": {
            "admin_status": "up",
            "speed": "100000",
            "mtu": "9100",
            "alias": "fortyGigE0/0"
        },
        "Ethernet4": {
            "admin_status": "up",
            "speed": "100000"
        }
    },
    "VLAN": {
        "Vlan100": {
            "vlanid": "100"
        }
    },
    "VLAN_MEMBER": {
        "Vlan100|Ethernet4": {
            "tagging_mode": "untagged"
        }
    },
    "INTERFACE": {
        "Ethernet0|10.0.0.1/31": {}
    }
}
```

The structure is:
```
TABLE_NAME → KEY → { field: value, field: value, ... }
```

In Redis, this maps to:
```
TABLE_NAME|KEY → HASH { field: value, ... }
```

## Ways to Configure SONiC

### 1. CLI (sonic-utilities / Click-based)

The traditional SONiC CLI runs on the host (not in any container). It is built with Python Click.

```bash
admin@sonic:~$ config interface speed Ethernet0 100000
admin@sonic:~$ config vlan add 100
admin@sonic:~$ config vlan member add 100 Ethernet4
```

These commands directly write to CONFIG_DB via the `swsscommon` Python library.

### 2. config_db.json Reload

Load a complete configuration file:

```bash
admin@sonic:~$ sudo config reload
# OR load from a specific file:
admin@sonic:~$ sudo config load /etc/sonic/config_db.json
```

`config reload` restarts all SONiC services after loading.

### 3. sonic-cfggen

A lower-level tool for rendering configuration from templates and loading it:

```bash
# Load a specific table from JSON
sonic-cfggen -j /tmp/my_config.json --write-to-db

# Generate config from a minigraph XML
sonic-cfggen -m /etc/sonic/minigraph.xml --write-to-db
```

### 4. REST API / gNMI

Through the management framework container:

```bash
# REST API example
curl -X PATCH https://switch:8443/restconf/data/openconfig-interfaces:interfaces/interface=Ethernet0/config \
  -d '{"admin-status": "DOWN"}'
```

### 5. Direct Redis Write (Advanced / Testing Only)

```bash
# Not recommended for production
redis-cli -n 4 HSET "PORT|Ethernet0" "admin_status" "down"
```

This bypasses all validation and can leave the system in an inconsistent state.

## Configuration Flow

Regardless of which method is used, the flow is always:

```
User action
    │
    v
CONFIG_DB (written)
    │
    │  (SubscriberStateTable notification)
    v
Manager daemon (portmgrd, intfmgrd, vlanmgrd, etc.)
    │
    ├── Validates the change
    ├── Configures Linux kernel (if needed)
    │
    v
APPL_DB (processed state)
    │
    v
orchagent → ASIC_DB → syncd → hardware
```

## Saving Configuration

Configuration in Redis is volatile (lost on reboot). To persist it:

```bash
# Save current CONFIG_DB to disk
admin@sonic:~$ config save

# This writes to /etc/sonic/config_db.json
```

If you make changes and don't run `config save`, the changes will be lost on next reboot (the system loads from config_db.json at boot).

## config reload vs config apply-patch

| Operation | What It Does | Service Impact |
|-----------|-------------|----------------|
| `config reload` | Loads config_db.json, restarts all services | Traffic disruption |
| `config apply-patch` | Applies incremental JSON patch to CONFIG_DB | Minimal disruption |
| `config save` | Saves current CONFIG_DB to disk | No impact |
| `config load` | Loads from file without restart | Adds/modifies CONFIG_DB entries |

> For detailed coverage of `config reload` internals and all SONiC reboot types (cold, fast, warm), see [Reboot Types and Config Reload](16_reboot_and_reload.md).

## YANG Validation

CONFIG_DB tables have YANG models that define valid structure:

```yang
container PORT {
    list PORT_LIST {
        key "name";
        leaf name { type string; }
        leaf admin_status {
            type enumeration {
                enum up;
                enum down;
            }
        }
        leaf speed { type uint32; }
        leaf mtu { type uint16 { range "68..9216"; } }
    }
}
```

When configuration enters through the management framework (REST/gNMI/KLISH), it is validated against these YANG models **before** being written to CONFIG_DB.

When configuration enters through the old CLI or direct Redis writes, YANG validation may be bypassed — the gate is at the management framework layer, not at CONFIG_DB itself.

## Boot-Time Configuration Loading

At boot:

```
1. database container starts Redis
2. config-setup.service runs:
   - Checks if /etc/sonic/config_db.json exists
   - Loads it into CONFIG_DB (Redis DB #4)
3. Other containers start:
   - Their manager daemons read CONFIG_DB
   - Apply configuration to kernel and APPL_DB
4. orchagent programs everything into hardware
```

If there is no `config_db.json` (fresh install), SONiC starts with a default/empty configuration.

## Key Takeaways

- **CONFIG_DB** (Redis DB #4) is the single source of truth for all user intent.
- Configuration is persisted to `/etc/sonic/config_db.json` — always run `config save` after making changes you want to keep.
- Multiple configuration methods exist (CLI, REST, gNMI, direct Redis), but all ultimately write to CONFIG_DB.
- YANG validation is enforced by the management framework but not by CONFIG_DB itself — direct Redis writes bypass validation.
- Use `config reload` only when you need a full configuration replacement; prefer incremental commands or `config apply-patch` for routine changes.

---

**Previous**: [← The BGP Container and FRR](14_bgp_container.md) · **Next**: [Reboot Types and Config Reload →](16_reboot_and_reload.md)
