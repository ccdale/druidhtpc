# Physical media server: live build checklist

Use this when returning to the physical PC build. For background and USB
partitioning details, see [the physical build guide](druidmedia-physical-build.md).

## 1. Starting point

USB layout:

- About 31 GB total (28.9 GiB).
- `Ventoy`: exFAT, with `archlinux-2026.11.01-x86_64.iso` copied alongside the older ISO.
- `VTOYEFI`: Ventoy's 32 MiB boot partition; leave it alone.
- `DRUIDWORK`: 12 GiB ext4 partition, now created and writable.
- The new ISO's SHA-256 matched the supplied checksum, its signature verified
  against the host pacman keyring, and the USB copy's SHA-256 matched.

Do not repartition the USB again. The remaining preparation is refreshing the
package cache and copying the build files.

## 2. Refresh the cache using the VM

On the preparation host, after saving anything needed from the old test VM
and its disks (the builder deletes both):

```bash
cd ~/src/druidhtpc
./build-druidhtpc.sh
```

Follow [the VM build instructions](druidmedia-htpc-build.md), including mounting
the virtiofs share at `/work`. To test the backup restore as well, run inside
the live VM:

```bash
RESTORE_MEDIA_BACKUP=1 /work/druidhtpc/druidhtpc-arch-setup.sh
```

Verify the selected 64 GiB OS and 40 GiB recording disks before typing `ERASE`.
Wait for the build to finish before copying the cache; stop the VM afterward
so it cannot modify the shared files during copying.

The NAS previously rejected the NAT VM's NFS mount because it required a
privileged source port. Allowing non-privileged ports on the NAS export fixed
this. The NAS is `nasmedia`, address `192.168.50.96`, export
`/volume1/druidshare`. Keep the old recording services stopped when testing
restored schedules on another machine.

## 3. Copy the build files to DRUIDWORK

On the preparation host, open `DRUIDWORK` in Files to mount it. Check the
actual mountpoint:

```bash
lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE,LABEL,MOUNTPOINTS
findmnt /run/media/chris/DRUIDWORK
```

If that is not the ext4 partition on the intended USB, stop and correct the
path below. These commands do not format anything:

```bash
cd ~/src/druidhtpc
USB_WORK=/run/media/chris/DRUIDWORK
mountpoint -q "$USB_WORK"
```

Continue only if `mountpoint` succeeds. Inspect `work/packages/`: the installer
installs all non-debug package archives there, so avoid obsolete versions.
Make sure `ccatv` and its dependencies are available from `ccapkgs`; the cache
does not make this an offline installation.

```bash
sudo mkdir -p "$USB_WORK"/{druidhtpc/tests,packages,pacman-cache}
sudo install -m 755 backup-druidmedia.sh druidhtpc-arch-setup.sh druidhtpc-slot-update "$USB_WORK/druidhtpc/"
sudo install -m 644 tests/backup-druidmedia.py tests/disk-detection.sh "$USB_WORK/druidhtpc/tests/"
sudo install -m 644 README.md druidmedia-physical-build.md "$USB_WORK/"
sudo install -m 644 work/ukmirrorlist "$USB_WORK/ukmirrorlist"
sudo install -m 644 live-steps.md "$USB_WORK/live-steps.md"
sudo rsync -rt work/packages/ "$USB_WORK/packages/"
sudo rsync -rt --exclude='download-*' work/pacman-cache/ "$USB_WORK/pacman-cache/"
df -h "$USB_WORK"
sync
```

Check for copy errors. The completed cache was approximately 4.31 GiB before
the new build; allow space for additional downloads. Skip temporary
`download-*` directories. These copy commands do not delete older files already
on the USB; review `packages/` there too if reusing it.

Expected contents at the root of `DRUIDWORK`:

```text
druidhtpc/
  backup-druidmedia.sh
  druidhtpc-arch-setup.sh
  druidhtpc-slot-update
  tests/
packages/
pacman-cache/
ukmirrorlist
README.md
druidmedia-physical-build.md
live-steps.md
```

Use Files to safely eject the USB after copying.

## 4. Before touching the physical PC

- [ ] Back up anything needed from both internal disks: both will be erased.
- [ ] OS disk is approximately 250 GB; recording disk is approximately 500 GB.
- [ ] Record/check their model and serial numbers; size alone is not identity.
- [ ] Disconnect unrelated storage where possible.
- [ ] Connect Ethernet, keyboard, display and USB.
- [ ] Boot the USB in **UEFI mode**, then select the Arch ISO in Ventoy.
- [ ] Disable Secure Boot for this procedure; signed boot is not configured.

Do not run `build-druidhtpc.sh` on the server. It is the host-side VM builder.

## 5. In the physical PC's Arch live environment

Run as root:

```bash
loadkeys uk
timedatectl set-timezone Europe/London
test -d /sys/firmware/efi/efivars && echo "UEFI boot confirmed"
lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,FSTYPE,LABEL,MOUNTPOINTS
ip -brief address
ping -c 3 archlinux.org
ping -c 3 github.com
```

Stop if not booted in UEFI mode. Establish working networking before continuing.
Device names may differ from the host or VM; the installer detects disks by
size, not by `/dev/sda` versus `/dev/sdb`.

Mount the USB work partition directly at `/work`. Check that exactly one
connected filesystem has the `DRUIDWORK` label:

```bash
mkdir -p /work
mount /dev/disk/by-label/DRUIDWORK /work
findmnt /work
ls -l /work/druidhtpc /work/packages /work/ukmirrorlist
df -h /work
```

The installer needs `rsync` in the live environment. If `command -v rsync`
fails, install it:

```bash
pacman -Sy --needed rsync
```

Test NAS access before starting the destructive installation, even if not
restoring a backup. Run as root in the live environment:

```bash
pacman -Sy --needed nfs-utils
mkdir -p /mnt/nas-test
mount -t nfs -o ro,vers=3 192.168.50.96:/volume1/druidshare /mnt/nas-test
findmnt /mnt/nas-test
ls -l /mnt/nas-test/backups/druidmedia-*.tar.gz*
umount /mnt/nas-test
```

Stop if the mount fails or `findmnt` does not show the NAS export; do not
proceed with the listing or unmount commands in that case. Resolve the
network or NAS access issue before continuing. If restoring, review the
[backup restore details](README.md#restoring-the-media-server-backup): the
installer defaults to the 15 November backup, or accepts a newer `MEDIA_BACKUP`
path. It validates the corresponding checksum before restoring.

## 6. Install: destructive step

Choose **one** command, depending on whether the backup should be restored:

```bash
cd /work/druidhtpc
RESTORE_MEDIA_BACKUP=1 ./druidhtpc-arch-setup.sh
```

For a newer backup, set `MEDIA_BACKUP` to the path printed by the backup script:

```bash
RESTORE_MEDIA_BACKUP=1 MEDIA_BACKUP=/mnt/nas/backups/druidmedia-REPLACE.tar.gz \
  ./druidhtpc-arch-setup.sh
```

Or, for a clean installation without restored application data:

```bash
cd /work/druidhtpc
./druidhtpc-arch-setup.sh
```

Before typing `ERASE`, verify the displayed model and serial for **both** disks:

- OS: one disk in the 240–275 GB range.
- Recordings: one disk in the 480–550 GB range.
- Neither is the USB stick.

The script rejects ambiguous matches and mounted target disks. Do not bypass
these checks. If installation fails, record the error rather than blindly
rerunning: another run starts by erasing the disks again.

## 7. After successful installation, before reboot

The installer has already cloned Slot A to Slot B. Set a password in each
root slot separately. First identify partition 3 (`Slot_B`) on the selected
OS disk with `lsblk -f`. Substitute its actual path below:

```bash
arch-chroot /mnt passwd chris
mkdir -p /mnt-slot-b
mount /dev/REPLACE_WITH_VERIFIED_SLOT_B_PARTITION /mnt-slot-b
arch-chroot /mnt-slot-b passwd chris
```

The installer currently enables synthetic **vidtv** testing on physical
hardware too. For a real-tuner deployment, disable its service and remove its
module-load configuration in **both slots** before first boot:

```bash
arch-chroot /mnt systemctl disable vidtv-provision.service
arch-chroot /mnt-slot-b systemctl disable vidtv-provision.service
rm /mnt/etc/modules-load.d/vidtv.conf
rm /mnt-slot-b/etc/modules-load.d/vidtv.conf
umount /mnt-slot-b
sync
reboot
```

Do not unplug the USB while the live OS is using it. Remove it as the machine
restarts, and boot the installed disk's UEFI entry.

## 8. First-boot acceptance checks

From a terminal on the installed system:

```bash
findmnt /
findmnt /home
findmnt /data
systemctl is-enabled sshd
systemctl status sshd
ip -brief address
ls /mnt/nas
findmnt /mnt/nas
ls -l /dev/dvb/
```

- [ ] Slot A boots; `/home` and `/data` are on the intended shared disks.
- [ ] SSH works from the client using the private key matching `chris@stone`.
- [ ] NAS automount works. Access may wait if the NAS is unavailable.
- [ ] Identify the real tuner adapters; do not assume adapter numbering.
- [ ] Reboot, choose Slot B, and repeat mount/login checks.
- [ ] Review restored recording paths, tuner settings and API/web settings.
- [ ] Stop the old server's recording services before enabling the replacement.

Verify NAS read/write access from a terminal logged in as `chris`, not root.
The first command triggers the on-demand mount; confirm `findmnt` reports the
NAS NFS export before running the write test:

```bash
ls /mnt/nas/backups
findmnt -T /mnt/nas
(
  set -e
  tmp=$(mktemp /mnt/nas/backups/.druidhtpc-check.XXXXXXXX)
  trap 'rm -f -- "$tmp"' EXIT
  echo test > "$tmp"
  grep -qx test "$tmp"
  echo "NAS read/write OK"
)
```

The test creates and removes only its own temporary file. Repeat it in Slot B.
If the NAS is unavailable, the hard mount can wait while retrying I/O.

Only when ready, run from Chris's logged-in session:

```bash
systemctl --user enable --now ccatv.service ccatv-api.service ccatv-web.service
systemctl --user status ccatv.service ccatv-api.service ccatv-web.service
```

Keep the USB and cache for recovery. For subsequent system updates, use
`sudo druidhtpc-slot-update`, not the destructive installer.
