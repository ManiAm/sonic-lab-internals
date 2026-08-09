# Container Build Time: How Container Images Are Built

This document covers SONiC's build-time container story — how Dockerfiles are structured, how the image hierarchy shares common layers, and what the build system produces for each container.

## Dockerfiles Are Templates

Every SONiC container is described by a `Dockerfile.j2`. The `.j2` extension means it is a **Jinja2 template** — a text file with placeholders and conditional logic. At build time, the build system renders each template with build-time variables — the target Debian release, the ASIC vendor, the CPU architecture, the list of locally built `.deb` packages — to produce a plain Dockerfile, which Docker then builds into an image.

For example, the SWSS container's `Dockerfile.j2` (`dockers/docker-orchagent/Dockerfile.j2`) contains:

```dockerfile
ARG BASE=docker-swss-layer-trixie-{{DOCKER_USERNAME}}:{{DOCKER_USERTAG}}
FROM $BASE

{% if ( CONFIGURED_ARCH == "armhf" or CONFIGURED_ARCH == "arm64" ) %}
RUN apt-get install -y gcc iputils-ping
{% endif %}
```

`{{DOCKER_USERNAME}}` and `{{DOCKER_USERTAG}}` are **placeholders** — at build time, the build system replaces them with real values (e.g. the developer's Docker Hub username and a build tag). The `{% if ... %}` block is **conditional logic** — the `gcc` package is only installed when building for ARM architectures, not for x86. After rendering, the build system feeds the resulting plain Dockerfile to `docker build`.

Jinja2 appears constantly in SONiC. The same template can be rendered with different inputs to produce a Broadcom build or a Mellanox build, a single-ASIC unit file or a multi-ASIC one. Keep this in mind: throughout this document and the [runtime document](05_container_run_time.md), whenever you see a `.j2` file, the real file on the switch is the *rendered result* of that template.

## The Image Hierarchy

Rather than building each container from scratch, SONiC stacks a small set of shared base images. Every container inherits from one of them, so common tooling is built and stored only once:

```
debian:trixie                            (stock Debian 13 — the foundation)
    └── docker-base-trixie                (adds Python 3, rsyslog, supervisord, redis-tools)
            └── docker-config-engine-trixie   (adds swsscommon and sonic-cfggen)
                    ├── docker-database
                    ├── docker-dhcp-relay
                    ├── docker-dhcp-server
                    ├── docker-eventd
                    ├── docker-lldp
                    ├── docker-mux
                    ├── docker-platform-monitor      (the pmon container)
                    ├── docker-router-advertiser
                    ├── docker-snmp
                    ├── docker-sonic-gnmi
                    │       └── docker-sonic-telemetry
                    ├── docker-sonic-mgmt-framework
                    ├── docker-sonic-p4rt
                    ├── docker-stp
                    ├── docker-syncd-<vendor>        (platform-specific)
                    ├── ...                          (and others)
                    └── docker-swss-layer-trixie     (adds the sonic-swss daemons)
                            ├── docker-dash-ha
                            ├── docker-fpm-frr       (the bgp container)
                            ├── docker-iccpd
                            ├── docker-macsec
                            ├── docker-nat
                            ├── docker-orchagent     (the swss container)
                            ├── docker-sflow
                            └── docker-teamd
```

What each shared layer contributes:

| Layer | What It Adds |
|-------|-------------|
| **docker-base-trixie** | Minimal Debian plus the tooling every SONiC container needs: Python 3, `rsyslog` (with the RELP module for log forwarding), `supervisord` and its dependent-startup plugin, `redis-tools`, and common shared libraries |
| **docker-config-engine-trixie** | Everything a container needs to talk to SONiC's databases: the `swsscommon` library (C++ and Python bindings for Redis), `sonic-db-cli`, the YANG model libraries, and the config engine `sonic-cfggen`, which lets a container generate its own configuration files from Redis at startup |
| **docker-swss-layer-trixie** | The `swss` package — the compiled SWSS **daemons** themselves: `orchagent`, the manager daemons (`portmgrd`, `vlanmgrd`, `intfmgrd`, `buffmgrd`, and the rest), and the sync daemons (`portsyncd`, `neighsyncd`, `fpmsyncd`, `teamsyncd`, and others) |

A few entries in the tree deserve explanation:

- **`docker-swss-layer-trixie`** exists solely to ship the sonic-swss daemon binaries. A container inherits from it only when it must run one of those daemons — for example, the BGP container requires `fpmsyncd`, the teamd container requires `teammgrd` and `teamsyncd`, and the NAT container requires `natmgrd` and `natsyncd`. Containers that have no such dependency, such as LLDP or SNMP, inherit from the config engine layer directly and remain smaller as a result.

- **`docker-sonic-telemetry`** inherits from `docker-sonic-gnmi` rather than from a shared base. It extends the gNMI container instead of duplicating it.

- **`docker-syncd-<vendor>`** is platform-specific: the build produces a different syncd image per ASIC vendor SDK, such as `docker-syncd-brcm` (Broadcom), `docker-syncd-mlnx` (NVIDIA/Mellanox), or `docker-syncd-vs` (the virtual switch used for testing). It inherits from the *config engine* layer rather than the swss layer: syncd is heavily involved with Redis, but it runs none of the sonic-swss daemons — it ships the vendor SDK and the `sairedis` library instead.

Because the tree is shallow and wide, optimizing a shared layer has a multiplied effect: trimming a package out of `docker-base` saves that space in every derived image — more than thirty containers in a full build.

## Why Multiple Debian Versions Exist in the Source Tree

Browsing the source, you will find parallel base images — `docker-base-bookworm` alongside `docker-base-trixie`, `docker-config-engine-bullseye`, and so on. This is deliberate.

SONiC first shipped on Debian 8 (jessie) around 2016 and has added support for newer releases one at a time:

| Codename | Debian Version | Year | Status on current `master` |
|----------|----------------|------|----------------------------|
| jessie   | Debian 8       | 2015 | Deprecated (disabled by default) |
| stretch  | Debian 9       | 2017 | Deprecated (disabled by default) |
| buster   | Debian 10      | 2019 | Deprecated (disabled by default) |
| bullseye | Debian 11      | 2021 | Deprecated (disabled by default) |
| bookworm | Debian 12      | 2023 | Enabled — still used by a few images |
| trixie   | Debian 13      | 2025 | Enabled — the primary build target |

**Why not simply drop the old versions?** Porting every component to a new Debian release is a large effort. Each container's dependencies — system libraries, Python packages, compiler versions — can behave differently on a new release. Some containers port in days, others take months. While that migration is in flight, the build system must be able to produce images for both the old and the new distribution, so that:

- Containers already ported build against the newer base.
- Containers not yet ported keep building against the older base.
- The final SONiC image can ship a mix of containers from different bases if necessary.

That last point is not hypothetical. On current `master`, every functional container is built on the trixie layers except a couple of virtual-switch images (`docker-sonic-vs` and Nokia's virtual syncd), which still build on bookworm. Keeping bookworm enabled is what lets those images continue to work while the rest of the tree moves forward.

Once every container is ported and validated, the old distribution is deprecated: its `NO<DISTRO>` flag defaults to `1` in the top-level `Makefile`, which disables it. The infrastructure stays in the tree for anyone who needs to build an older configuration, but the default build stops producing those images.

```makefile
NOJESSIE   ?= 1    # Disabled
NOSTRETCH  ?= 1    # Disabled
NOBUSTER   ?= 1    # Disabled
NOBULLSEYE ?= 1    # Disabled
NOBOOKWORM ?= 0    # Enabled
NOTRIXIE   ?= 0    # Enabled (primary)
```

## What a Container's Dockerfile Does

Every container Dockerfile follows the same four-step shape:

1. Inherit from the appropriate base image.
2. Install the Debian packages and Python wheels this container's daemons need.
3. Copy the container's Jinja2 templates and scripts into the image, and render the entrypoint script.
4. Declare the **entrypoint** — the command Docker runs when the container starts.

Simplified from the SWSS container (`dockers/docker-orchagent/Dockerfile.j2`):

```dockerfile
ARG BASE=docker-swss-layer-trixie
FROM $BASE

# 2. Upstream Debian packages this container needs
RUN apt-get install -y iproute2 bridge-utils conntrack ndppd

#    Locally built SONiC packages (orchagent, the *mgrd daemons, and so on)
COPY debs/ /debs/
RUN dpkg -i /debs/*.deb

# 3. Ship all templates, and render the entrypoint script now, at build time
COPY ["*.j2", "/usr/share/sonic/templates/"]
RUN sonic-cfggen -t /usr/share/sonic/templates/docker-init.j2 > /usr/bin/docker-init.sh
RUN chmod 755 /usr/bin/docker-init.sh

# 4. What runs when the container starts
ENTRYPOINT ["/usr/bin/docker-init.sh"]
```

Note the split in step 3. The *entrypoint script itself* is rendered at build time, because it depends only on build-time facts. The templates it will use are merely copied in; they get rendered later, on the switch, because they depend on the device's actual configuration. The [runtime document](05_container_run_time.md) picks up that thread.

## What Else the Build Produces Per Container

Building the image is only half the job. For each container, the build also generates two host-side files and installs them into the SONiC image:

| Generated file               | Installed at                             | Rendered from                                             | Purpose |
|------------------------------|------------------------------------------|-----------------------------------------------------------|---------|
| **systemd unit**             | `/usr/lib/systemd/system/<name>.service` | `files/build_templates/[per_namespace/]<name>.service.j2` | Tells systemd how to manage this container |
| **Container control script** | `/usr/bin/<name>.sh`                     | `files/build_templates/docker_image_ctl.j2` | Runs the actual `docker create` / `start` / `stop` commands |

Both come from templates, so a single source file produces the correct unit and script for every container and every platform. These two files are the bridge from build time to run time, and they are where the [runtime document](05_container_run_time.md) begins.

---

**Previous**: [← SONiC Container Architecture](03_sonic_container.md) · **Next**: [Container Run Time →](05_container_run_time.md)
