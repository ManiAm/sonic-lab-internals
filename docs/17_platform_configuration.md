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

Here is what that looks like for a real platform — the Celestica Seastone DX010, a Broadcom-based switch with 32 physical QSFP28 ports (each capable of up to 100G). Those 32 physical ports can be configured in many ways — all at full speed, some split into multiple lower-speed logical ports, or a mix — giving eight port-layout variants:

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

**Why this exact string matters:** it is not chosen by SONiC — it comes from the hardware. ONIE (the Open Network Install Environment, a small bootloader shipped on bare-metal switches) reads the board's EEPROM (a small non-volatile memory chip soldered onto the board that stores hardware identity data) and reports the platform string at install time. SONiC records it in `/host/machine.conf` (`onie_platform=...`) and uses it at every boot to find the matching folder under `/usr/share/sonic/device/`. If the folder name and the EEPROM string don't match exactly, the switch cannot identify itself and services fail to start.

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

| File                       | Purpose |
|----------------------------|------------------------------------|
| `platform.json`            | Capabilities of the chassis: port-to-lane pools and supported breakout modes (ways to split one physical port into multiple logical ports), number of fans/PSUs/thermals, and feature flags (e.g. whether ASIC firmware may be field-upgraded by the OS) |
| `platform_components.json` | Firmware-upgradable components (BIOS, CPLD, FPGA, ONIE) for `fwutil` |
| `pmon_daemon_control.json` | Which platform-monitor daemons run on this box (some platforms have no PSU daemon, etc.) |
| `sensors.conf`             | lm-sensors mapping: names, scaling, and alarm thresholds for voltage/temp sensors |
| `thermal_policy.json`      | Fan-speed policy: which thermal conditions drive which fan actions |
| `pcie.yaml`                | Expected PCIe topology, used by the PCIe health checker |
| `system_health_monitoring_config.json` | What the system-health service checks/ignores on this platform |
| `default_sku`              | Which HwSKU to use when nothing else selects one — e.g. `DellEMC-Z9332f-O32 t1` (SKU name + default role) |
| `installer.conf`           | Boot/console settings consumed at image install (console port, baud rate) |
| `plugins/`                 | Legacy Python plugins for vendor-specific behavior (SFP access, LED control). Newer platforms use the `sonic_platform` wheel instead. |
| `sonic_platform-*.whl`     | The Platform API package — Python classes that PMON uses to read fans, PSUs, thermals, EEPROM, and transceivers. See [The PMON Container](16_pmon_container.md) for how this package is loaded and used. |

Vendors are free to add extras (firmware bundles, product specs, porting notes); the files above are the common core that SONiC infrastructure looks for.

> **Porting note:** adding support for a brand-new switch means creating exactly this — a new vendor folder (if the vendor is new) and a new platform folder with these files, sitting alongside the existing vendor trees such as Dell, Arista, and Mellanox.

## The HwSKU Folder — Port Layout

**HwSKU** stands for **Hardware SKU**, where SKU (Stock Keeping Unit) is a term borrowed from retail and inventory management. In a store, a SKU identifies a specific product variant — the same T-shirt in size Medium and color Blue is a different SKU from size Large in Red. SONiC borrows this idea: the same physical switch (same chassis, same ASIC) can be deployed with different port configurations, and each configuration is a different HwSKU.

**HwSKU** answers: *given this chassis, how are the ports arranged?*

The same physical box is often sold or deployed in multiple port configurations: all ports at max speed, some ports split into breakouts, a couple of ports reserved for management, different buffer tuning for leaf vs. spine roles — each variant is one HwSKU subfolder (as shown in the [Seastone example above](#the-big-picture)).

The active SKU is chosen by (in order): the saved configuration (`DEVICE_METADATA.hwsku` in CONFIG_DB), a minigraph, or the platform's `default_sku` file.

### What Lives at the HwSKU Level

| File | Purpose |
|---|---|
| `port_config.ini` | The classic port table: one row per port with name (`Ethernet0`...), **lanes** (which SerDes lanes form the port), alias (front-panel label like `Et1/1`), index, and default speed. This seeds the PORT table on first boot. |
| `hwsku.json` | The default **breakout mode** per port (works together with the platform-level `platform.json` for Dynamic Port Breakout) |
| `supported_breakout.json` (if present) | Which split modes each port supports on this SKU |
| `sai.profile` | Tells the SAI/ASIC driver which hardware profile to load |
| ASIC config file | Vendor-specific ASIC view of the ports — Mellanox: `sai_<model>_<layout>.xml`; Broadcom: `config.bcm` / `.config.yml`; Barefoot: context JSONs. Must agree with `port_config.ini`, or port creation fails in syncd. |
| `buffers.json.j2`, `buffers_defaults_*.j2` | Buffer pool/profile templates, rendered per port at config load |
| `qos.json.j2` | QoS maps (DSCP/TC/queue) rendered per port |
| `pg_profile_lookup.ini` | Priority-group headroom per speed + cable length |
| `media_settings.json`, `optics_si_settings.json` | SerDes signal-integrity presets per optic/cable type |

**The key file for port layout is `port_config.ini`.** A row looks like:

```
# name         lanes              alias    index    speed
Ethernet0      0,1,2,3,4,5,6,7    Et1/1    1        400000
Ethernet8      8,9,10,11,12,13,14,15  Et2/1    2    400000
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

1. **First boot (or config wipe):** `sonic-cfggen` reads the platform string, picks the HwSKU, and renders `port_config.ini` + the `.j2` templates into **CONFIG_DB** (persisted as `/etc/sonic/config_db.json`). See [Configuration Management](18_configuration_management.md) for more on `sonic-cfggen` and CONFIG_DB loading.
2. **Every boot after that:** CONFIG_DB is the source of truth. The seed files are only consulted again if you change SKU, run a config wipe, or use breakout commands.
3. **In parallel**, syncd loads the ASIC config named by `sai.profile`. The ASIC's port map and the PORT table must describe the same layout.

Practical consequence worth remembering: **editing `port_config.ini` on a deployed switch does nothing** until the PORT table is re-generated. To inspect reality, read the runtime:

```
show interfaces status                      # live port state
redis-cli -n 4 keys "PORT|*"                # PORT table keys in CONFIG_DB
redis-cli -n 4 hgetall "PORT|Ethernet0"     # lanes/speed/alias of one port
```

## Changing the Port Layout — Your Three Options

| You want to...                                               | Mechanism                           |
|--------------------------------------------------------------|-------------------------------------|
| Use a completely different layout the vendor already defined | Switch HwSKU (`DEVICE_METADATA.hwsku` + config wipe/reload) — swaps the whole folder |
| Split or combine individual ports                            | Dynamic Port Breakout: `config interface breakout Ethernet0 "2x200G"` — driven by `platform.json` + `hwsku.json` |
| Create a layout that doesn't exist yet                       | Author a new HwSKU folder (new `port_config.ini`, matching ASIC config, buffer/QoS templates) — this is a porting task, done in the repo, not on the box |

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

**Previous**: [← The PMON Container](16_pmon_container.md) · **Next**: [Configuration Management →](18_configuration_management.md)
