#!/usr/bin/env bash
set -auo pipefail

VMDIR="$HOME/vmware/macOS-Dev"

# Linux-style directory structure
BIN_DIR="$VMDIR/bin"
LIB_DIR="$VMDIR/lib"
VAR_DIR="$VMDIR/var"
TMP_DIR="$VMDIR/tmp"
LOG_DIR="$VMDIR/logs"
FIRMWARE_DIR="$VMDIR/firmware"
SHARE_DIR="$VMDIR/share"

# Mount/NBD settings
NBD_DEVICE="/dev/nbd0"
MOUNT_POINT="$VMDIR/tmp/efi-mount"
MAX_WAIT=5

# Files to keep during clean
KEEP_FILES=(
    "os.sh"
    "config.plist"
    "basic.sh.backup"
)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

RECOVERY_DMG="$SHARE_DIR/BaseSystem.dmg"
RECOVERY_IMG="$SHARE_DIR/BaseSystem.img"

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
step() { echo -e "\n${BLUE}=== $1 ===${NC}\n"; }

wait_for_nbd() {
  local dev="${1:?usage: wait_for_nbd /dev/nbd0}"
  local base
  base="$(basename "$dev")"   # nbd0
  local pid_path="/sys/block/$base/pid"
  local size_path="/sys/block/$base/size"

  # Wait up to ~6 seconds (30 * 0.2s) for the NBD server + size to be present.
  for _ in {1..30}; do
    # pid file exists and is non-empty, and exported size is non-zero
    if [[ -r "$pid_path" ]] && [[ -s "$pid_path" ]] && [[ -r "$size_path" ]] && [[ "$(cat "$size_path")" -gt 0 ]]; then
      return 0
    fi
    sleep 0.2
  done

  return 1
}


# ============================================================================
# INSTALL COMMAND
# ============================================================================
cmd_install() {
    step "Creating Linux-style directory structure"
    mkdir -p "$BIN_DIR" "$LIB_DIR" "$VAR_DIR" "$TMP_DIR" "$LOG_DIR" "$FIRMWARE_DIR" "$SHARE_DIR"
    
    cd "$VMDIR"
    
    # Download Clover
    step "Checking Clover bootloader"
    if [[ ! -f "$LIB_DIR/clover/CloverV2/EFI/CLOVER/CLOVERX64.efi" ]]; then
        log "Downloading latest Clover release..."
        mkdir -p "$LIB_DIR/clover"
        
        CLOVER_URL=$(curl -s https://api.github.com/repos/CloverHackyColor/CloverBootloader/releases/latest | \
            grep "browser_download_url.*CloverV2.*\.zip" | cut -d '"' -f 4)
        
        wget -O "$TMP_DIR/CloverV2.zip" "$CLOVER_URL"
        unzip -q "$TMP_DIR/CloverV2.zip" -d "$LIB_DIR/clover/"
        rm "$TMP_DIR/CloverV2.zip"
        log "✓ Clover downloaded and extracted"
    else
        log "✓ Clover already installed"
    fi
    
    # Download OVMF firmware
    step "Checking OVMF UEFI firmware"
    if [[ ! -f "$FIRMWARE_DIR/OVMF_CODE.fd" ]]; then
        log "Downloading OVMF_CODE.fd..."
        wget -O "$FIRMWARE_DIR/OVMF_CODE.fd" \
            "https://github.com/kholia/OSX-KVM/raw/master/OVMF_CODE.fd"
        log "✓ OVMF_CODE.fd downloaded"
    else
        log "✓ OVMF_CODE.fd already exists"
    fi
    
    if [[ ! -f "$FIRMWARE_DIR/OVMF_VARS-1024x768.fd" ]]; then
        log "Downloading OVMF_VARS template..."
        wget -O "$FIRMWARE_DIR/OVMF_VARS-1024x768.fd" \
            "https://github.com/kholia/OSX-KVM/raw/master/OVMF_VARS-1024x768.fd"
        log "✓ OVMF_VARS template downloaded"
    else
        log "✓ OVMF_VARS template already exists"
    fi
    
    # Create runtime OVMF_VARS
    if [[ ! -f "$VAR_DIR/OVMF_VARS.fd" ]]; then
        log "Creating runtime OVMF_VARS..."
        cp "$FIRMWARE_DIR/OVMF_VARS-1024x768.fd" "$VAR_DIR/OVMF_VARS.fd"
        log "✓ Runtime OVMF_VARS created"
    else
        log "✓ Runtime OVMF_VARS already exists"
    fi
    
    # Download macrecovery tool
    step "Checking macrecovery tool"
    if [[ ! -f "$LIB_DIR/macrecovery/macrecovery.py" ]]; then
        log "Downloading macrecovery tool..."
        mkdir -p "$LIB_DIR/macrecovery"
        wget -O "$TMP_DIR/macrecovery.zip" \
            "https://github.com/acidanthera/OpenCorePkg/archive/refs/heads/master.zip"
        unzip -q "$TMP_DIR/macrecovery.zip" "OpenCorePkg-master/Utilities/macrecovery/*" -d "$TMP_DIR"
        mv "$TMP_DIR/OpenCorePkg-master/Utilities/macrecovery"/* "$LIB_DIR/macrecovery/"
        rm -rf "$TMP_DIR/macrecovery.zip" "$TMP_DIR/OpenCorePkg-master"
        log "✓ macrecovery tool downloaded"
    else
        log "✓ macrecovery tool already installed"
    fi
    
    # Download macOS Tahoe recovery
    step "Checking macOS Tahoe recovery image"
    if [[ ! -f "$RECOVERY_IMG" ]]; then
        log "Downloading Tahoe recovery (this may take a while)..."
        
        cd "$TMP_DIR"
        python3 "$LIB_DIR/macrecovery/macrecovery.py" \
            -b Mac-7BA5B2D9E42DDD94 \
            -m 00000000000000000 \
            -os latest download
        
        mv com.apple.recovery.boot/BaseSystem.dmg "$SHARE_DIR/"
        mv com.apple.recovery.boot/BaseSystem.chunklist "$SHARE_DIR/"
        rm -rf com.apple.recovery.boot

	# convert .dmg to .img
        if ! command -v dmg2img >/dev/null 2>&1; then
           sudo apt-get update
  	   sudo apt-get install -y dmg2img
	fi

	test -f "$RECOVERY_DMG" || { echo "Missing: $RECOVERY_DMG" >&2; exit 1; }

	dmg2img -i "$RECOVERY_DMG" "$RECOVERY_IMG"

	# Quick sanity check
	ls -lh "$RECOVERY_DMG" "$RECOVERY_IMG"
	qemu-img info "$RECOVERY_IMG" || true

        cd "$VMDIR"
        log "✓ Tahoe recovery downloaded & converted"
    else
        log "✓ Tahoe recovery already downloaded"
        if 7z l "$RECOVERY_DMG" 2>/dev/null | grep -q "Install macOS Sequoia\|Install macOS Tahoe"; then
            log "  Verified: macOS Tahoe/Sequoia recovery"
        else
            warn "  BaseSystem.dmg may be an older version"
            warn "  Run: os.sh install-clean && os.sh install"
        fi
    fi
    
    # Create ESP disk for Clover
    step "Checking ESP disk image"
    
    # Function to validate existing ESP
    validate_esp() {
        local esp_file="$1"
        
        log "Validating existing ESP..."
        
        sudo modprobe nbd max_part=8
        sudo qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true
        sleep 1
        
        if ! sudo qemu-nbd --connect=/dev/nbd0 --format=qcow2 --persistent --fork "$esp_file" 2>/dev/null; then
            warn "Failed to connect ESP for validation"
            return 1
        fi

	if ! wait_for_nbd "/dev/nbd0"; then
  	   error "NBD did not become ready (pid/size missing)"
  	   sudo qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true
  	   exit 1
	fi

	sudo udevadm settle || true
        
        local temp_mount="$TMP_DIR/esp-validate"
        sudo mkdir -p "$temp_mount"
        
        if ! sudo mount -t vfat /dev/nbd0p1 "$temp_mount" 2>/dev/null; then
            warn "Failed to mount ESP"
            sudo qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true
            return 1
        fi
       
        # Check for critical Clover files
        if [[ ! -f "$temp_mount/EFI/BOOT/BOOTX64.efi" ]] || \
           [[ ! -f "$temp_mount/EFI/CLOVER/CLOVERX64.efi" ]]; then
            warn "Clover files missing in ESP"
            sudo umount "$temp_mount" 2>/dev/null || true
            sudo qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true
            return 1
        fi
        
        sudo umount "$temp_mount"
        sudo qemu-nbd --disconnect /dev/nbd0
        
        log "✓ ESP validation passed"
        return 0
    }
    
    # Check existing ESP
    if [[ -f "$VAR_DIR/ESP.qcow2" ]]; then
        if validate_esp "$VAR_DIR/ESP.qcow2"; then
            log "✓ ESP disk already exists and is valid"
        else
            warn "Existing ESP is invalid, recreating..."
            rm -f "$VAR_DIR/ESP.qcow2"
        fi
    fi
    
    # Create ESP if needed
    if [[ ! -f "$VAR_DIR/ESP.qcow2" ]]; then
        log "Creating 256MB ESP disk..."

	# Unload NBD module entirely (clears all state)
	sudo rmmod nbd 2>/dev/null || true

	# Reload fresh
	sudo modprobe nbd max_part=8

        qemu-img create -f qcow2 "$VAR_DIR/ESP.qcow2" 256M
        
        # Trap to cleanup on failure
        cleanup_failed_esp() {
            warn "ESP creation failed, cleaning up..."
            sudo umount "$TMP_DIR/esp-mount" 2>/dev/null || true
            sudo qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true
            rm -f "$VAR_DIR/ESP.qcow2"
            exit 1
        }
        trap cleanup_failed_esp ERR
        
        log "Formatting ESP and installing Clover..."
        sudo modprobe nbd max_part=8
        
        sudo qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true
        sleep 1
        
        log "Connecting NBD device..."
        sudo qemu-nbd --connect=/dev/nbd0 --format=qcow2 --persistent --fork "$VAR_DIR/ESP.qcow2"

	if ! wait_for_nbd "/dev/nbd0"; then
  	   error "NBD did not become ready (pid/size missing)"
  	   sudo qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true
  	   exit 1
	fi
        
        log "Waiting for device to be ready..."
        sleep 3
        
        if [[ ! -b /dev/nbd0 ]]; then
            error "NBD device /dev/nbd0 not available"
            cleanup_failed_esp
        fi
        
        log "Creating partition table..."
        sudo wipefs -a /dev/nbd0 2>/dev/null || true
        
        sudo parted -s /dev/nbd0 \
            mklabel gpt \
            mkpart primary fat32 1MiB 100% \
            set 1 esp on
        
        sudo partprobe /dev/nbd0
	sudo udevadm settle || true

        sleep 2
        
        log "Waiting for partition..."
        for i in {1..10}; do
            if [[ -b /dev/nbd0p1 ]]; then
                log "✓ Partition /dev/nbd0p1 ready"
                break
            fi
            sleep 1
        done
        
        if [[ ! -b /dev/nbd0p1 ]]; then
            error "Partition /dev/nbd0p1 did not appear"
            cleanup_failed_esp
        fi
        
        log "Formatting as FAT32..."
        sudo mkfs.vfat -F 32 -n "ESP" /dev/nbd0p1
        sleep 1
        
        sudo mkdir -p "$TMP_DIR/esp-mount"
        log "Mounting ESP..."
        sudo mount -t vfat /dev/nbd0p1 "$TMP_DIR/esp-mount"
        
        log "Installing Clover bootloader..."
        sudo mkdir -p "$TMP_DIR/esp-mount/EFI"/{BOOT,CLOVER}
        sudo cp "$LIB_DIR/clover/CloverV2/EFI/BOOT/BOOTX64.efi" "$TMP_DIR/esp-mount/EFI/BOOT/"
        sudo cp "$LIB_DIR/clover/CloverV2/EFI/CLOVER/CLOVERX64.efi" "$TMP_DIR/esp-mount/EFI/CLOVER/"

	# Copy all UEFI firmware drivers from Clover package into ESP
	sudo mkdir -p "$TMP_DIR/esp-mount/EFI/CLOVER/drivers/UEFI"

        # Prefer UEFI drivers tree if present (most common in modern Clover zips)
	if [[ -d "$LIB_DIR/clover/CloverV2/EFI/CLOVER/drivers/off/UEFI" ]]; then
  	   sudo find "$LIB_DIR/clover/CloverV2/EFI/CLOVER/drivers/off/UEFI" \
    	     -type f -name '*.efi' -print \
    	     -exec sudo cp -v {} "$TMP_DIR/esp-mount/EFI/CLOVER/drivers/UEFI/" \;
	else
	   # Fallback: older packages may ship top-level drivers under drivers/off/
  	   shopt -s nullglob
  	   drivers=( "$LIB_DIR/clover/CloverV2/EFI/CLOVER/drivers/off/"*.efi )
  	   shopt -u nullglob

  	   if ((${#drivers[@]})); then
    	      sudo cp -v "${drivers[@]}" "$TMP_DIR/esp-mount/EFI/CLOVER/drivers/UEFI/"
  	   else
    	      warn "No Clover drivers found under CloverV2/EFI/CLOVER/drivers/off/"
  	   fi
        fi
        
        if [[ -d "$LIB_DIR/clover/CloverV2/EFI/CLOVER/themes" ]]; then
            sudo cp -r "$LIB_DIR/clover/CloverV2/EFI/CLOVER/themes" "$TMP_DIR/esp-mount/EFI/CLOVER/"
        fi
        
        if [[ -f "$VMDIR/config.plist" ]]; then
            sudo cp "$VMDIR/config.plist" "$TMP_DIR/esp-mount/EFI/CLOVER/config.plist"
            log "✓ config.plist installed"
        else
            warn "config.plist not found, Clover will use defaults"
        fi
        
        log "Syncing and unmounting..."
        sudo sync
        sleep 1
        sudo umount "$TMP_DIR/esp-mount"
        sleep 1
        sudo qemu-nbd --disconnect /dev/nbd0
        sleep 1
        
        # Remove trap since we succeeded
        trap - ERR
        
        log "✓ ESP disk created and configured"
    fi

    # Create macOS system disk
    step "Checking macOS system disk"
    if [[ ! -f "$VAR_DIR/MyDisk.qcow2" ]]; then
        log "Creating 100GB system disk..."
        qemu-img create -f qcow2 "$VAR_DIR/MyDisk.qcow2" 100G
        log "✓ System disk created"
    else
        log "✓ System disk already exists"
        DISK_SIZE=$(qemu-img info "$VAR_DIR/MyDisk.qcow2" | grep "virtual size" | awk '{print $3 $4}')
        log "  Size: $DISK_SIZE"
    fi
    
    step "Installation complete!"
    log ""
    log "✓ All components ready:"
    log "  - Clover: $LIB_DIR/clover/"
    log "  - OVMF: $FIRMWARE_DIR/"
    log "  - macOS Tahoe: $SHARE_DIR/BaseSystem.dmg"
    log "  - ESP: $VAR_DIR/ESP.qcow2"
    log "  - System disk: $VAR_DIR/MyDisk.qcow2"
    log ""
    log "Next steps:"
    log "  os.sh start    # Start the VM"
    log "  os.sh mount    # Mount EFI to edit config"
}

# ============================================================================
# INSTALL-CLEAN COMMAND
# ============================================================================
cmd_install_clean() {
    step "macOS VM Environment Cleanup"
    
    if [[ ! -f "$VMDIR/os.sh" ]]; then
        error "Must run from $VMDIR"
        exit 1
    fi
    
    DIRS_TO_CLEAN=(
        "$VMDIR/bin"
        "$VMDIR/lib"
        "$VMDIR/var"
        "$VMDIR/tmp"
        "$VMDIR/logs"
        "$VMDIR/firmware"
        "$VMDIR/share"
    )
    
    log "The following directories will be DELETED:"
    echo ""
    for dir in "${DIRS_TO_CLEAN[@]}"; do
        if [[ -d "$dir" ]]; then
            SIZE=$(du -sh "$dir" 2>/dev/null | cut -f1)
            echo -e "  ${RED}✗${NC} $(basename $dir)/ ($SIZE)"
        else
            echo -e "  ${YELLOW}○${NC} $(basename $dir)/ (not found)"
        fi
    done
    
    echo ""
    log "The following files will be KEPT:"
    echo ""
    for file in "${KEEP_FILES[@]}"; do
        if [[ -f "$VMDIR/$file" ]]; then
            echo -e "  ${GREEN}✓${NC} $file"
        fi
    done
    
    echo ""
    warn "This will delete ALL VM data (disks, logs, downloads)"
    warn "You will need to run 'os.sh install' again"
    echo ""
    
    read -p "Are you sure? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "Cleanup cancelled"
        return 0
    fi
    
    step "Cleaning up NBD devices"
    for nbd in /dev/nbd*; do
        if [[ -b "$nbd" ]] && [[ "$nbd" =~ ^/dev/nbd[0-9]+$ ]]; then
            sudo qemu-nbd --disconnect "$nbd" 2>/dev/null || true
        fi
    done
    
    step "Stopping any running VMs"
    if pkill -f "qemu-system-x86_64.*$VMDIR" 2>/dev/null; then
        log "Stopped running VM"
        sleep 2
    fi
    
    step "Removing directories"
    for dir in "${DIRS_TO_CLEAN[@]}"; do
        if [[ -d "$dir" ]]; then
            log "Removing $(basename $dir)/..."
            rm -rf "$dir"
        fi
    done
    
    step "Cleanup complete!"
    log "Run: os.sh install"
}

# ============================================================================
# START COMMAND
# ============================================================================
cmd_start() {
    ESP_DISK="$VAR_DIR/ESP.qcow2"
    SYSTEM_DISK="$VAR_DIR/MyDisk.qcow2"
    OVMF_CODE="$FIRMWARE_DIR/OVMF_CODE.fd"
    OVMF_VARS="$VAR_DIR/OVMF_VARS.fd"
    
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    QEMU_LOG="$LOG_DIR/qemu-${TIMESTAMP}.log"
    SERIAL_LOG="$LOG_DIR/serial-${TIMESTAMP}.log"
    MONITOR_LOG="$LOG_DIR/monitor-${TIMESTAMP}.log"
    
    mkdir -p "$LOG_DIR"
    
    # Verify files
    log "Verifying required files..."
    for file in "$OVMF_CODE" "$OVMF_VARS" "$ESP_DISK" "$SYSTEM_DISK" "$RECOVERY_IMG"; do
        if [[ ! -f "$file" ]]; then
            error "Missing: $file"
            error "Run: os.sh install"
            exit 1
        fi
    done
    
    # Cleanup
    log "Cleaning up stale connections..."
    pkill -f "qemu-system-x86_64.*$VMDIR" 2>/dev/null || true
    
    for nbd in /dev/nbd*; do
        if [[ -b "$nbd" ]] && [[ "$nbd" =~ ^/dev/nbd[0-9]+$ ]]; then
            sudo qemu-nbd --disconnect "$nbd" 2>/dev/null || true
        fi
    done
    
    sleep 1
    
    log "Starting macOS Tahoe VM..."
    log "Logs: $LOG_DIR"
    log "  - QEMU: $(basename $QEMU_LOG)"
    log "  - Serial: $(basename $SERIAL_LOG)"
    log "  - Monitor: stdio"
    log ""
    
    # BaseSystem.dmg is a UDIF disk image (not an ISO). When presented as ATAPI CD-ROM (ide-cd),
    # QEMU uses CD-ROM semantics (notably 2048-byte blocks), and macOS Recovery may fail to boot/mount it.
    # Attaching it as an ATA disk (ide-hd) exposes normal disk semantics (512-byte sectors), which works reliably.
    # snapshot=on keeps it effectively read-only via a temporary overlay.
 
    exec qemu-system-x86_64 \
      -name "macOS-Tahoe-VM" \
      -enable-kvm \
      -machine q35,accel=kvm,i8042=off,vmport=off \
      -no-reboot \
      -cpu Penryn,vendor=GenuineIntel,kvm=on,+sse3,+sse4.2,+aes,+xsave,+xsaveopt,+avx,+avx2,+xsavec,+xgetbv1,+invtsc \
      -smp 8,cores=4,threads=2 \
      -m 16G \
      -device isa-applesmc,osk="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc" \
      -smbios type=2 \
      -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
      -drive if=pflash,format=raw,file="$OVMF_VARS" \
      -vga none \
      -device VGA,vgamem_mb=128 \
      -display gtk,gl=off,zoom-to-fit=off \
      -device ich9-ahci,id=sata \
      -drive id=ESP,if=none,format=qcow2,file="$ESP_DISK",cache=none,aio=native \
      -device ide-hd,bus=sata.0,drive=ESP,bootindex=1 \
      -drive id=Recovery,if=none,format=raw,file="$RECOVERY_IMG",snapshot=on,cache=none,aio=native \
      -device ide-hd,bus=sata.1,drive=Recovery \
      -drive id=MacHDD,if=none,format=qcow2,file="$SYSTEM_DISK",cache=none,aio=native,discard=unmap,detect-zeroes=unmap \
      -device ide-hd,bus=sata.2,drive=MacHDD,bootindex=2 \
      -device ich9-usb-ehci1,id=usb \
      -device ich9-usb-uhci1,masterbus=usb.0,firstport=0,multifunction=on \
      -device ich9-usb-uhci2,masterbus=usb.0,firstport=2 \
      -device ich9-usb-uhci3,masterbus=usb.0,firstport=4 \
      -device usb-kbd,bus=usb.0 \
      -device usb-tablet,bus=usb.0 \
      -k en-us \
      -netdev user,id=net0 \
      -device vmxnet3,netdev=net0,mac=52:54:00:c9:18:27 \
      -device virtio-rng-pci \
      -rtc base=utc,clock=host \
      -global kvm-pit.lost_tick_policy=discard \
      -serial file:"$SERIAL_LOG" \
      -monitor stdio \
      -global ICH9-LPC.disable_s3=1 \
      -global ICH9-LPC.disable_s4=1 \
      -D "$QEMU_LOG" \
      -d guest_errors,unimp 2>&1 | tee -a "$MONITOR_LOG"
}

# ============================================================================
# MOUNT COMMAND
# ============================================================================
cmd_mount() {
    ESP_IMAGE="$VAR_DIR/ESP.qcow2"
    
    if [[ ! -f "$ESP_IMAGE" ]]; then
        error "ESP not found: $ESP_IMAGE"
        error "Run: os.sh install"
        exit 1
    fi
    
    if ! lsmod | grep -q "^nbd "; then
        log "Loading NBD module..."
        sudo modprobe nbd max_part=8
    fi
    
    if [[ -b "$NBD_DEVICE" ]]; then
        if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
            warn "Already mounted, unmounting first..."
            sudo umount "$MOUNT_POINT" || true
        fi
        sudo qemu-nbd --disconnect "$NBD_DEVICE" 2>/dev/null || true
        sleep 1
    fi
    
    log "Connecting ESP to $NBD_DEVICE..."
    sudo qemu-nbd --connect=/dev/nbd0 --format=qcow2 --persistent --fork "$VAR_DIR/ESP.qcow2"

    
    log "Waiting for partition..."
    for i in $(seq 1 $MAX_WAIT); do
        if [[ -b "${NBD_DEVICE}p1" ]]; then
            break
        fi
        sleep 1
    done
    
    if [[ ! -b "${NBD_DEVICE}p1" ]]; then
        error "Partition did not appear"
        sudo qemu-nbd --disconnect "$NBD_DEVICE"
        exit 1
    fi
    
    sudo mkdir -p "$MOUNT_POINT"
    
    log "Mounting..."
    sudo mount -t vfat "${NBD_DEVICE}p1" "$MOUNT_POINT"
    
    log "✓ EFI mounted at $MOUNT_POINT"
    log ""
    log "Edit Clover config:"
    log "  sudo nano $MOUNT_POINT/EFI/CLOVER/config.plist"
    log ""
    log "When done:"
    log "  os.sh umount"
}

# ============================================================================
# UMOUNT COMMAND
# ============================================================================
cmd_umount() {
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        log "Unmounting..."
        sudo umount "$MOUNT_POINT"
        log "✓ Unmounted"
    else
        warn "Not mounted"
    fi
    
    if [[ -b "$NBD_DEVICE" ]]; then
        log "Disconnecting NBD..."
        sudo qemu-nbd --disconnect "$NBD_DEVICE"
        log "✓ Disconnected"
    else
        warn "NBD not connected"
    fi
    
    log "✓ Cleanup complete"
}

# ============================================================================
# MAIN
# ============================================================================
usage() {
    cat << 'USAGE'
Usage: os.sh <command>

Commands:
  install         Install/setup macOS VM environment
  install-clean   Clean everything and start fresh
  start           Start the macOS VM
  mount           Mount EFI partition for editing
  umount          Unmount EFI partition

Examples:
  os.sh install         # First time setup
  os.sh start           # Run the VM
  os.sh mount           # Edit Clover config
  os.sh umount          # Unmount after editing
  os.sh install-clean   # Clean and reinstall
USAGE
    exit 1
}

if [[ $# -eq 0 ]]; then
    usage
fi

case "$1" in
    install)
        cmd_install
        ;;
    install-clean)
        cmd_install_clean
        ;;
    start)
        cmd_start
        ;;
    mount)
        cmd_mount
        ;;
    umount)
        cmd_umount
        ;;
    *)
        error "Unknown command: $1"
        usage
        ;;
esac
