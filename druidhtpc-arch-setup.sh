#!/usr/bin/env bash

# ==============================================================================
# DRUIDHTPC AUTOMATED ARCH INSTALLER & PARTITIONER
# Target Environment: Guest VM / Bare-Metal UEFI System
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${PACKAGE_STAGING_DIR:-}" ]]; then
  PACKAGE_STAGING_DIR="${PACKAGE_STAGING_DIR}"
elif [[ -d /work/packages ]]; then
  PACKAGE_STAGING_DIR="/work/packages"
else
  PACKAGE_STAGING_DIR="${SCRIPT_DIR}/packages"
fi
MIRRORLIST_SOURCE="${MIRRORLIST_SOURCE:-/work/ukmirrorlist}"
SLOT_UPDATE_SOURCE="${SCRIPT_DIR}/druidhtpc-slot-update"
NAS_SOURCE="192.168.50.96:/volume1/druidshare"
RESTORE_MEDIA_BACKUP="${RESTORE_MEDIA_BACKUP:-0}"
MEDIA_BACKUP="/mnt/nas/backups/druidmedia-2026-11-15-111810.tar.gz"

if [[ "${RESTORE_MEDIA_BACKUP}" != 0 && "${RESTORE_MEDIA_BACKUP}" != 1 ]]; then
  echo "RESTORE_MEDIA_BACKUP must be 0 or 1." >&2
  exit 1
fi

restore_media_backup() (
  set -euo pipefail
  local nas_mount archive expected_digest checksum_path
  nas_mount="$(mktemp -d /tmp/druidhtpc-nas.XXXXXX)"
  cleanup_restore() {
    if mountpoint -q "${nas_mount}"; then
      umount "${nas_mount}" || return 1
    fi
    rmdir "${nas_mount}"
  }
  trap cleanup_restore EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  mount -t nfs -o ro,nosuid,nodev,noexec,vers=3,hard,timeo=900,retrans=5 \
    "${NAS_SOURCE}" "${nas_mount}"
  archive="${nas_mount}/${MEDIA_BACKUP#/mnt/nas/}"
  read -r expected_digest checksum_path < "${archive}.sha256"
  if [[ ! "${expected_digest}" =~ ^[[:xdigit:]]{64}$ || "${checksum_path}" != "${MEDIA_BACKUP}" ]]; then
    echo "Invalid checksum file for ${MEDIA_BACKUP}." >&2
    exit 1
  fi
  printf '%s  %s\n' "${expected_digest}" "${archive}" | sha256sum --check --strict -

  echo "Restoring application config/data from ${MEDIA_BACKUP}."
  tar --extract --gzip --file="${archive}" --directory=/mnt/home/chris \
    --numeric-owner --same-owner --same-permissions --wildcards --anchored \
    -- .kodi .dvbstreamer .config/ccatv .config/dvbstreamer .config/comskip \
    '.local/share/ccatv/ccatv.sqlite3*' \
    .local/state/ccatv/schedules_direct_token_cache.json
)

# Resolve partition names for both sdX and nvme/mmc devices.
partition_path() {
  local disk="$1"
  local index="$2"
  if [[ "$disk" =~ [0-9]$ ]]; then
    printf "%sp%s" "$disk" "$index"
  else
    printf "%s%s" "$disk" "$index"
  fi
}

detect_target_disks() {
  local disk_list disk size type removable readonly transport mounted
  local -a physical_os=() physical_recording=() vm_os=() vm_recording=()

  if ! disk_list="$(lsblk -b -d -n -p -r -o PATH,SIZE,TYPE,RM,RO,TRAN)"; then
    echo "Unable to enumerate disks; refusing to install." >&2
    return 1
  fi
  while read -r disk size type removable readonly transport; do
    [[ "${type}" == disk && "${removable}" == 0 && "${readonly}" == 0 ]] || continue
    [[ "${transport}" != usb ]] || continue
    [[ "${size}" =~ ^[0-9]+$ ]] || continue
    if (( size >= 240000000000 && size <= 275000000000 )); then
      physical_os+=("${disk}")
    elif (( size >= 480000000000 && size <= 550000000000 )); then
      physical_recording+=("${disk}")
    elif (( size == 64 * 1024 * 1024 * 1024 )); then
      vm_os+=("${disk}")
    elif (( size == 40 * 1024 * 1024 * 1024 )); then
      vm_recording+=("${disk}")
    fi
  done <<< "${disk_list}"

  if (( ${#physical_os[@]} == 1 && ${#physical_recording[@]} == 1 )); then
    TARGET_DISK="${physical_os[0]}"
    RECORDING_DISK="${physical_recording[0]}"
    echo "Detected physical disk sizes."
  elif (( ${#physical_os[@]} == 0 && ${#physical_recording[@]} == 0 )) &&
       systemd-detect-virt --vm --quiet &&
       (( ${#vm_os[@]} == 1 && ${#vm_recording[@]} == 1 )); then
    TARGET_DISK="${vm_os[0]}"
    RECORDING_DISK="${vm_recording[0]}"
    echo "Detected the 64 GiB / 40 GiB VM disk sizes."
  else
    echo "Could not uniquely identify both disks; refusing to install." >&2
    echo "Expected one 240–275 GB OS disk and one 480–550 GB recording disk, or the configured VM disks." >&2
    lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,RM,RO,MOUNTPOINTS >&2
    return 1
  fi

  for disk in "${TARGET_DISK}" "${RECORDING_DISK}"; do
    if ! mounted="$(lsblk -n -r -p -o MOUNTPOINTS "${disk}")"; then
      echo "Unable to check mounts on ${disk}; refusing to install." >&2
      return 1
    fi
    if [[ -n "${mounted//[[:space:]]/}" ]]; then
      echo "${disk} or one of its descendants is mounted; refusing to install." >&2
      return 1
    fi
  done

  echo "WARNING: the following disks and all their contents will be erased:"
  echo "OS disk: ${TARGET_DISK}"
  echo "Recording disk: ${RECORDING_DISK}"
  lsblk -d -o NAME,SIZE,MODEL,SERIAL,TRAN "${TARGET_DISK}" "${RECORDING_DISK}"
  echo "Verify the model and serial numbers independently before continuing."
  local confirmation
  read -r -p "Type ERASE to confirm: " confirmation || {
    echo "Confirmation not received; refusing to install." >&2
    return 1
  }
  if [[ "${confirmation}" != ERASE ]]; then
    echo "Confirmation not given; refusing to install." >&2
    return 1
  fi
}

detect_target_disks

echo "=== [1/15] Creating GPT Partition Layout (56 GB Total Required) ==="
# Wipe existing partition signatures cleanly
blkdiscard -f "${TARGET_DISK}" || true

# Execute a precise script-driven sfdisk partition sequence
# Layout: 1GB ESP (U), 15GB Slot A (L), 15GB Slot B (L), Remainder Linux Home (L)
sfdisk "${TARGET_DISK}" <<EOF
label: gpt
size=1GiB  type=U  name="ESP"
size=15GiB type=L  name="Slot_A"
size=15GiB type=L  name="Slot_B"
type=L            name="Home"
EOF

# Notify the kernel of partition alterations
partprobe "${TARGET_DISK}"
sleep 2

# Recording drive uses one dedicated data partition.
sfdisk "${RECORDING_DISK}" <<EOF
label: gpt
type=L name="Recording_Data"
EOF
partprobe "${RECORDING_DISK}"
sleep 2

# Target mapping names based on sfdisk creation output
PART_ESP="$(partition_path "${TARGET_DISK}" 1)"
PART_SLOT_A="$(partition_path "${TARGET_DISK}" 2)"
PART_SLOT_B="$(partition_path "${TARGET_DISK}" 3)"
PART_HOME="$(partition_path "${TARGET_DISK}" 4)"
PART_RECORDING="$(partition_path "${RECORDING_DISK}" 1)"

echo "=== [2/15] Initializing Filesystems ==="
mkfs.vfat -F32 -n "ESP" "${PART_ESP}"
mkfs.ext4 -F -L "Slot_A" "${PART_SLOT_A}"
mkfs.ext4 -F -L "Slot_B" "${PART_SLOT_B}"
mkfs.ext4 -F -L "Shared_Home" "${PART_HOME}"
mkfs.ext4 -F -L "Recording_Data" "${PART_RECORDING}"

echo "=== [3/15] Mounting Target Environment (Defaulting to Active Slot A) ==="
mount "${PART_SLOT_A}" /mnt
mkdir -p /mnt/boot /mnt/home /mnt/data

mount "${PART_ESP}" /mnt/boot
mount "${PART_HOME}" /mnt/home
mount "${PART_RECORDING}" /mnt/data

# Reuse host-backed pacman cache when /work is mounted via virtiofs.
if mountpoint -q /work; then
  mkdir -p /work/pacman-cache /mnt/var/cache/pacman/pkg
  mount --bind /work/pacman-cache /mnt/var/cache/pacman/pkg
  echo "Using host pacman cache at /work/pacman-cache"
else
  echo "/work is not mounted; using VM-local pacman cache"
fi

echo "=== [4/15] Bootstrapping Base System & Multimedia Backends ==="
# Configure the live installer and target system to use the supplied mirrorlist.
if [[ ! -f "${MIRRORLIST_SOURCE}" ]]; then
  echo "Expected mirrorlist at ${MIRRORLIST_SOURCE}" >&2
  exit 1
fi
install -Dm644 "${MIRRORLIST_SOURCE}" /etc/pacman.d/mirrorlist
install -Dm644 "${MIRRORLIST_SOURCE}" /mnt/etc/pacman.d/mirrorlist

# Essential system packages, IceWM environment, and DVB utilities
pacstrap -K /mnt \
  base \
  git \
  linux \
  linux-firmware \
  networkmanager \
  nfs-utils \
  openssh \
  python \
  intel-ucode \
  intel-media-driver \
  libva-utils \
  mesa \
  uv \
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
  sudo \
  vim

# Generate explicit fstab file using persistent unique hardware UUID identifiers
genfstab -U /mnt > /mnt/etc/fstab

mkdir -p /mnt/mnt/nas
cat << EOF >> /mnt/etc/fstab

# Mount the NAS on demand without requiring it to be available at boot.
${NAS_SOURCE} /mnt/nas nfs rw,nosuid,nodev,_netdev,nofail,x-systemd.automount,vers=3,hard,timeo=900,retrans=5 0 0
EOF

echo "=== [5/15] Provisioning User 'chris' ==="
if group_entry="$(arch-chroot /mnt getent group chris)"; then
  IFS=: read -r group_name group_password group_gid group_members <<< "${group_entry}"
  if [[ "${group_gid}" != 1000 ]]; then
    echo "Expected group chris to have GID 1000; found ${group_gid}. Refusing to change existing ownership." >&2
    exit 1
  fi
else
  arch-chroot /mnt groupadd -g 1000 chris
fi

if chris_uid="$(arch-chroot /mnt id -u chris 2>/dev/null)"; then
  chris_gid="$(arch-chroot /mnt id -g chris)"
  if [[ "${chris_uid}" != 1000 || "${chris_gid}" != 1000 ]]; then
    echo "Expected chris to have UID/GID 1000:1000; found ${chris_uid}:${chris_gid}. Refusing to change existing ownership." >&2
    exit 1
  fi
else
  arch-chroot /mnt useradd -m -u 1000 -g chris -G wheel,audio,video,storage,optical -s /bin/bash chris
fi

install -d -m 700 /mnt/home/chris/.ssh
touch /mnt/home/chris/.ssh/authorized_keys
chmod 600 /mnt/home/chris/.ssh/authorized_keys
ssh_public_key='ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCm17hBhuF0ynsU1LapUg1K5EtgU69hLBj/bva0YhK7f49HuQH9ZkypChDdYiI+YSE/UK6KCELURsqsYAcA2vgeRYhaJ0cu+9gwt+QjGJ75TvrFdOc8HWLaY70v8qW7fC/QJ0en8OY6lMcuYaPhMdzHWCG5Jdwpea4NFHESrjmJYarTrjZzC2oAmS8l+dJswlSD0oxVsfwowXvrqrACULcQhLcW+wtA28XMM/WUyTJDJHEMyH3Fjt7P3blcUd/kNLFt1/mgrXOCU5Un5N8i8/Vsfr9ppRN1fjq4PikPPv9eK77WHEdE0dX8vdxctZjhQOVXklvuslufMrLj5gZO7BNf chris@stone'
if ! grep -qxF -- "${ssh_public_key}" /mnt/home/chris/.ssh/authorized_keys; then
  printf '%s\n' "${ssh_public_key}" >> /mnt/home/chris/.ssh/authorized_keys
fi
arch-chroot /mnt chown -R chris:chris /home/chris/.ssh

# Allow clean power controls from IceWM without prompting for a password.
cat << 'EOF' > /mnt/etc/sudoers.d/chris-power
chris ALL=(root) NOPASSWD: /usr/bin/systemctl poweroff, /usr/bin/systemctl reboot, /usr/bin/poweroff, /usr/bin/reboot, /usr/bin/shutdown, /usr/bin/loginctl poweroff, /usr/bin/loginctl reboot, /usr/local/sbin/druidhtpc-slot-update
EOF
chmod 0440 /mnt/etc/sudoers.d/chris-power

# Do not set a default password in automation.
echo "Post-install action required: set the chris password with: arch-chroot /mnt passwd chris"

if [[ "${RESTORE_MEDIA_BACKUP}" == 1 ]]; then
  pacman -Sy --needed --noconfirm nfs-utils
  restore_media_backup
fi

echo "=== [6/15] Installing Staged Package Set ==="

cat << 'EOF' >> /mnt/etc/pacman.conf

[ccapkgs]
SigLevel = Optional TrustAll
Server = https://raw.github.com/ccdale/$repo/main/any
EOF
arch-chroot /mnt pacman -Syu --noconfirm ccatv

# Copy all staged package artifacts into the target and install them there.
mkdir -p /mnt/root/packages
shopt -s nullglob
package_matches=("${PACKAGE_STAGING_DIR}"/*.pkg.tar.*)
shopt -u nullglob

install_packages=()
for pkg in "${package_matches[@]}"; do
  base="$(basename "${pkg}")"
  if [[ "${base}" == *-debug-* || "${base}" == *.sig ]]; then
    continue
  fi
  install_packages+=("${pkg}")
done

if [[ ${#install_packages[@]} -eq 0 ]]; then
  echo "Expected at least one package artifact in ${PACKAGE_STAGING_DIR}" >&2
  echo "Stage package files (for example dvbstreamer-t2/comskip/ccatv) before running this installer." >&2
  exit 1
fi

target_packages=()
for pkg in "${install_packages[@]}"; do
  package_filename="$(basename "${pkg}")"
  cp "${pkg}" "/mnt/root/packages/${package_filename}"
  target_packages+=("/root/packages/${package_filename}")
done

arch-chroot /mnt pacman -U --noconfirm "${target_packages[@]}"
echo "Installed ${#target_packages[@]} staged package(s) from ${PACKAGE_STAGING_DIR}."

arch-chroot /mnt systemctl --global disable ccatv.service ccatv-api.service ccatv-web.service
echo "ccatv services are installed but disabled; review restored paths/tuner settings before enabling them."

# Bring up standard LAN networking and SSH for remote access.
arch-chroot /mnt systemctl enable NetworkManager NetworkManager-wait-online.service sshd.service


echo "=== [7/15] Deploying systemd-boot Configurations ==="
# Initialize systemd-boot inside the ESP partition
arch-chroot /mnt bootctl --path=/boot install

# Extract persistent PARTUUID strings directly from blkid evaluations
PARTUUID_A=$(blkid -s PARTUUID -o value "${PART_SLOT_A}")
PARTUUID_B=$(blkid -s PARTUUID -o value "${PART_SLOT_B}")
ROOT_UUID_A=$(blkid -s UUID -o value "${PART_SLOT_A}")
ROOT_UUID_B=$(blkid -s UUID -o value "${PART_SLOT_B}")

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
initrd  /initramfs-linux.img
options root=PARTUUID=${PARTUUID_A} rw quiet
EOF

cat <<EOF > /mnt/boot/loader/entries/slot-b.conf
title   Arch Linux (Slot B - Fallback/Testing)
linux   /vmlinuz-linux-b
initrd  /intel-ucode.img
initrd  /initramfs-linux-b.img
options root=PARTUUID=${PARTUUID_B} rw quiet
EOF

# Populate initial empty kernel configurations into the ESP path
cp /mnt/boot/vmlinuz-linux /mnt/boot/vmlinuz-linux-b || true
cp /mnt/boot/initramfs-linux.img /mnt/boot/initramfs-linux-b.img || true

echo "=== [8/15] Automated Base Installation Complete ==="
echo "You can now run 'arch-chroot /mnt' for additional system customization."

echo "=== [9/15] Provisioning IceWM Configurations ==="

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
key "Ctrl+K" /home/chris/scripts/toggle-kodi.sh
key "Ctrl+T" xterm
key "Ctrl+F" firefox
EOF

# Ensure IceWM power menu actions work in this minimal setup.
cat << 'EOF' > "${CHRIS_HOME}/.icewm/prefoverride"
ShutdownCommand="sudo /usr/bin/systemctl poweroff"
RebootCommand="sudo /usr/bin/systemctl reboot"
EOF

# 5. Fix permissions so the user owns their own configuration footprint
arch-chroot /mnt chown -R chris:chris /home/chris
echo "User profiles, memory leak handlers, and IceWM hooks successfully staged."



echo "=== [10/15] Configuring Automated Console Login for chris ==="
# Create the override directory for the primary virtual console (tty1)
mkdir -p /mnt/etc/systemd/system/getty@tty1.service.d

# Write the override configuration to drop straight into the 'chris' user shell
cat << 'EOF' > /mnt/etc/systemd/system/getty@tty1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin chris --noclear %I $TERM
EOF

echo "=== [11/15] Configuring Automated X11 Shell Initialization ==="
# Add a conditional startx trigger once.
if ! grep -q "kick off X11 immediately" /mnt/home/chris/.bash_profile 2>/dev/null; then
  cat << 'EOF' >> /mnt/home/chris/.bash_profile

# If running on the primary local virtual terminal, kick off X11 immediately
if [[ -z $DISPLAY && $(tty) == /dev/tty1 ]]; then
    exec startx
fi
EOF
fi
arch-chroot /mnt chown chris:chris /home/chris/.bash_profile

echo "=== [12/15] Configuring .xinitrc Startup Chain ==="
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
arch-chroot /mnt chown chris:chris /home/chris/.xinitrc


echo "=== [13/15] Automating vidtv Kernel Module Initialization ==="
# Force the system to load the virtual DVB bridge driver on boot
mkdir -p /mnt/etc/modules-load.d
cat << 'EOF' > /mnt/etc/modules-load.d/vidtv.conf
# Load synthetic DVB adapter for HTPC pipeline testing
dvb_vidtv_bridge
EOF

echo "=== [14/15] Deploying vidtv Tuning Automation Service ==="

# 1. Create the systemd service file
cat << 'EOF' > /mnt/etc/systemd/system/vidtv-provision.service
[Unit]
Description=Provision Synthetic vidtv Tuning Files
After=systemd-modules-load.service
Requires=systemd-modules-load.service

[Service]
Type=oneshot
User=chris
Group=chris
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

echo "=== [15/15] Cloning Slot A to Slot B ==="
if ! command -v rsync > /dev/null 2>&1; then
  echo "The live installer requires rsync to clone Slot A to Slot B." >&2
  exit 1
fi
if [[ ! -f "${SLOT_UPDATE_SOURCE}" ]]; then
  echo "Expected slot update helper at ${SLOT_UPDATE_SOURCE}" >&2
  exit 1
fi

install -Dm755 "${SLOT_UPDATE_SOURCE}" /mnt/usr/local/sbin/druidhtpc-slot-update

SLOT_B_MOUNT="$(mktemp -d /tmp/druidhtpc-slot-b.XXXXXX)"
mount "${PART_SLOT_B}" "${SLOT_B_MOUNT}"
rsync -aHAXx --delete --numeric-ids /mnt/ "${SLOT_B_MOUNT}/"
sed -i "s#UUID=${ROOT_UUID_A}#UUID=${ROOT_UUID_B}#" "${SLOT_B_MOUNT}/etc/fstab"
sync
umount "${SLOT_B_MOUNT}"
rmdir "${SLOT_B_MOUNT}"
echo "Slot B is now a root-filesystem clone of Slot A."
