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
ARCH_ISO="${HOME}/Downloads/archlinux-x86_64.iso" # Update this path to your Arch ISO
HOST_WORK_SHARE_DIR="${SCRIPT_DIR}/work"
HOST_VM_WORK_DIR="${HOST_WORK_SHARE_DIR}/druidhtpc"

# Virtual Storage Disk Definitions
OS_SSD_PATH="${DISK_DIR}/${VM_NAME}-os-ssd.qcow2"
OS_SSD_SIZE=64 # Leaves enough room for 1GB ESP + 15GB Slot A + 15GB Slot B + shared home
DATA_HDD_PATH="${DISK_DIR}/${VM_NAME}-data-hdd.qcow2"
DATA_HDD_SIZE=40 # 40GB virtual drive to test the raw TS stream buffer allocations

echo "=== [1/4] Preparing Host Storage & Environment ==="
mkdir -p "${DISK_DIR}"
mkdir -p "${HOST_VM_WORK_DIR}" "${HOST_WORK_SHARE_DIR}/packages"

# Stage installer files in a dedicated shared workspace to avoid touching source-tree ownership.
install -m 0755 "${SCRIPT_DIR}/druidhtpc-arch-setup.sh" "${HOST_VM_WORK_DIR}/druidhtpc-arch-setup.sh"

# --- AUTOMATED CLEANUP / ITERATION LOOP ---
# If the VM exists from a previous test run, wipe it out completely to ensure a clean state
if virsh --connect qemu:///session list --all --name | grep -q "^${VM_NAME}$"; then
    echo "Found existing environment '${VM_NAME}'. Tearing down for iterative build..."
    
    # Force stop if running
    if virsh --connect qemu:///session domstate "${VM_NAME}" | grep -q "running"; then
        echo "Stopping running instance..."
        virsh --connect qemu:///session destroy "${VM_NAME}" >/dev/null
    fi
    
    # Undefine from libvirt registry
    echo "Removing VM definition..."
    virsh --connect qemu:///session undefine "${VM_NAME}" >/dev/null
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
  --disk path="${OS_SSD_PATH}",format=qcow2,bus=sata,cache=none \
  --disk path="${DATA_HDD_PATH}",format=qcow2,bus=sata,cache=none \
  --filesystem source="${HOST_WORK_SHARE_DIR}",target=work,driver.type=virtiofs \
  --cdrom "${ARCH_ISO}" \
  "${NETWORK_ARG[@]}" \
  --graphics spice,listen=127.0.0.1 \
  --channel spicevmc \
  --noautoconsole

echo "VM '${VM_NAME}' successfully defined and started background initialization."

echo "=== [4/4] Launching SPICE Graphical Interface ==="
echo "Connecting Virt-Viewer to simulate GNOME Boxes display rendering..."
echo "Press Ctrl+Alt+R inside the viewer to release your mouse cursor if trapped."

# Launch Virt-Viewer over SPICE to handle the interactive graphical configuration
# It waits dynamically for the VM subsystem to come completely online
virt-viewer --connect qemu:///session --wait "${VM_NAME}" &

echo "=== Build script execution completed ==="
