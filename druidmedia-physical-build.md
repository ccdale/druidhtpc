# Building the physical media server

This procedure uses the same Arch installer as the VM, but replaces its
virtiofs share with a writable partition on the boot USB. First complete a
successful VM build and verify that the staged packages and the `ccatv`
repository are ready. The host-side `build-druidhtpc.sh` creates a VM; do not
run it on the physical server.

## Important: disk contents will be destroyed

The installer **partitions and formats the selected OS and recording disks**.
Back up anything needed from both drives and disconnect other storage where
possible.

Linux disk names are not guaranteed. The installer looks for one 240–275 GB
OS disk and one 480–550 GB recording disk, regardless of device name. These
ranges use decimal bytes and include typical 250 GB and 500 GB disks. It
excludes USB, removable and read-only devices, rejects ambiguous matches and
refuses to proceed if a selected disk or its descendants are mounted.

Size alone cannot establish identity. The installer displays the selected
disks' model and serial and requires an `ERASE` confirmation. Independently
check the model, serial, size and transport against the intended drives
before confirming; if anything is wrong or uncertain, stop. Do not rely on
the boot order or on example device names.

The firmware must boot the installer in UEFI mode. The script installs
systemd-boot and Intel microcode/graphics packages; check that those choices
match the actual hardware. Secure Boot needs its own signing/enrollment setup;
this procedure assumes it is disabled.

## USB size and layout

A **16 GB or larger** USB stick is recommended. Drive manufacturers use
decimal GB: 16 GB is about 14.9 GiB before formatting.

Measurements on the preparation host on 15 November 2026:

| Item | Size |
| --- | ---: |
| Arch ISO at `/mnt/nas/iso/archlinux-2026.11.01-x86_64.iso` | 1,317,568,512 bytes, about 1.23 GiB |
| `work/pacman-cache` | at least 4,624,197,082 bytes, about 4.31 GiB |
| `work/packages` | about 628 KiB |
| Ventoy EFI partition | 32 MB |

The cache measurement is a **lower bound**: some `download-*` directories
were not readable by the measuring user. Cache contents can also change during
a build. Check the latest size with `sudo du -sh ~/src/druidhtpc/work/pacman-cache`
after the VM has finished. The ISO and previously measured readable cache
alone total about 5.54 GiB, before filesystem overhead and future downloads.

Use Ventoy's standard two partitions, plus an ext4 work partition in reserved
space at the end:

| Partition | Purpose | Suggested size on a 16 GB stick |
| --- | --- | --- |
| 1: Ventoy | ISO files, normally exFAT | Remaining space, roughly 6–7 GiB |
| 2: VTOYEFI | Ventoy UEFI boot files | Ventoy's 32 MB |
| 3: DRUIDWORK | Installer, packages, mirrorlist and writable pacman cache | Reserve 8192 MB, approximately 8 GiB |

This leaves roughly 3 GiB or more above the measured cache on partition 3,
depending on the actual reserved size, filesystem overhead and inaccessible
files. Check free space after copying. If the cache grows beyond that margin,
use a larger stick and reserve more space. The USB is a package cache, not an
offline repository: current repository databases and missing or newer packages
still require network access.

Ventoy's [installation instructions](https://www.ventoy.net/en/doc_start.html)
and [disk layout documentation](https://www.ventoy.net/en/doc_disk_layout.html)
describe reserved space. Do not alter Ventoy partitions 1 or 2 when creating
partition 3.

## Prepare the USB on the existing host

1. Finish the running VM installation before copying its cache. Install or
   obtain Ventoy and a partition editor such as GParted. Verify the Arch ISO
   using the signature and instructions from the
   [Arch download page](https://archlinux.org/download/). Recheck the ISO size
   if using a newer image.
2. Insert the USB and identify the **whole USB device**, not a partition:

   ```bash
   lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,FSTYPE,LABEL,MOUNTPOINTS
   ```

3. Unmount its partitions using your desktop or `umount`. Ventoy installation
   erases the entire selected USB. After independently confirming the device,
   substitute its path below; `USB` must not be either server disk or your
   host's system disk. The local host has a `ventoy` command; the upstream
   download calls it `Ventoy2Disk.sh`.

   ```bash
   USB=/dev/REPLACE_WITH_CONFIRMED_USB_DISK
   sudo ventoy -i -g -r 8192 "$USB"
   ```

   Confirm the prompts only after checking the device again. `-g` selects GPT;
   `-r 8192` tells Ventoy to reserve 8192 MB at the end. Use a larger value
   with a larger stick if needed.
4. In GParted, select the same USB device and create one **ext4** partition
   in the unallocated reserved space after VTOYEFI. Label it `DRUIDWORK`.
   Apply the change without moving or resizing either Ventoy partition. Check
   the result with `lsblk -f`. Use unique labels or explicit device paths if
   other connected disks have the same labels.
5. Mount Ventoy partition 1 and the new ext4 partition. Replace both
   placeholders with the verified **partition** paths shown by `lsblk`:

   ```bash
   VENTOY_PART=/dev/REPLACE_WITH_USB_PARTITION_1
   WORK_PART=/dev/REPLACE_WITH_USB_PARTITION_3
   sudo mkdir -p /mnt/ventoy-usb /mnt/druidwork-usb
   sudo mount "$VENTOY_PART" /mnt/ventoy-usb
   sudo mount "$WORK_PART" /mnt/druidwork-usb
   ```

6. Copy the ISO, the **current repository versions** of the installer and slot
   helper, the mirrorlist, staged package files and completed cache. The
   `download-*` directories contain temporary downloads and are excluded; do
   not delete them from the host. `rsync` must be installed on the preparation
   host.

   ```bash
   cd ~/src/druidhtpc
   sudo cp /mnt/nas/iso/archlinux-2026.11.01-x86_64.iso /mnt/ventoy-usb/
   sudo mkdir -p /mnt/druidwork-usb/{druidhtpc,packages,pacman-cache}
   sudo install -m 755 druidhtpc-arch-setup.sh druidhtpc-slot-update /mnt/druidwork-usb/druidhtpc/
   sudo install -m 644 work/ukmirrorlist /mnt/druidwork-usb/ukmirrorlist
   sudo rsync -rt work/packages/ /mnt/druidwork-usb/packages/
   sudo rsync -rt --exclude='download-*' work/pacman-cache/ /mnt/druidwork-usb/pacman-cache/
   df -h /mnt/ventoy-usb /mnt/druidwork-usb
   sync
   sudo umount /mnt/druidwork-usb
   sudo umount /mnt/ventoy-usb
   ```

   Check for copy errors and sufficient free space. The installer installs
   **all** non-debug package archives in `packages/`, not just DVBStreamer;
   inspect that directory and stage only packages intended for the server.
   The scripts are copied directly from the repository so the VM's staged
   copy cannot accidentally be stale.

## Boot and install on the server

1. Connect the OS disk, recording disk, network and USB. Select the USB's
   **UEFI** entry in firmware and boot the Arch ISO through Ventoy.
2. In the live environment:

   ```bash
   loadkeys uk
   timedatectl set-timezone Europe/London
   test -d /sys/firmware/efi/efivars && echo "UEFI boot confirmed"
   lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,FSTYPE,LABEL,MOUNTPOINTS
   ```

   If the UEFI test fails, stop and resolve that before continuing. Check the
   intended OS disk is approximately 250 GB, the recording disk approximately
   500 GB, and the USB is a **different** disk. The OS disk needs space
   for a 1 GiB ESP, two 15 GiB root slots and a useful home partition; the
   current VM uses a 64 GB OS disk. The recording disk is dedicated to `/data`
   and is completely reformatted.
3. Establish networking and verify connectivity to the configured Arch
   mirrors and GitHub. If restoring, also check that the NAS is reachable.
   Check that the live environment has `rsync`, which the installer needs:

   ```bash
   ip -brief address
   ping -c 3 archlinux.org
   ping -c 3 github.com
   command -v rsync
   ```

   Configure networking if necessary. If `rsync` is missing, refresh the live
   package databases and install it before running the installer:

   ```bash
   pacman -Sy --needed rsync
   ```

4. Find partition 3 of the USB in `lsblk -f`, then mount it **directly** at
   `/work`. Replace the placeholder with the verified partition path:

   ```bash
   mkdir -p /work
   mount /dev/REPLACE_WITH_USB_WORK_PARTITION /work
   findmnt /work
   ls -l /work/druidhtpc /work/packages /work/ukmirrorlist
   df -h /work
   ```

   `/work` must be a mountpoint: the installer bind-mounts
   `/work/pacman-cache` into the target pacman cache. Confirm sufficient free
   space for downloads.
5. Run the installer as root. Check its selected disk names, models and serial
   numbers against the actual OS and recording disks **one last time**.
   Type `ERASE` only if both are correct:

   ```bash
   cd /work/druidhtpc
   ./druidhtpc-arch-setup.sh
   ```

   To restore the NAS backup during installation instead, run
   `RESTORE_MEDIA_BACKUP=1 ./druidhtpc-arch-setup.sh`. Review the
   [restore notes](README.md#restoring-the-media-server-backup) first.
   Restoration needs NAS access, downloads the live environment's `nfs-utils`
   after refreshing its package databases, and imports potentially sensitive
   application data. No default password is set.
6. Once the installer has completed, set the password in **both** root slots.
   The installer clones Slot A to Slot B before it exits, so setting a password
   only in `/mnt` afterward does not update Slot B. Use `lsblk -f` to identify
   partition 3 of the selected OS disk and substitute its verified path:

   ```bash
   arch-chroot /mnt passwd chris
   mkdir -p /mnt-slot-b
   mount /dev/REPLACE_WITH_VERIFIED_SLOT_B_PARTITION /mnt-slot-b
   arch-chroot /mnt-slot-b passwd chris
   umount /mnt-slot-b
   sync
   reboot
   ```

   Remove the USB when the machine restarts and select the installed disk's
   UEFI boot entry. Do not unplug the USB while the live OS is using it.

## After the first boot

- Check `findmnt /`, `findmnt /home` and `findmnt /data`. Reboot and select
  Slot B from the systemd-boot menu, then confirm the shared home and data
  mounts and login there too.
- Confirm `systemctl status sshd` and test the `chris@stone` key from the
  client. Check the server's IP address with `ip -brief address`.
- Test the NAS with `ls /mnt/nas` and `findmnt /mnt/nas`; an unavailable NAS
  can cause access to wait because this is a hard NFS mount.
- The installer currently enables the **synthetic vidtv** module and service,
  even on physical hardware. Its service assumes `/dev/dvb/adapter0`; do not
  assume that is the real tuner. Review and disable the test setup in both
  slots if not wanted, then identify the actual tuner and configure ccatv.
- The ccatv user services are deliberately disabled. Review restored paths,
  tuner settings and schedules before enabling them, especially if the old
  server is still running.
