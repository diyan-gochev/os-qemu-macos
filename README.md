# macOS-Dev (QEMU/KVM + Clover) — macOS VM on Linux

This repository contains a Bash-based workflow for running a macOS virtual machine on Linux using **QEMU/KVM**, **OVMF (UEFI)**, and **Clover**. It is designed around a simple directory layout and a single script (`os.sh`) that handles install/start/mount/cleanup operations.

> [!IMPORTANT]
> Tested on Debian Linux / AMD Ryzen 7 PRO 7840U w/ Radeon 780M Graphics **ONLY!**

**IMPORTANT: USE AT YOUR OWN RISK. THIS PROJECT IS PROVIDED “AS IS”, WITH NO WARRANTIES OR GUARANTEES OF ANY KIND. YOU ARE RESPONSIBLE FOR COMPLIANCE, DATA SAFETY, AND ANY DAMAGE OR LOSS THAT MAY OCCUR.**

## What this repo is (and is not)

- Provides a reproducible host-side setup for a macOS VM: firmware files, bootloader, and QEMU invocation.
- Automates common tasks (e.g., preparing ESP, fetching recovery media, launching QEMU, mounting ESP for edits).
- Does **not** include the macOS operating system itself, and does not bypass Apple licensing requirements.

## Repository layout

Typical structure:

```

macOS-Dev/
os.sh                  # main entrypoint
bin/                   # helper binaries (optional)
lib/                   # tooling and bootloader payloads (downloaded by script)
firmware/              # OVMF firmware (CODE) used by QEMU
share/                 # recovery media artifacts (downloaded)
var/                   # VM state: disks, NVRAM vars, etc. (runtime)
tmp/                   # temporary mounts and working directories (runtime)
logs/                  # qemu/serial logs (runtime)

````

### Tracked vs untracked
This repo intentionally ignores runtime state and large artifacts:
- VM disks (`*.qcow2`, `*.img`, `*.dmg`, etc.)
- logs, temporary mounts, caches
- downloaded recovery artifacts

See `.gitignore`.

## Requirements (host)

- Linux with KVM enabled (Intel VT-x / AMD-V)
- QEMU
- OVMF (UEFI firmware)
- `qemu-nbd`, `nbd` kernel module
- Common utilities: `wget`, `unzip`, `python3`, `parted`, `mkfs.fat`, `mount`

On Debian-based systems, typical packages include:
- `qemu-system-x86`, `qemu-utils`, `ovmf`, `python3`, `wget`, `unzip`, `parted`, `dosfstools`, `nbd-client` (or just `modprobe nbd`)

## Quick start

### 1) Clone
```bash
git clone <this-repo>
cd macOS-Dev
````

### 2) Prepare firmware (OVMF)

This project expects OVMF firmware files to be present in:

* `firmware/OVMF_CODE.fd`
* `var/OVMF_VARS.fd`

On Debian/Ubuntu, matching 4M firmware templates are commonly available under `/usr/share/OVMF/`:

* `OVMF_CODE_4M.fd`
* `OVMF_VARS_4M.fd`

Example (adjust paths if needed):

```bash
sudo cp /usr/share/OVMF/OVMF_CODE_4M.fd firmware/OVMF_CODE.fd
sudo cp /usr/share/OVMF/OVMF_VARS_4M.fd var/OVMF_VARS.fd
sudo chown "$USER:$USER" firmware/OVMF_CODE.fd var/OVMF_VARS.fd
chmod u+r firmware/OVMF_CODE.fd
chmod u+rw var/OVMF_VARS.fd
```

### 3) Run the workflow script

The script is the main interface:

```bash
./os.sh install
./os.sh start
```

Depending on your environment, the script may require `sudo` for:

* `qemu-nbd` attach/detach
* mounting filesystems
* partitioning/formatting the ESP

## Common operational notes

### macOS installation is multi-stage (Preboot)

macOS installation is typically **two-stage**:

1. Boot from the recovery/base system to start installation.
2. On reboot, continue installation via the **Preboot / Installer** entry.

If Clover hides extra entries by default, use:

* **F3** in Clover to show hidden boot entries
* then choose the **Preboot / Install** option until it disappears

A reliable indicator that installation is not finished is the presence of:

* `macOS Install Data` on the target volume

### Network

This project uses QEMU user-mode networking by default. If DNS issues occur, avoid forcing a public DNS server via `-netdev user,...,dns=...` unless you have a strong reason. Default user-mode DNS behavior is often more reliable.

### CPU flags

CPU feature flags can affect runtime stability. If you encounter unexplained stalls, time drift, or input issues, A/B test CPU flags (especially timing-related ones) methodically.

## Editing Clover configuration

The Clover configuration file lives on the ESP (EFI system partition). The script may provide helper commands to mount/unmount it; otherwise you can mount it via NBD and edit:

* `EFI/CLOVER/config.plist`

## Logging and troubleshooting

* QEMU logs: `logs/`
* Serial logs: `logs/serial-*.log` (if enabled)
* QEMU monitor: if started with `-monitor stdio`, you can use:

  * `info status`, `info blockstats`, `system_reset`, etc.

If you get stuck at an Apple progress bar:

* check disk I/O via QEMU monitor (`info blockstats`)
* boot the correct installer stage (Preboot)
* enable verbose boot (`-v`) and capture the last visible lines

## Legal and licensing

Apple’s macOS licensing terms may restrict where and how macOS can be run. You are responsible for ensuring you have the legal right to use macOS in your environment.

## Contributing

Contributions are welcome, especially:

* safer defaults
* clearer troubleshooting paths
* improvements to idempotency (avoid re-downloading/rebuilding when not needed)

Please keep changes small, explain rationale, and include testing notes.

## Disclaimer

**IMPORTANT: USE AT YOUR OWN RISK. THIS PROJECT IS PROVIDED “AS IS”, WITH NO WARRANTIES OR GUARANTEES OF ANY KIND. YOU ARE RESPONSIBLE FOR COMPLIANCE, DATA SAFETY, AND ANY DAMAGE OR LOSS THAT MAY OCCUR.**

```
