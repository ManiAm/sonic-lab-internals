# Troubleshooting SONiC

> **Prerequisites**: This is a reference document that assumes familiarity with SONiC's architecture. At minimum, read [Architecture Overview](02_architecture_overview.md), [Core Redis Databases](08_redis_databases.md), and [State Interactions](18_state_interactions.md) first.

This document provides practical debugging techniques for common SONiC issues, organized by symptom.

## General Debugging Approach

SONiC's database-centric architecture means you can observe the system state at every stage of the pipeline:

```
CONFIG_DB → APPL_DB → ASIC_DB → Hardware
                                    │
                              COUNTERS_DB, STATE_DB
```

The debugging strategy is: **start at the symptom and trace backwards through the pipeline** until you find where things diverge from the expected state.

## Essential Commands

### System Health

```bash
# Check all container status
docker ps -a

# Check systemd service status
sudo systemctl status swss bgp syncd database

# Check if any service is in failed state
sudo systemctl --failed

# Show overall system readiness
show system-health summary
```

### Logs

```bash
# Real-time syslog
tail -f /var/log/syslog

# Container-specific logs
docker logs swss
docker logs syncd
docker logs bgp

# Search for errors
grep -i "error\|fail\|abort" /var/log/syslog | tail -50
```

### Redis Database Inspection

```bash
# List all keys in a database
sonic-db-cli CONFIG_DB keys '*'
sonic-db-cli APPL_DB keys '*PORT*'

# Get a specific entry
sonic-db-cli CONFIG_DB hgetall 'PORT|Ethernet0'
sonic-db-cli APPL_DB hgetall 'ROUTE_TABLE:10.0.0.0/24'

# Check for pending (unprocessed) entries
sonic-db-cli APPL_DB keys '_*'
sonic-db-cli ASIC_DB keys '_*'
```

## Problem: Container Keeps Restarting

### Symptoms
- `docker ps` shows a container with short uptime or in "Restarting" state.
- Syslog shows repeated start/stop messages.

### Diagnosis

```bash
# 1. Check container logs
docker logs <container_name>

# 2. Check systemd restart count
systemctl show swss.service | grep -i restart

# 3. Check if restart limit is hit
systemctl status swss.service
# Look for: "start request repeated too quickly"

# 4. Check for core dumps
ls /var/core/

# 5. Check what critical process died (inside the container)
docker exec -it <container> cat /var/log/supervisor/supervisord.log
```

### Common Causes

| Cause | Solution |
|-------|----------|
| Critical process crash (segfault) | Check core dump, file a bug |
| Redis unreachable | Verify database container is running |
| Configuration error | Check syslog for config parsing errors |
| Resource exhaustion (OOM) | Check `dmesg` for OOM killer messages |
| Dependency not met | Check service dependencies with `systemctl list-dependencies` |

### Recovery

```bash
# Reset failed state and restart
sudo systemctl reset-failed <service>
sudo systemctl restart <service>

# Nuclear option: restart all SONiC services
sudo systemctl restart sonic.target
```

## Problem: Interface Not Coming Up

### Diagnosis Checklist

```bash
# 1. Check physical/admin state
show interface status Ethernet0
show interface counters Ethernet0

# 2. Check CONFIG_DB intent
sonic-db-cli CONFIG_DB hgetall 'PORT|Ethernet0'
# admin_status should be "up"

# 3. Check STATE_DB initialization
sonic-db-cli STATE_DB hgetall 'PORT_TABLE|Ethernet0'
# Should show "state": "ok"

# 4. Check APPL_DB
sonic-db-cli APPL_DB hgetall 'PORT_TABLE:Ethernet0'

# 5. Check ASIC_DB
sonic-db-cli ASIC_DB keys '*PORT*' | head

# 6. Check kernel state
ip link show Ethernet0

# 7. Check syncd/SAI for errors
grep -i "Ethernet0\|port" /var/log/syslog | grep -i "error\|fail"

# 8. Check transceiver (if SFP/QSFP)
show interface transceiver presence
show interface transceiver info Ethernet0
```

### Common Causes

| Layer | Issue | Fix |
|-------|-------|-----|
| Physical | No transceiver / bad cable | Check `show interface transceiver presence` |
| Config | admin_status = down | `config interface startup Ethernet0` |
| State | Port not initialized | Check STATE_DB, may need container restart |
| ASIC | SAI error during port create | Check syncd logs |
| Kernel | Interface not created | Check portsyncd logs |

## Problem: Routes Not Being Programmed

### Diagnosis

```bash
# 1. Verify route is in FRR
vtysh -c "show ip route 10.1.0.0/24"

# 2. Check if route reached APPL_DB
sonic-db-cli APPL_DB hgetall 'ROUTE_TABLE:10.1.0.0/24'

# 3. Check for pending entries (orchagent not processing)
sonic-db-cli APPL_DB keys '_ROUTE*'

# 4. Check ASIC_DB for the route
sonic-db-cli ASIC_DB keys '*ROUTE*10.1.0.0*'

# 5. Check orchagent logs for errors
grep "orchagent\|RouteOrch" /var/log/syslog | grep -i "error\|fail\|retry"

# 6. Verify the next-hop exists
sonic-db-cli APPL_DB hgetall 'NEIGH_TABLE:Ethernet0:10.0.0.1'
```

### Common Causes

| Symptom | Likely Cause |
|---------|-------------|
| Route in FRR but not in APPL_DB | fpmsyncd not running or FPM connection broken |
| Route in APPL_DB but not in ASIC_DB | orchagent: next-hop not resolved, or SAI error |
| `_ROUTE_TABLE` entries exist | orchagent is stuck/overloaded |
| Route in ASIC_DB but not forwarding | syncd error or ASIC table full |

## Problem: Orchagent "task_timeout" Messages

### Symptom

Syslog shows:
```
orchagent: :- doTask: task_timeout: PORT_TABLE
```

### What It Means

Orchagent has entries in its task queue (`m_toSync`) that it cannot process — likely because a dependency is not met. After a timeout period, it logs this warning.

### Diagnosis

```bash
# Check for pending entries
sonic-db-cli APPL_DB keys '_*'

# Check orchagent's view of pending items
grep "doTask\|task_timeout\|retry" /var/log/syslog | tail -20
```

### Common Causes

- A port referenced in configuration hasn't been initialized yet (missing STATE_DB entry).
- A next-hop referenced by a route doesn't exist (ARP not resolved).
- A VLAN member references a port that is in another state.

## Problem: Configuration Not Taking Effect

### Diagnosis

```bash
# 1. Verify CONFIG_DB has the expected value
sonic-db-cli CONFIG_DB hgetall 'PORT|Ethernet0'

# 2. Check the appropriate manager daemon is running
docker exec swss ps aux | grep mgrd

# 3. Check manager daemon logs
grep "portmgrd\|intfmgrd\|vlanmgrd" /var/log/syslog | tail -20

# 4. Check if APPL_DB was updated
sonic-db-cli APPL_DB hgetall 'PORT_TABLE:Ethernet0'
```

If CONFIG_DB has the value but APPL_DB doesn't, the manager daemon either:
- Didn't receive the notification (check if it's running).
- Received it but validation failed (check syslog for errors).
- Is waiting for a dependency in STATE_DB.

## Useful Debugging Tools

| Tool | Purpose |
|------|---------|
| `show techsupport` | Collect all logs and state (for bug reports) |
| `sonic-db-cli` | Query any Redis database |
| `redis-cli -n <db_id>` | Direct Redis access |
| `vtysh` | FRR CLI (check routing state) |
| `ip link` / `ip route` / `ip neigh` | Kernel networking state |
| `docker exec -it <container> bash` | Enter a container |
| `supervisorctl -s unix:///var/run/supervisor.sock status` | Check process status inside container |

---

**Previous**: [← State Interactions](18_state_interactions.md)
