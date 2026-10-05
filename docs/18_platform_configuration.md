# SONiC Platform Configuration

> **Prerequisites**: [The PMON Container](17_pmon_container.md) (the Platform API and vendor plugins that consume these files) and [Core Redis Databases](09_redis_databases.md) (CONFIG_DB as the runtime source of truth).

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
| `default_sku` | Which HwSKU to use when nothing else selects one — e.g. `DellEMC-Z9332f-O32 t1` (SKU name + default role). See [How the Active SKU Is Selected](#how-the-active-sku-is-selected). |
| `sonic_platform-*.whl` | The Platform API package — Python classes that PMON uses to read fans, PSUs, thermals, EEPROM, and transceivers. Built at image time from the vendor's `sonic_platform/` source directory. See [The PMON Container](17_pmon_container.md) for how this package is loaded and used. |
| `plugins/` | Legacy Python plugins for vendor-specific behavior (SFP access, LED control). Newer platforms use the `sonic_platform` wheel instead. |
| `pmon_daemon_control.json` | Which platform-monitor daemons run on this box (some platforms have no PSU daemon, etc.). See [Daemon Control](17_pmon_container.md#daemon-control-enabling-and-disabling-daemons). |
| `thermal_policy.json` | Fan-speed policy: which thermal conditions drive which fan actions. See [Fan Speed Control](17_pmon_container.md#fan-speed-control). |
| `sensors.conf` | lm-sensors mapping: names, scaling, and alarm thresholds for voltage/temp sensors. See [sensord](17_pmon_container.md#the-daemons-inside-pmon). |
| `installer.conf` | Boot/console settings consumed at image install (console port, baud rate) |
| `system_health_monitoring_config.json` | What the system-health service (`healthd`) checks/ignores on this platform — polling interval, devices to skip, LED colors. See [System Health Monitoring](19_host_services.md#system-health-monitoring-healthd). |
| `pcie.yaml` | Expected PCIe topology, used by the PCIe health checker. See [pcie-check](19_host_services.md#pcie-check). |
| `platform_components.json` | Firmware-upgradable components (BIOS, CPLD, FPGA, ONIE) for `fwutil` |

Vendors are free to add extras (firmware bundles, environment configs, custom reboot scripts, porting notes); the files above are the ones that SONiC infrastructure looks for.

> **Porting note:** adding support for a brand-new switch means creating exactly this — a new vendor folder (if the vendor is new) and a new platform folder with these files, sitting alongside the existing vendor trees such as Dell, Arista, and Mellanox.

## The HwSKU Folder — Port Layout

**HwSKU** stands for **Hardware SKU** (Stock Keeping Unit). It identifies a specific **port-layout variant** of a given platform — the same physical switch (same chassis, same ASIC) can be deployed with different port configurations, and each configuration is a different HwSKU. Think of it like retail inventory: the same T-shirt in size Medium / Blue is a different SKU from size Large / Red. Similarly, the same Celestica DX010 box configured as 32×100G is a different HwSKU from the same box configured as 64×50G.

**HwSKU** answers: *given this chassis, how are the ports arranged?*

The same physical box is often sold or deployed in multiple port configurations: all ports at max speed, some ports split into breakouts, a couple of ports reserved for management, different buffer tuning for leaf vs. spine roles — each variant is one HwSKU subfolder (as shown in the [Seastone example above](#concrete-example-celestica-seastone-dx010)).

### How the Active SKU Is Selected

The active SKU is resolved at boot time through a fixed fallback chain — the first source that provides an HwSKU wins:

1. **Saved configuration (CONFIG_DB)** — On every normal boot, `/etc/sonic/config_db.json` already exists. SONiC loads it directly, and the `DEVICE_METADATA|localhost.hwsku` field inside it determines the active SKU. This is the common case — once a configuration is generated, it persists across reboots.

2. **Minigraph** — On first boot (or after `config erase`), no CONFIG_DB exists. If a minigraph is available (`/etc/sonic/minigraph.xml` — an XML topology file provisioned via ZTP or placed manually), `sonic-cfggen -m` reads the `<HwSku>` element from it and generates a fresh CONFIG_DB with that SKU.

3. **`default_sku` file** — If neither CONFIG_DB nor a minigraph exists, `sonic-cfggen` reads the platform's `default_sku` file (e.g., `DellEMC-Z9332f-O32 t1`) to pick the SKU and the topology preset, then generates a factory-default CONFIG_DB from it.

Once CONFIG_DB is generated (by any of the three paths), it becomes the persistent source of truth — subsequent boots always use path 1.

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

The key file for port layout is `port_config.ini`. A row looks like:

```
# name     lanes                  alias   index    speed
Ethernet0  0,1,2,3,4,5,6,7        Et1/1   1        400000
Ethernet8  8,9,10,11,12,13,14,15  Et2/1   2        400000
```

"Lanes" are the ASIC's SerDes (Serializer/Deserializer) lanes — individual high-speed serial links. A 400G port here consumes 8 lanes; splitting that port 2x200G means two ports with 4 lanes each — which is exactly what breakout mode changes.

## From Files to a Running Switch — Who Reads What, When

The device folder files are **seeds**, not the runtime state. They are never read at run time — the running switch gets its configuration from CONFIG_DB (a Redis database). The question is: how do the seeds become CONFIG_DB entries?

The [Database Container startup sequence](08_database_container.md#startup-sequence) covers three cold-boot paths. Two of them never touch the seed files at all:

- **Normal reboot** — `/etc/sonic/config_db.json` already exists, so the `postStartAction` hook loads it straight into CONFIG_DB. Done.
- **Upgrade from an old image** — the old `config_db.json` is copied over and reloaded. The seed files are irrelevant.

The only path that reads the seed files is a **clean first boot** (no existing configuration). On that path, `config-setup` calls `sonic-cfggen`, which auto-discovers `port_config.ini` (or `platform.json` + `hwsku.json`) inside the device folder, builds a complete PORT table from it, and writes `/etc/sonic/config_db.json`. Then `config reload` loads that file into CONFIG_DB.

Once `config_db.json` exists, it is the durable source of truth. The seed files are only consulted again if you wipe the config, change HwSKU, or use breakout commands.

Separately from the CONFIG_DB path, syncd loads the ASIC vendor config named by `sai.profile` directly from the device folder on every boot. The ASIC's port map and the PORT table in CONFIG_DB must describe the same layout — if they disagree, the switch will not forward traffic.

Practical consequence worth remembering: **editing `port_config.ini` on a deployed switch does nothing** until the PORT table is re-generated. To inspect reality, read the runtime:

```
show interfaces status                      # live port state
redis-cli -n 4 keys "PORT|*"                # PORT table keys in CONFIG_DB
redis-cli -n 4 hgetall "PORT|Ethernet0"     # lanes/speed/alias of one port
```

## Switching to a Different HwSKU

When you want a completely different port layout that the vendor has already defined (e.g. switching a box from an all-400G spine layout to a mixed 100G/400G leaf layout), you switch the active HwSKU. This replaces the *entire* port inventory: you regenerate CONFIG_DB for the target SKU and cold reboot.

> **Note:** If you only need to split or combine a few individual ports without changing the overall layout, see [Dynamic Port Breakout](#dynamic-port-breakout) instead.

### Why You Cannot Just Edit the SKU Field

As explained in [How the Active SKU Is Selected](#how-the-active-sku-is-selected), the running HwSKU comes from `DEVICE_METADATA|localhost.hwsku` in CONFIG_DB. It is tempting to just change that one field to the new SKU name and reload. **This will leave the switch broken.** Here is why:

- CONFIG_DB does not store the SKU name alone — it also stores a `PORT` table with an entry for every port (name, lanes, speed, alias), all describing the *current* SKU's layout.

- Changing only the SKU name creates a three-way mismatch: the SKU field says "new layout," the PORT table still says "old layout," and the ASIC configuration loaded from the new SKU's `sai.profile` expects the new layout. syncd tries to create ports that don't match the PORT table, and port initialization fails.

The correct approach is to **regenerate the entire configuration from scratch** for the target SKU.

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


## Dynamic Port Breakout (DPB)

Dynamic Port Breakout lets you split or combine individual ports without changing the HwSKU or rebooting. For example, splitting one 400G port into 4×100G, or combining four 25G ports back into one 100G port:

```
config interface breakout Ethernet0 "2x200G"
config interface breakout Ethernet0 "4x100G"
config interface breakout Ethernet0 "1x400G"      # revert to original
```

SONiC reads the allowed breakout modes from `platform.json` (which modes the hardware supports) and `hwsku.json` (the default mode per port), updates the PORT table in CONFIG_DB, and reprograms the ASIC — all without a reboot.

### HwSKU Change vs. Dynamic Port Breakout

|                 | HwSKU change                             | Dynamic Port Breakout |
|-----------------|------------------------------------------|-----------------------|
| Scope           | Entire port inventory                    | Individual ports      |
| Config impact   | Full regeneration — custom settings lost | In-place; rest of config untouched |
| Reboot required | Yes (cold reboot)                        | No                                 |
| Defined by      | A different SKU folder                   | `platform.json` + `hwsku.json` breakout modes |
| Typical use     | Repurposing a box (leaf → spine), adopting a vendor-defined alternate layout | Splitting one 400G port into 4×100G |

Rule of thumb: if the layout you want already exists as a SKU folder, switch SKU. If you are adjusting a handful of ports within the current layout, use breakout.


---

**Previous**: [← The PMON Container](17_pmon_container.md) · **Next**: [Host Services →](19_host_services.md)
