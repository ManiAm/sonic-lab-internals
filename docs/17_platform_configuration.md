# SONiC Platform Configuration

> **Prerequisites**: [The PMON Container](16_pmon_container.md) (the Platform API and vendor plugins that consume these files) and [Core Redis Databases](08_redis_databases.md) (CONFIG_DB as the runtime source of truth).

SONiC runs on hundreds of switch models from many vendors. To keep the OS code hardware-independent, every platform-specific detail — port layouts, sensor mappings, fan policies, firmware metadata — is captured in data files rather than in code. This document explains those files: where they live, what each one does, and how they seed the running configuration at boot.

## The Big Picture

Everything hardware-specific is pushed out of the OS code and into **data files**, organized in a strict three-level hierarchy:

```
device/
└── <vendor>/                                e.g. dell, arista, mellanox, celestica, accton
    └── <platform>/                          one folder per switch model (ONIE platform string)
        ├── platform-level files             chassis: fans, sensors, PSUs, thermals, plugins
        ├── <HwSKU-A>/                       one folder per port layout / role variant
        │   └── port-layout files            ports, lanes, speeds, breakout, buffers, QoS
        └── <HwSKU-B>/
            └── port-layout files
```

- In the source tree (sonic-buildimage) this is the top-level `device/` directory.
- On a running switch the same content is installed under `/usr/share/sonic/device/<platform>/`.

The three levels answer three different questions:

| Level       | Question it answers                                    | Example                       |
|-------------|--------------------------------------------------------|-------------------------------|
| Vendor      | Who makes it?                                          | `device/dell`, `device/arista`, `device/mellanox` |
| Platform    | Which physical box is this?                            | `x86_64-dellemc_z9332f_d1508-r0` |
| HwSKU       | How are its ports laid out, or what role does it play? | `DellEMC-Z9332f-O32` |

## Concrete Example: Celestica Seastone DX010

Here is what the hierarchy looks like for a real platform — the Celestica Seastone DX010, a Broadcom-based switch with 32 physical QSFP28 ports (each capable of up to 100G). Those 32 physical ports can be configured in many ways — all at full speed, some split into multiple lower-speed logical ports, or a mix — giving eight port-layout variants:

```
device/
└── celestica/
    └── x86_64-cel_seastone-r0/
        ├── platform.json, sensors.conf, ...     <- platform-level files (shared by all SKUs)
        ├── Celestica-DX010-C32/                 <- 32 × 100G (all ports at max speed)
        ├── Celestica-DX010-D48C8/               <- 48 × 50G + 8 × 100G
        ├── Seastone-DX010/                      <- 32 × 100G (default SKU)
        ├── Seastone-DX010-10-50/                <- 96 × 10G + 16 × 50G
        ├── Seastone-DX010-25-50/                <- 96 × 25G + 16 × 50G
        ├── Seastone-DX010-50/                   <- 64 × 50G
        ├── Seastone-DX010-50-40/                <- 32 × 50G + 16 × 40G
        └── Seastone-DX010-50-50-40/             <- 48 × 50G + 8 × 40G
```

## The Platform Folder and the ONIE Platform String

Each switch model gets exactly one **platform folder**, named with its **ONIE platform string**:

```
<cpu-arch>-<vendor>_<model>-r<hardware-revision>
```

Real examples:

| Vendor          | Platform string                  |
|-----------------|----------------------------------|
| Dell            | `x86_64-dellemc_z9332f_d1508-r0` |
| Arista          | `x86_64-arista_7060x6_64pe`      |
| NVIDIA/Mellanox | `x86_64-nvidia_sn5610-r0`        |
| Celestica       | `x86_64-cel_silverstone-r0`      |

**Why this exact string matters:** it is not chosen by SONiC — it comes from the hardware. ONIE (the Open Network Install Environment, a small firmware pre-installed on bare-metal switches that handles OS installation and hardware identity) reads the board's EEPROM (a small non-volatile memory chip soldered onto the board that stores hardware identity data) and reports the platform string at install time. SONiC records it in `/host/machine.conf` (`onie_platform=...`) and uses it at every boot to find the matching folder under `/usr/share/sonic/device/`. If the folder name and the EEPROM string don't match exactly, the switch cannot identify itself and services fail to start.

You can always check what a live switch resolved itself to:

```
admin@sonic:~$ show platform summary
Platform: x86_64-cel_seastone-r0
HwSKU: Seastone-DX010
ASIC: broadcom
ASIC Count: 1
Serial Number: DX010F2B031421BY200065
Model Number: R0872-F0019-02
Hardware Revision: N/A
```

And the raw ONIE identity stored at install time:

```
admin@sonic:~$ cat /host/machine.conf
onie_version=2014.08.0.0.7
onie_vendor_id=12244
onie_platform=x86_64-cel_seastone-r0
onie_machine=cel_seastone
onie_machine_rev=0
onie_arch=x86_64
onie_config_version=1
onie_build_date="2018-05-09T10:48-0400"
onie_partition_type=gpt
onie_kernel_version=3.2.35
```

### What Lives at the Platform Level

These files describe the **chassis** — everything about the box that is true regardless of how the ports are configured:

| File | Purpose |
|------|------------------------------------|
| `platform.json` | Capabilities of the chassis: port-to-lane pools and supported breakout modes (ways to split one physical port into multiple logical ports), number of fans/PSUs/thermals, and feature flags (e.g. whether ASIC firmware may be field-upgraded by the OS) |
| `platform_asic` | One-line file naming the ASIC vendor (e.g. `broadcom`, `mellanox`, `barefoot`). SONiC uses this to select the correct syncd variant and SAI library. |
| `default_sku` | Which HwSKU to use when nothing else selects one — e.g. `DellEMC-Z9332f-O32 t1` (SKU name + default role) |
| `sonic_platform-*.whl` | The Platform API package — Python classes that PMON uses to read fans, PSUs, thermals, EEPROM, and transceivers. Built at image time from the vendor's `sonic_platform/` source directory. See [The PMON Container](16_pmon_container.md) for how this package is loaded and used. |
| `plugins/` | Legacy Python plugins for vendor-specific behavior (SFP access, LED control). Newer platforms use the `sonic_platform` wheel instead. |
| `pmon_daemon_control.json` | Which platform-monitor daemons run on this box (some platforms have no PSU daemon, etc.). See [Daemon Control](16_pmon_container.md#daemon-control-enabling-and-disabling-daemons). |
| `thermal_policy.json` | Fan-speed policy: which thermal conditions drive which fan actions |
| `installer.conf` | Boot/console settings consumed at image install (console port, baud rate) |
| `system_health_monitoring_config.json` | What the system-health service (`healthd`) checks/ignores on this platform — polling interval, devices to skip, LED colors. See [System Health Monitoring](18_host_services.md#system-health-monitoring-healthd). |
| `pcie.yaml` | Expected PCIe topology, used by the PCIe health checker. See [pcie-check](18_host_services.md#pcie-check). |
| `sensors.conf` | lm-sensors mapping: names, scaling, and alarm thresholds for voltage/temp sensors |
| `platform_components.json` | Firmware-upgradable components (BIOS, CPLD, FPGA, ONIE) for `fwutil` |

Vendors are free to add extras (firmware bundles, environment configs, custom reboot scripts, porting notes); the files above are the ones that SONiC infrastructure looks for.

> **Porting note:** adding support for a brand-new switch means creating exactly this — a new vendor folder (if the vendor is new) and a new platform folder with these files, sitting alongside the existing vendor trees such as Dell, Arista, and Mellanox.

## The HwSKU Folder — Port Layout

**HwSKU** stands for **Hardware SKU** (Stock Keeping Unit). It identifies a specific **port-layout variant** of a given platform — the same physical switch (same chassis, same ASIC) can be deployed with different port configurations, and each configuration is a different HwSKU. Think of it like retail inventory: the same T-shirt in size Medium / Blue is a different SKU from size Large / Red. Similarly, the same Celestica DX010 box configured as 32×100G is a different HwSKU from the same box configured as 64×50G.

**HwSKU** answers: *given this chassis, how are the ports arranged?*

The same physical box is often sold or deployed in multiple port configurations: all ports at max speed, some ports split into breakouts, a couple of ports reserved for management, different buffer tuning for leaf vs. spine roles — each variant is one HwSKU subfolder (as shown in the [Seastone example above](#concrete-example-celestica-seastone-dx010)).

The active SKU is chosen by (in order): the saved configuration (`DEVICE_METADATA.hwsku` in CONFIG_DB), a minigraph, or the platform's `default_sku` file.

### What Lives at the HwSKU Level

| File                                             | Purpose                             |
|--------------------------------------------------|-------------------------------------|
| `port_config.ini`                                | The classic port table: one row per port with name (`Ethernet0`...), **lanes** (which SerDes lanes form the port), alias (front-panel label like `Et1/1`), index, and default speed. This seeds the PORT table on first boot. |
| `sai.profile`                                    | Tells the SAI/ASIC driver which hardware profile to load |
| ASIC config file                                 | Vendor-specific ASIC view of the ports — Mellanox: `sai_<model>_<layout>.xml`; Broadcom: `*.bcm` / `*.config.yml`; Barefoot: context JSONs. Must agree with `port_config.ini`, or port creation fails in syncd. |
| `buffers.json.j2`, `buffers_defaults_*.j2`       | Buffer pool/profile templates, rendered per port at config load |
| `qos.json.j2`                                    | QoS maps (DSCP/TC/queue) rendered per port |
| `pg_profile_lookup.ini`                          | Priority-group headroom per speed + cable length |
| `hwsku.json`                                     | The default **breakout mode** per port (works together with the platform-level `platform.json` for Dynamic Port Breakout) |
| `media_settings.json`, `optics_si_settings.json` | SerDes signal-integrity presets per optic/cable type. Can live at either the platform level (shared by all SKUs) or the HwSKU level (per-layout overrides); the platform level is more common. |

**The key file for port layout is `port_config.ini`.** A row looks like:

```
# name         lanes                  alias    index    speed
Ethernet0      0,1,2,3,4,5,6,7        Et1/1    1        400000
Ethernet8      8,9,10,11,12,13,14,15  Et2/1    2        400000
```

"Lanes" are the ASIC's SerDes (Serializer/Deserializer) lanes — individual high-speed serial links. A 400G port here consumes 8 lanes; splitting that port 2x200G means two ports with 4 lanes each — which is exactly what breakout mode changes.

## From Files to a Running Switch — Who Reads What, When

The device folder files are **seeds**, not the runtime state. The flow:

```
 EEPROM/ONIE          device folder                     runtime
┌───────────┐   ┌──────────────────────┐   ┌──────────────────────────────┐
│ platform  │──>│ platform folder      │──>│ CONFIG_DB  (PORT table etc.) │
│ string    │   │  └── HwSKU folder    │   │   /etc/sonic/config_db.json  │
└───────────┘   │      port_config.ini │   └──────────────┬───────────────┘
                │      *.json.j2 ...   │                  │ swss/orchagent
                └──────────────────────┘                  v
                     ASIC config  ───────────────> SAI/syncd -> ASIC
                     (sai.profile/XML/bcm)
```

1. **First boot (or config wipe):** `sonic-cfggen` reads the platform string, picks the HwSKU, and renders `port_config.ini` + the `.j2` templates into **CONFIG_DB** (persisted as `/etc/sonic/config_db.json`). See [Configuration Management](19_configuration_management.md) for more on `sonic-cfggen` and CONFIG_DB loading.
2. **Every boot after that:** CONFIG_DB is the source of truth. The seed files are only consulted again if you change SKU, run a config wipe, or use breakout commands.
3. **In parallel**, syncd loads the ASIC config named by `sai.profile`. The ASIC's port map and the PORT table must describe the same layout.

Practical consequence worth remembering: **editing `port_config.ini` on a deployed switch does nothing** until the PORT table is re-generated. To inspect reality, read the runtime:

```
show interfaces status                      # live port state
redis-cli -n 4 keys "PORT|*"                # PORT table keys in CONFIG_DB
redis-cli -n 4 hgetall "PORT|Ethernet0"     # lanes/speed/alias of one port
```

## Changing the Port Layout

There are three ways to change how the ports on a switch are arranged. Each one is suited to a different situation:

- **Switch to a different HwSKU** — Use this when you want a completely different port layout that the vendor has already defined (e.g. switching a box from an all-400G spine layout to a mixed 100G/400G leaf layout). This replaces the *entire* port inventory: you regenerate CONFIG_DB for the target SKU and cold reboot. The full procedure is [detailed below](#switching-hwsku--step-by-step).

- **Dynamic Port Breakout** — Use this when you only need to split or combine a few individual ports without changing anything else (e.g. splitting one 400G port into 4×100G). Run `config interface breakout Ethernet0 "2x200G"` — SONiC reads the allowed modes from `platform.json` and `hwsku.json` and updates the PORT table accordingly.

- **Author a new HwSKU folder** — Use this when the layout you need does not exist yet as a vendor-defined SKU. You create a new subfolder with a new `port_config.ini`, a matching ASIC config, and buffer/QoS templates. This is a porting task done in the source repository (`sonic-buildimage`), not on a live switch.

The right choice depends on scope:

|                 | HwSKU change                             | Dynamic Port Breakout |
|-----------------|------------------------------------------|-----------------------|
| Scope           | Entire port inventory                    | Individual ports      |
| Config impact   | Full regeneration — custom settings lost | In-place; rest of config untouched |
| Reboot required | Yes (cold reboot)                        | No                                 |
| Defined by      | A different SKU folder                   | `platform.json` + `hwsku.json` breakout modes |
| Typical use     | Repurposing a box (leaf → spine), adopting a vendor-defined alternate layout | Splitting one 400G port into 4×100G |

Rule of thumb: if the layout you want already exists as a SKU folder, switch SKU. If you are adjusting a handful of ports within the current layout, use breakout.

### Why You Cannot Just Edit the SKU Field

It is tempting to set `DEVICE_METADATA.hwsku` to the new name and reload. **This will leave the switch broken.** The reason:

- The saved configuration contains a `PORT` table entry for every port — name, lanes, speed, alias — all describing the *old* SKU's layout.
- Changing only the SKU name produces a mismatch: SONiC believes it is running the new SKU, but the port inventory still describes the old one.
- The ASIC configuration selected through the new SKU's `sai.profile` will disagree with the PORT table, and port creation fails inside syncd.

The correct approach is to **regenerate the configuration from scratch** for the target SKU — the same thing SONiC does on a factory first boot.

### Switching HwSKU — Step by Step

> **Impact:** a SKU change is a disruptive maintenance operation. It replaces the entire configuration and requires a reboot. Plan a maintenance window.

> **Scope:** the procedure below covers single-ASIC platforms. On multi-ASIC platforms the startup configuration is split into per-ASIC namespace files (`config_db0.json`, `config_db1.json`, ...), so Steps 0, 2, and 3 must be repeated for each namespace.

**Step 0 — Back up the current configuration**

```
sudo cp /etc/sonic/config_db.json ~/config_db.backup.json
```

The new configuration is generated from factory defaults — **your current settings (IPs, VLANs, routes, users, features) do not carry over**. The backup is your reference for re-applying whatever still applies to the new layout.

**Step 1 — Confirm the target SKU exists**

List the contents of the platform directory (this lists valid HwSKU folders, filtering out supporting directories):

```
PLATFORM=$(sonic-cfggen -H -v DEVICE_METADATA.localhost.platform)
for d in /usr/share/sonic/device/$PLATFORM/*/; do
    [ -f "$d/port_config.ini" ] || [ -f "$d/hwsku.json" ] && basename "$d"
done
```

**Step 2 — Generate a fresh configuration for the target SKU**

```
sudo sonic-cfggen -H -k <target-SKU> --preset <preset> > /tmp/config_db.new.json
```

- `-H` reads the hardware identity (platform) from the running system.
- `-k` names the target SKU.
- `--preset` selects the config template role (e.g. `t1` or `l2`); the platform's `default_sku` file shows the vendor-intended preset.

Sanity-check the output — it should contain a `PORT` entry for every port of the *new* layout:

```
python3 -c "import json; d=json.load(open('/tmp/config_db.new.json')); \
  print(len(d['PORT']), 'ports'); print(d['DEVICE_METADATA']['localhost']['hwsku'])"
```

**Step 3 — Install as the startup configuration**

```
sudo cp /tmp/config_db.new.json /etc/sonic/config_db.json
```

**Step 4 — Cold reboot**

```
sudo reboot
```

A full reboot is required: the ASIC must be re-initialized with the new SKU's hardware profile, and no running component can survive its ports being torn down and re-created.

**Step 5 — Verify**

```
show platform summary            # HwSKU should show the target SKU
show interfaces status           # new port inventory, speeds, lanes
docker ps                        # swss / syncd / pmon all running
```

**Step 6 — Re-apply your configuration**

Using the Step 0 backup as a reference, re-apply what still makes sense on the new layout (management settings, users, features, routing config). Port-level settings usually need rethinking since port names and speeds have changed.

### Pitfalls

| Pitfall                                 | What happens | Avoidance |
|-----------------------------------------|--------------|-----------|
| Editing only `DEVICE_METADATA.hwsku`    | PORT table still describes the old SKU; syncd fails to create ports         | Always regenerate the full config (Step 2) |
| Expecting settings to survive           | The new config is factory-fresh; everything custom is gone                  | Back up first (Step 0), re-apply after (Step 6) |
| Using `config reload` instead of reboot | ASIC may keep the old hardware profile; port creation errors                | Cold reboot (Step 4) |
| Target SKU folder incomplete            | Boot loops or missing ports                                                 | Verify Step 1; the SKU needs both a port inventory and a matching ASIC config |
| Config written to a non-persistent path | On platforms where `config_db.json` is a symlink, `cp` may write to a tmpfs; the switch silently reverts on the next reboot | Run `ls -l /etc/sonic/config_db.json` (Step 3); if it's a symlink, copy to the real target |
| Mismatched cabling expectations         | New layout may renumber or re-lane ports; optics in "removed" ports go dark | Map old → new port names from the two `port_config.ini` files before the window |

## Quick Reference — Where Everything Is

| What                               | Where |
|------------------------------------|-----------------------------|
| All hardware definitions (source)  | `sonic-buildimage/device/<vendor>/` |
| Same, on a running switch          | `/usr/share/sonic/device/<platform>/` |
| Convenience symlinks on the switch | `/usr/share/sonic/platform` and `/usr/share/sonic/hwsku` (point into the active platform/SKU) |
| The box's identity                 | `/host/machine.conf` (`onie_platform=`), `show platform summary` |
| Runtime port config                | CONFIG_DB (`/etc/sonic/config_db.json`, `PORT` table) |
| Platform chassis definition        | `<platform>/platform.json`, `sensors.conf`, `thermal_policy.json`, ... |
| Port layout definition             | `<platform>/<HwSKU>/port_config.ini` (+ `hwsku.json`, ASIC config) |

---

**Previous**: [← The PMON Container](16_pmon_container.md) · **Next**: [Host Services →](18_host_services.md)
