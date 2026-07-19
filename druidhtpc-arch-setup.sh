#!/usr/bin/env bash

# ==============================================================================
# DRUIDHTPC AUTOMATED ARCH INSTALLER & PARTITIONER
# Target Environment: Guest VM / Bare-Metal UEFI System
# ==============================================================================

set -euo pipefail

# --- TARGET DISK CONFIGURATION ---
TARGET_DISK="/dev/sda"
RECORDING_DISK="/dev/sdb"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_STAGING_DIR="${PACKAGE_STAGING_DIR:-${SCRIPT_DIR}/packages}"

# Resolve partition names for both sdX and nvme/mmc devices.
partition_path() {
  local disk="$1"
  local index="$2"
  if [[ "$disk" =~ (nvme|mmcblk) ]]; then
    printf "%sp%s" "$disk" "$index"
  else
    printf "%s%s" "$disk" "$index"
  fi
}

echo "=== [1/14] Creating GPT Partition Layout (56 GB Total Required) ==="
# Wipe existing partition signatures cleanly
blkdiscard -f "${TARGET_DISK}" || true

# Execute a precise script-driven sfdisk partition sequence
# Layout: 1GB ESP (Type 1), 15GB Slot A (Type 23), 15GB Slot B (Type 23), Remainder Linux Home (Type 42)
sfdisk "${TARGET_DISK}" <<EOF
label: gpt
size=1GiB,      type=1, name="ESP"
size=15GiB,     type=23, name="Slot_A"
size=15GiB,     type=23, name="Slot_B"
type=42,        name="Home"
EOF

# Notify the kernel of partition alterations
partprobe "${TARGET_DISK}"
sleep 2

# Recording drive uses one dedicated data partition.
sfdisk "${RECORDING_DISK}" <<EOF
label: gpt
type=20, name="Recording_Data"
EOF
partprobe "${RECORDING_DISK}"
sleep 2

# Target mapping names based on sfdisk creation output
PART_ESP="$(partition_path "${TARGET_DISK}" 1)"
PART_SLOT_A="$(partition_path "${TARGET_DISK}" 2)"
PART_SLOT_B="$(partition_path "${TARGET_DISK}" 3)"
PART_HOME="$(partition_path "${TARGET_DISK}" 4)"
PART_RECORDING="$(partition_path "${RECORDING_DISK}" 1)"

echo "=== [2/14] Initializing Filesystems ==="
mkfs.vfat -F32 -n "ESP" "${PART_ESP}"
mkfs.ext4 -F -L "Slot_A" "${PART_SLOT_A}"
mkfs.ext4 -F -L "Slot_B" "${PART_SLOT_B}"
mkfs.ext4 -F -L "Shared_Home" "${PART_HOME}"
mkfs.ext4 -F -L "Recording_Data" "${PART_RECORDING}"

echo "=== [3/14] Mounting Target Environment (Defaulting to Active Slot A) ==="
mount "${PART_SLOT_A}" /mnt
mkdir -p /mnt/boot /mnt/home /mnt/data

mount "${PART_ESP}" /mnt/boot
mount "${PART_HOME}" /mnt/home
mount "${PART_RECORDING}" /mnt/data

echo "=== [4/14] Bootstrapping Base System & Multimedia Backends ==="
# Essential system packages, IceWM environment, and DVB utilities
pacstrap -K /mnt \
  base \
  linux \
  linux-firmware \
  intel-ucode \
  amd-ucode \
  xorg-server \
  xorg-xinit \
  xterm \
  firefox \
  icewm \
  kodi-x11 \
  v4l-utils \
  xdotool \
  lirc \
  rsync \
  vim

# Generate explicit fstab file using persistent unique hardware UUID identifiers
genfstab -U /mnt > /mnt/etc/fstab

echo "=== [5/14] Provisioning User 'chris' ==="
if ! arch-chroot /mnt id -u chris > /dev/null 2>&1; then
  arch-chroot /mnt useradd -m -g users -G wheel,audio,video,storage,optical -s /bin/bash chris
fi
# Assign a temporary password (chris) - change this upon final bare-metal rollout
echo "chris:chris" | arch-chroot /mnt chpasswd

echo "=== [6/14] Installing Staged dvbstreamer-t2 Package ==="

# Copy one prebuilt package into the target and install it there.
mkdir -p /mnt/root/packages
shopt -s nullglob
package_matches=("${PACKAGE_STAGING_DIR}"/dvbstreamer-t2-*.pkg.tar.*)
shopt -u nullglob

if [[ ${#package_matches[@]} -ne 1 ]]; then
  echo "Expected exactly one dvbstreamer-t2 package in ${PACKAGE_STAGING_DIR}" >&2
  echo "Build the package separately and place the resulting .pkg.tar.zst file there before running this installer." >&2
  exit 1
fi

package_filename="$(basename "${package_matches[0]}")"
cp "${package_matches[0]}" "/mnt/root/packages/${package_filename}"
arch-chroot /mnt pacman -U --noconfirm "/root/packages/${package_filename}"
echo "dvbstreamer-t2 installed from staged package ${package_filename}."


echo "=== [7/14] Deploying systemd-boot Configurations ==="
# Initialize systemd-boot inside the ESP partition
arch-chroot /mnt bootctl --path=/boot install

# Extract persistent PARTUUID strings directly from blkid evaluations
PARTUUID_A=$(blkid -s PARTUUID -o value "${PART_SLOT_A}")
PARTUUID_B=$(blkid -s PARTUUID -o value "${PART_SLOT_B}")

# Write out the systemd-boot entry definitions
cat <<EOF > /mnt/boot/loader/loader.conf
default slot-a.conf
timeout 4
console-mode max
EOF

cat <<EOF > /mnt/boot/loader/entries/slot-a.conf
title   Arch Linux (Slot A - Active)
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /amd-ucode.img
initrd  /initramfs-linux.img
options root=PARTUUID=${PARTUUID_A} rw quiet
EOF

cat <<EOF > /mnt/boot/loader/entries/slot-b.conf
title   Arch Linux (Slot B - Fallback/Testing)
linux   /vmlinuz-linux-b
initrd  /intel-ucode.img
initrd  /amd-ucode.img
initrd  /initramfs-linux-b.img
options root=PARTUUID=${PARTUUID_B} rw quiet
EOF

# Populate initial empty kernel configurations into the ESP path
cp /mnt/boot/vmlinuz-linux /mnt/boot/vmlinuz-linux-b || true
cp /mnt/boot/initramfs-linux.img /mnt/boot/initramfs-linux-b.img || true

echo "=== [8/14] Automated Base Installation Complete ==="
echo "You can now run 'arch-chroot /mnt' for additional system customization."

echo "=== [9/14] Provisioning IceWM Configurations ==="

# 2. Establish directory structures inside the new home mount
CHRIS_HOME="/mnt/home/chris"
mkdir -p "${CHRIS_HOME}/scripts"
mkdir -p "${CHRIS_HOME}/.icewm"

# 3. Inject the Kodi atomic toggle script to catch and clean up memory leaks
cat << 'EOF' > "${CHRIS_HOME}/scripts/toggle-kodi.sh"
#!/usr/bin/env bash
set -euo pipefail

if pgrep -x "kodi-x11" > /dev/null; then
    echo "Kodi process detected. Terminating session to flush memory leaks..."
    pkill -x "kodi-x11"
else
    echo "Initializing fresh Kodi media center runtime..."
    kodi &
fi
EOF
chmod +x "${CHRIS_HOME}/scripts/toggle-kodi.sh"

# 4. Write the global IceWM keyboard configuration file with your specific layouts
# Uses clear, explicit keysym strings mapped directly to your requested keys
cat << EOF > "${CHRIS_HOME}/.icewm/keys"
# DruidHTPC System Keybindings
key "K" /home/chris/scripts/toggle-kodi.sh
key "T" xterm
key "F" firefox
EOF

# 5. Fix permissions so the user owns their own configuration footprint
arch-chroot /mnt chown -R chris:users /home/chris
echo "User profiles, memory leak handlers, and IceWM hooks successfully staged."



echo "=== [10/14] Configuring Automated Console Login for chris ==="
# Create the override directory for the primary virtual console (tty1)
mkdir -p /mnt/etc/systemd/system/getty@tty1.service.d

# Write the override configuration to drop straight into the 'chris' user shell
cat << 'EOF' > /mnt/etc/systemd/system/getty@tty1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin chris --noclear %I $TERM
EOF

echo "=== [11/14] Configuring Automated X11 Shell Initialization ==="
# Add a conditional startx trigger once.
if ! grep -q "kick off X11 immediately" /mnt/home/chris/.bash_profile 2>/dev/null; then
  cat << 'EOF' >> /mnt/home/chris/.bash_profile

# If running on the primary local virtual terminal, kick off X11 immediately
if [[ -z $DISPLAY && $(tty) == /dev/tty1 ]]; then
    exec startx
fi
EOF
fi
chown chris:users /mnt/home/chris/.bash_profile

echo "=== [12/14] Configuring .xinitrc Startup Chain ==="
# Define the X11 launch parameters
cat << 'EOF' > /mnt/home/chris/.xinitrc
#!/bin/sh

# Disable screen blanking and power management for HTPC stability
xset s off
xset -dpms

# Execute your memory-leak toggle script in the background to initialize Kodi
/home/chris/scripts/toggle-kodi.sh &

# Execute IceWM as the controlling session manager
# Using 'exec' ensures killing IceWM logs the user out safely
exec icewm-session
EOF

chmod +x /mnt/home/chris/.xinitrc
chown chris:users /mnt/home/chris/.xinitrc


echo "=== [13/14] Automating vidtv Kernel Module Initialization ==="
# Force the system to load the virtual DVB bridge driver on boot
mkdir -p /mnt/etc/modules-load.d
cat << 'EOF' > /mnt/etc/modules-load.d/vidtv.conf
# Load synthetic DVB adapter for HTPC pipeline testing
dvb_vidtv_bridge
EOF

echo "=== [14/14] Deploying vidtv Tuning Automation Service ==="

# 1. Create the systemd service file
cat << 'EOF' > /mnt/etc/systemd/system/vidtv-provision.service
[Unit]
Description=Provision Synthetic vidtv Tuning Files
After=systemd-modules-load.service
Requires=systemd-modules-load.service

[Service]
Type=oneshot
User=chris
Group=users
RemainAfterExit=yes
WorkingDirectory=/home/chris
ExecStartPre=/usr/bin/timeout 30 /usr/bin/bash -c 'until [ -d /dev/dvb/adapter0 ]; do sleep 0.5; done'
ExecStart=/usr/bin/bash -c '\
  echo -e "[Channel]\nFREQUENCY = 474000000\nMODULATION = QAM/AUTO\nSYMBOL_RATE = 6940000\nINNER_FEC = AUTO\nDELIVERY_SYSTEM = DVBC/ANNEX_A" > /home/chris/vidtv.conf && \
  /usr/bin/dvbv5-scan /home/chris/vidtv.conf -o /home/chris/dvb_channels.conf'

[Install]
WantedBy=multi-user.target
EOF

# 2. Enable the service inside the change-root abstraction layer
arch-chroot /mnt systemctl enable vidtv-provision.service
