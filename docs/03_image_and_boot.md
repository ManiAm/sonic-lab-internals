# Image and Boot

This document covers how SONiC packages its operating system into a single compressed image, how that image is installed and booted on a switch, and how the dual-image design enables safe upgrades with rollback.

## What is SquashFS?

SquashFS is a **read-only, compressed filesystem** built into the Linux kernel.

Think of it like a **ZIP file that the kernel can mount directly as a real filesystem** — you don't need to extract it first. Applications read files from it exactly as they would from a normal disk; the kernel transparently decompresses blocks on the fly.

| Concept    | ZIP file                        | SquashFS                              |
|------------|---------------------------------|---------------------------------------|
| Compressed | Yes                             | Yes (zlib, lzo, xz, zstd)             |
| Writable   | Yes (after extraction)          | No — strictly read-only               |
| Mountable  | No (must extract first)         | Yes — `mount -t squashfs img /mnt`    |
| Use case   | Archiving / file transfer       | Embedded systems, live CDs, SONiC OS  |

**Key properties:**

- Files are compressed with block-level granularity (typically 128 KiB blocks), so the kernel only decompresses the blocks it needs.
- Metadata (directory entries, inodes, symlinks) is also compressed.
- De-duplication is performed at build time — identical files are stored once.
- The image is a single flat file (e.g., `filesystem.squashfs`), easy to copy, checksum, and swap.

## What is OverlayFS?

SquashFS is read-only, but a running system needs to write files — logs, configuration changes, temporary data. **OverlayFS** is a Linux kernel feature that solves this by **merging a read-only lower layer with a writable upper layer** into a single unified filesystem view:

```
Read a file:
  → If it exists in upper (rw), serve from upper
  → Otherwise, serve from lower (squashfs)

Write a file:
  → Always goes to upper (rw)
  → The squashfs original is never modified

Delete a file:
  → A "whiteout" marker is written to upper
    (a special empty file that tells OverlayFS to hide the original)
  → The file disappears from the merged view but still exists in squashfs
```

This gives the best of both worlds: an **immutable, compressed OS base** with full **read-write capability** at runtime. Writes are isolated to the upper layer, so removing it instantly restores the original read-only filesystem.

## Why SONiC Uses SquashFS

SONiC runs on network switches that typically have **limited storage** — often a single 16–64 GB SSD or eMMC module. The entire operating system, Docker images, and configuration must fit on that device, with room for two OS images (current + rollback).

SquashFS solves several problems at once:

### Compression

A typical SONiC root filesystem is **2–3× smaller** when packed into SquashFS compared to a raw ext4 partition.

```
Uncompressed rootfs (ext4):   ~3.5 GB
SquashFS image (xz):          ~1.2 GB   ← fits easily on small SSDs
```

This is critical when the switch needs to store two full images plus Docker overlay data on a small disk.

### Read-only Protection

The base OS files **cannot be accidentally modified or corrupted**. There is no `rm -rf /` risk, no bit-rot on system binaries, and no way for a misbehaving process to alter the OS image. If something goes wrong, a reboot always returns to the known-good SquashFS image.

### Fast Boot

- **No fsck:** Because the filesystem is read-only and integrity is guaranteed by its checksum, the kernel never needs to run a filesystem check at boot. On ext4, an unclean shutdown can trigger a multi-minute `fsck`.

- **Sequential reads:** The SquashFS image is laid out sequentially on disk, so mounting it is a single contiguous read — ideal for the slow SSDs found in switch hardware.

### Image-based Upgrades

Upgrading SONiC means writing a **new SquashFS image** to disk. There is no package-by-package upgrade (like `apt upgrade`). The entire root filesystem is swapped atomically. If the new image fails to boot, the switch can fall back to the previous image. The dual-image mechanism that makes this possible is described in [Dual-Image Support](#dual-image-support).

## Filesystem Roles in SONiC

SONiC uses four filesystem types, each serving a specific role:

| Property         | SquashFS              | ext4                  | tmpfs               | OverlayFS                        |
|------------------|-----------------------|-----------------------|---------------------|----------------------------------|
| **Read/Write**   | Read-only             | Read-write            | Read-write          | Union (read-only + read-write)   |
| **Compressed**   | Yes (xz, zstd, lzo)   | No                    | No (RAM)            | Depends on layers                |
| **Journaled**    | No (not needed)       | Yes                   | No                  | Depends on upper fs              |
| **Persistent**   | Yes (on disk)         | Yes (on disk)         | No (lost on reboot) | Upper layer is persistent        |
| **Integrity**    | Checksum verified     | Journal recovery      | N/A                 | Inherits from layers             |
| **Boot speed**   | Fast (no fsck)        | Slow if unclean       | Instant             | Fast (squashfs lower)            |
| **Typical use**  | OS image, rootfs      | General storage       | /tmp, /run          | Writable overlay on squashfs     |
| **SONiC role**   | Root filesystem image | /host partition       | Temp directories    | Merged root at runtime           |

### How They Work Together on Disk

The switch's SSD has a single ext4 partition mounted at `/host`. This partition stores the SquashFS images, the OverlayFS writable layers, and the bootloader configuration:

```
/dev/sda1  (ext4)         ← /host partition, stores squashfs images + writable data
  └── /host/
       ├── image-current/
       │    ├── fs.squashfs         ← SquashFS (the compressed rootfs)
       │    ├── rw/                 ← OverlayFS upper layer (writable)
       │    └── work/               ← OverlayFS work directory
       ├── image-previous/
       │    ├── fs.squashfs         ← Previous SquashFS image (rollback)
       │    ├── rw/
       │    └── work/
       └── grub/
            └── grub.cfg
```

At runtime, the kernel mounts OverlayFS with the SquashFS as the lower layer and `rw/` as the upper layer. The result is a unified root filesystem where reads come from the compressed SquashFS and writes go to `rw/` on ext4.

## The Build Pipeline

The SONiC build system (`sonic-buildimage`) goes through several stages before producing the final `.bin` installer:

```
┌─────────────────────────────────────────────────────────────────────┐
│                     SONiC Build Pipeline                            │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Stage 1: Build individual .deb packages                            │
│  ─────────────────────────────────────────                          │
│  sonic-swss_1.0.0_amd64.deb                                         │
│  sonic-syncd-mlnx_1.0.0_amd64.deb                                   │
│  sonic-utilities_1.0.0_all.deb                                      │
│  sonic-ucli_1.0.0_amd64.deb                                         │
│  ... (100+ packages)                                                │
│           │                                                         │
│           ▼                                                         │
│  Stage 2: Build Docker container images                             │
│  ──────────────────────────────────────                             │
│  docker-syncd-mlnx.gz                                               │
│  docker-orchagent.gz                                                │
│  docker-bgp.gz                                                      │
│  docker-teamd.gz                                                    │
│  docker-snmp.gz                                                     │
│  ... (15-20 container images)                                       │
│           │                                                         │
│           ▼                                                         │
│  Stage 3: Assemble the root filesystem                              │
│  ─────────────────────────────────────                              │
│  Install base Debian (Bullseye/Bookworm) via debootstrap            │
│    (debootstrap is a tool that installs a minimal Debian system     │
│     into a directory — no installer CD needed)                      │
│  Install all .deb packages                                          │
│  Copy Docker .gz images into /var/images/                           │
│  Install config files, systemd units, boot scripts                  │
│  Generate /etc/sonic/sonic_version.yml                              │
│           │                                                         │
│           ▼                                                         │
│  Stage 4: Compress into SquashFS                                    │
│  ────────────────────────────────                                   │
│  mksquashfs fsroot/ sonic-mellanox.bin__mellanox__rfs.squashfs \    │
│      -comp xz -b 131072                                             │
│                                                                     │
│  Output: sonic-mellanox.bin__mellanox__rfs.squashfs (~1.2 GB)       │
│           │                                                         │
│           ▼                                                         │
│  Stage 5: Pack into the .bin installer                              │
│  ─────────────────────────────────────                              │
│  sonic-mellanox.bin contains:                                       │
│    ├── Self-extracting shell script header (ONIE installer)         │
│    ├── vmlinuz (Linux kernel)                                       │
│    ├── initrd.img (initial ramdisk)                                 │
│    ├── sonic-mellanox.bin__mellanox__rfs.squashfs (rootfs)          │
│    ├── GRUB bootloader config                                       │
│    └── Checksums / metadata                                         │
│                                                                     │
│  Output: sonic-mellanox.bin (~1.3 GB, self-extracting installer)    │
└─────────────────────────────────────────────────────────────────────┘
```

### What is the `.bin` File?

The `.bin` file is a **self-extracting shell script** that ONIE (Open Network Install Environment) executes on the switch. It is not a raw disk image — it contains a shell script header followed by a compressed payload. When ONIE runs it, the script extracts the SquashFS, kernel, and bootloader configuration onto the switch's local storage.

## The Boot Sequence

Once the `.bin` installer has been run (either via ONIE for first install or `sonic-installer` for upgrades), the switch boots through this sequence:

```
┌──────────────────────────────────────────────────────────────────┐
│                    Boot Sequence (Bottom → Top)                  │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  Docker Containers                                         │  │
│  │  (swss, syncd, bgp, teamd, snmp, lldp, ...)                │  │
│  ├────────────────────────────────────────────────────────────┤  │
│  │  OverlayFS  (writable layer)                               │  │
│  │  upper: /host/image-current/rw    ← logs, config, runtime  │  │
│  │  lower: squashfs mount            ← read-only OS base      │  │
│  ├────────────────────────────────────────────────────────────┤  │
│  │  SquashFS Root Filesystem                                  │  │
│  │  mounted read-only from fs.squashfs                        │  │
│  ├────────────────────────────────────────────────────────────┤  │
│  │  Linux Kernel  (vmlinuz + initrd)                          │  │
│  │  mounts squashfs, sets up overlayfs, pivots root           │  │
│  ├────────────────────────────────────────────────────────────┤  │
│  │  GRUB Bootloader                                           │  │
│  │  selects which image to boot (current or previous)         │  │
│  ├────────────────────────────────────────────────────────────┤  │
│  │  ONIE  (Open Network Install Environment)                  │  │
│  │  firmware-level installer, runs .bin files                 │  │
│  │  NOTE: ONIE only runs during first install or recovery —   │  │
│  │  normal boots go directly from BIOS/UEFI to GRUB           │  │
│  ├────────────────────────────────────────────────────────────┤  │
│  │  Switch Hardware  (Mellanox Spectrum ASIC, CPU, SSD, NIC)  │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### Step-by-step Boot Flow

1. **Power on** — The switch BIOS/UEFI starts and hands off to GRUB. (ONIE is **not** involved in normal boots — it only runs during first-time installation or disaster recovery. Once SONiC is installed, GRUB takes over as the bootloader.)

2. **GRUB** — Reads its config from `/host/grub/grub.cfg`, loads the kernel (`vmlinuz`) and initial ramdisk (`initrd.img`) for the selected image slot (current or previous).

3. **Kernel + initrd** — The Linux kernel boots, the initrd runs early userspace scripts that:
   - Locate the SquashFS file on disk (e.g., `/host/image-current/fs.squashfs`)
   - Mount it read-only to a temporary mount point
   - Create an OverlayFS with the SquashFS as the **lower** (read-only) layer and a writable directory as the **upper** layer (see [What is OverlayFS?](#what-is-overlayfs) for details)
   - `pivot_root` into the OverlayFS union — this becomes `/` (`pivot_root` is a Linux system call that swaps the root filesystem; the initrd's temporary root is replaced by the OverlayFS mount)

4. **OverlayFS root** — The system now has a fully functional root filesystem:
   - Reads come from SquashFS (compressed, read-only OS base)
   - Writes go to the upper layer on disk (`/host/image-current/rw/`)
   - This means logs, config changes, and runtime state persist across reboots but can be wiped cleanly by removing the upper layer

5. **systemd** — The init system starts, bringing up services and Docker.

6. **Docker containers** — SONiC's functionality lives in Docker containers (swss, syncd, bgp, teamd, etc.) that start on top of the OverlayFS root.

## Dual-Image Support

SONiC always maintains **two image slots** on disk: `image-current` and `image-previous` (shown in the [disk layout](#how-they-work-together-on-disk) above). This enables safe, rollback-capable upgrades.

### How It Works

```
Before upgrade:
┌─────────────────────────────────────────────┐
│  /host/image-current/    ← SONiC 202305     │  (running)
│  /host/image-previous/   ← SONiC 202211     │  (rollback)
└─────────────────────────────────────────────┘

During "sonic-installer install <new-image.bin>":
  1. The old "image-previous" is deleted to free space
  2. The current "image-current" is renamed to "image-previous"
  3. The new image is extracted to "image-current"
  4. GRUB config is updated to boot the new image

After upgrade:
┌─────────────────────────────────────────────┐
│  /host/image-current/    ← SONiC 202405     │  (new, will boot next)
│  /host/image-previous/   ← SONiC 202305     │  (rollback)
└─────────────────────────────────────────────┘
```

### Using `sonic-installer`

```bash
# List installed images and which one is current/next-boot
admin@switch:~$ sonic-installer list
Current: SONiC-OS-202405.1-mellanox
Next:    SONiC-OS-202405.1-mellanox
Available:
  SONiC-OS-202405.1-mellanox
  SONiC-OS-202305.3-mellanox

# Install a new image (downloads or uses local .bin file)
admin@switch:~$ sudo sonic-installer install sonic-mellanox-202411.bin

# Roll back to the previous image
admin@switch:~$ sudo sonic-installer set-default SONiC-OS-202305.3-mellanox

# Remove an image (cannot remove the currently running image)
admin@switch:~$ sudo sonic-installer remove SONiC-OS-202305.3-mellanox
```

### Why Dual Images Matter

| Scenario                          | What happens                                          |
|-----------------------------------|-------------------------------------------------------|
| Upgrade succeeds                  | New image becomes current, old becomes rollback       |
| Upgrade fails to boot             | GRUB falls back to previous image automatically       |
| Upgrade boots but has bugs        | Admin runs `sonic-installer set-default` to roll back |
| Disk is nearly full               | Old image is removed before new one is installed      |

This dual-image design is made practical by SquashFS: because each image is a single compressed file (~1.2 GB), it is feasible to keep two complete OS images on the switch's small SSD. Without compression, two copies of a 3.5 GB rootfs would not fit.

## Key Commands

### Inspecting a SquashFS Image

```bash
# List all files inside a squashfs image (without extracting)
unsquashfs -l sonic-mellanox.bin__mellanox__rfs.squashfs

# Show squashfs metadata (compression type, block size, file count)
unsquashfs -s sonic-mellanox.bin__mellanox__rfs.squashfs
```

Example output of `-s`:
```
Found a valid SQUASHFS 4:0 superblock on sonic-mellanox.bin__mellanox__rfs.squashfs
Creation or last append time is Thu Aug 20 14:32:11 2026
Filesystem size 1248316.42 Kbytes (1219.06 Mbytes)
Compression xz
Block size 131072
Number of fragments 2847
Number of inodes 48923
Number of ids 1
```

### Extracting a SquashFS Image

```bash
# Extract everything into a directory called "squashfs-root"
unsquashfs sonic-mellanox.bin__mellanox__rfs.squashfs

# Extract to a specific directory
unsquashfs -d /tmp/rootfs sonic-mellanox.bin__mellanox__rfs.squashfs

# Extract only specific files or directories
unsquashfs -d /tmp/etc-only sonic-mellanox.bin__mellanox__rfs.squashfs etc/sonic
```

### Creating a SquashFS Image

```bash
# Create a squashfs image from a directory
mksquashfs /path/to/rootfs output.squashfs -comp xz -b 131072

# Options:
#   -comp xz       Use xz compression (best ratio, slower to build)
#   -comp zstd     Use zstd compression (good ratio, faster)
#   -b 131072      Block size of 128 KiB
#   -noappend      Don't append to existing squashfs, create fresh
```

### Mounting a SquashFS Image

```bash
# Mount read-only (requires root)
sudo mount -t squashfs -o loop sonic-mellanox.bin__mellanox__rfs.squashfs /mnt

# Inspect the mounted filesystem
ls /mnt/etc/sonic/
cat /mnt/etc/sonic/sonic_version.yml

# Unmount when done
sudo umount /mnt
```

### On a Running SONiC Switch

```bash
# See what is mounted as the root filesystem
mount | grep squashfs

# Check the current and previous images
sonic-installer list

# Show disk usage of squashfs images
ls -lh /host/image-*/fs.squashfs
```

## Summary

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  Build time:                                                    │
│    .deb packages + Docker images                                │
│        → assembled into rootfs directory                        │
│        → compressed with mksquashfs → fs.squashfs               │
│        → bundled with kernel + GRUB → sonic-mellanox.bin        │
│                                                                 │
│  Install time:                                                  │
│    ONIE runs sonic-mellanox.bin                                 │
│        → extracts squashfs + kernel to /host/image-current/     │
│        → configures GRUB                                        │
│                                                                 │
│  Boot time:                                                     │
│    GRUB → kernel → mount squashfs (read-only)                   │
│        → overlayfs (squashfs + writable upper) → pivot_root     │
│        → systemd → Docker containers (swss, syncd, bgp, ...)    │
│                                                                 │
│  Runtime:                                                       │
│    Reads  → served from compressed squashfs (fast, immutable)   │
│    Writes → go to overlayfs upper layer on ext4 (persistent)    │
│                                                                 │
│  Upgrade:                                                       │
│    sonic-installer install new.bin                              │
│        → old current becomes previous (rollback)                │
│        → new image becomes current                              │
│        → reboot into the new squashfs                           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

SquashFS is the foundation that makes SONiC's image-based, upgrade-safe, space-efficient architecture possible on resource-constrained network switch hardware.

**Previous**: [← Architecture Overview](02_architecture_overview.md) · **Next**: [SONiC Container Architecture →](04_sonic_container.md)
