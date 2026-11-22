#!/usr/bin/env bash

# ==============================================================================
# DRUIDHTPC VM AUTOMATED PROVISIONING SCRIPT
# Mimics GNOME Boxes backend architecture via libvirt / QEMU / SPICE
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- CONFIGURATION ---
VM_NAME="druidhtpc-test-env"
RAM_MB=4096
VCPUS=2
DISK_DIR="${HOME}/.local/share/gnome-boxes/images" # Matches GNOME Boxes default storage path
ARCH_ISO="${ARCH_ISO:-/mnt/nas/iso/archlinux-2026.11.01-x86_64.iso}"
HOST_WORK_SHARE_DIR="${SCRIPT_DIR}/work"
HOST_VM_WORK_DIR="${HOST_WORK_SHARE_DIR}/druidhtpc"

# Virtual Storage Disk Definitions
OS_SSD_PATH="${DISK_DIR}/${VM_NAME}-os-ssd.qcow2"
OS_SSD_SIZE=64 # Leaves enough room for 1GB ESP + 15GB Slot A + 15GB Slot B + shared home
DATA_HDD_PATH="${DISK_DIR}/${VM_NAME}-data-hdd.qcow2"
DATA_HDD_SIZE=40 # 40GB virtual drive to test the raw TS stream buffer allocations

if [[ ! -r "${ARCH_ISO}" || ! -f "${ARCH_ISO}" ]]; then
    echo "Arch ISO not found or unreadable: ${ARCH_ISO}" >&2
    exit 1
fi

echo "=== [1/4] Preparing Host Storage & Environment ==="
mkdir -p "${DISK_DIR}"
mkdir -p "${HOST_VM_WORK_DIR}" "${HOST_WORK_SHARE_DIR}/packages"

# Stage installer files in a dedicated shared workspace to avoid touching source-tree ownership.
install -m 0755 "${SCRIPT_DIR}/druidhtpc-arch-setup.sh" "${HOST_VM_WORK_DIR}/druidhtpc-arch-setup.sh"
install -m 0755 "${SCRIPT_DIR}/druidhtpc-slot-update" "${HOST_VM_WORK_DIR}/druidhtpc-slot-update"

# --- AUTOMATED CLEANUP / ITERATION LOOP ---
# If the VM exists from a previous test run, wipe it out completely to ensure a clean state
if virsh --connect qemu:///session list --all --name | grep -q "^${VM_NAME}$"; then
    echo "Found existing environment '${VM_NAME}'. Tearing down for iterative build..."
    
    # Force stop if running
    if virsh --connect qemu:///session domstate "${VM_NAME}" | grep -q "running"; then
        echo "Stopping running instance..."
        virsh --connect qemu:///session destroy "${VM_NAME}" >/dev/null
    fi
    
    # Undefine from libvirt registry (UEFI guests need NVRAM removal too)
    echo "Removing VM definition..."
    virsh --connect qemu:///session undefine "${VM_NAME}" --nvram >/dev/null
fi

# Explicitly purge old virtual disk files if they remain on the file system
rm -f "${OS_SSD_PATH}" "${DATA_HDD_PATH}"
echo "Storage and state purged successfully."

echo "=== [2/4] Allocating Multi-Disk Layout ==="
# Emulate the physical dual-drive target architecture
qemu-img create -f qcow2 "${OS_SSD_PATH}" "${OS_SSD_SIZE}G" >/dev/null
qemu-img create -f qcow2 "${DATA_HDD_PATH}" "${DATA_HDD_SIZE}G" >/dev/null
echo "Allocated Virtual OS SSD: ${OS_SSD_PATH} (${OS_SSD_SIZE}GB)"
echo "Allocated Virtual Recording HDD: ${DATA_HDD_PATH} (${DATA_HDD_SIZE}GB)"

echo "=== [3/4] Provisioning VM via Libvirt & QEMU ==="
# Use libvirt default network when available; otherwise fall back to user-mode NAT.
if virsh --connect qemu:///session net-info default >/dev/null 2>&1; then
  NETWORK_ARG=(--network network=default)
  echo "Using libvirt network: default"
else
  NETWORK_ARG=(--network user)
  echo "libvirt network 'default' not found in qemu:///session; falling back to user-mode NAT"
fi

# Execute virt-install against the user-space session daemon
virt-install \
  --connect qemu:///session \
  --name="${VM_NAME}" \
  --ram="${RAM_MB}" \
  --memorybacking access.mode=shared \
  --vcpus="${VCPUS}" \
  --cpu host-passthrough \
  --boot uefi \
  --os-variant=archlinux \
  --disk path="${OS_SSD_PATH}",format=qcow2,bus=sata,cache=none,boot.order=2 \
  --disk path="${DATA_HDD_PATH}",format=qcow2,bus=sata,cache=none \
  --disk path="${ARCH_ISO}",device=cdrom,bus=sata,boot.order=1 \
  --filesystem source="${HOST_WORK_SHARE_DIR}",target=work,driver.type=virtiofs \
  "${NETWORK_ARG[@]}" \
  --graphics spice,listen=127.0.0.1 \
  --channel spicevmc \
  --noautoconsole
# Execute virt-install against the user-space session daemon
# virt-install \
#   --connect qemu:///session \
#   --name="${VM_NAME}" \
#   --ram="${RAM_MB}" \
#   --memorybacking access.mode=shared \
#   --vcpus="${VCPUS}" \
#   --cpu host-passthrough \
#   --boot uefi \
#   --os-variant=archlinux \
#   --disk path="${OS_SSD_PATH}",format=qcow2,bus=sata,cache=none \
#   --disk path="${DATA_HDD_PATH}",format=qcow2,bus=sata,cache=none \
#   --filesystem source="${HOST_WORK_SHARE_DIR}",target=work,driver.type=virtiofs \
#   --cdrom "${ARCH_ISO}" \
#   "${NETWORK_ARG[@]}" \
#   --graphics spice,listen=127.0.0.1 \
#   --channel spicevmc \
#   --noautoconsole

echo "VM '${VM_NAME}' successfully defined and started background initialization."

echo "=== [4/4] Launching SPICE Graphical Interface & Auto-Eject Hook ==="
echo "Connecting Virt-Viewer to simulate GNOME Boxes display rendering..."
echo "Press Ctrl+Alt+R inside the viewer to release your mouse cursor if trapped."

# Launch Virt-Viewer over SPICE in the background
virt-viewer --connect qemu:///session --wait "${VM_NAME}" &

# --- AUTOMATED ISO EJECT HOOK ---
echo "Waiting for installer completion (VM shutdown/reboot)..."

# Poll virsh state until the VM is no longer running
while virsh --connect qemu:///session domstate "${VM_NAME}" 2>/dev/null | grep -q "running"; do
    sleep 3
done

echo "Installer finished! Ejecting Arch ISO from virtual CD-ROM drive..."

# Detect the target device name for the CD-ROM drive (e.g., sda or sdc)
CDROM_DEV=$(virsh --connect qemu:///session domblklist "${VM_NAME}" | grep -E '\.iso$' | awk '{print $1}')

if [ -n "${CDROM_DEV}" ]; then
    virsh --connect qemu:///session change-media "${VM_NAME}" "${CDROM_DEV}" --eject --config >/dev/null
    echo "Successfully ejected ISO from target '${CDROM_DEV}'."
else
    echo "No attached ISO found to eject."
fi

echo "=== Build script execution completed ==="

# echo "=== [4/4] Launching SPICE Graphical Interface ==="
# echo "Connecting Virt-Viewer to simulate GNOME Boxes display rendering..."
# echo "Press Ctrl+Alt+R inside the viewer to release your mouse cursor if trapped."
# 
# # Launch Virt-Viewer over SPICE to handle the interactive graphical configuration
# # It waits dynamically for the VM subsystem to come completely online
# virt-viewer --connect qemu:///session --wait "${VM_NAME}" &
# 
# echo "=== Build script execution completed ==="
# 