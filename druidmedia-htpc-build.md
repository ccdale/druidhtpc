# build instructions

This file now describes the automated test workflow.

The split is:

1. `build-druidhtpc.sh` runs on the host and creates the VM definition plus its two virtual disks.
2. `druidhtpc-arch-setup.sh` runs inside the Arch live environment in that VM and performs the actual install/configuration.

## 1. Host prerequisites

Before starting, make sure the following are true on the host:

* The Arch ISO is available at `/mnt/nas/iso/archlinux-2026.11.01-x86_64.iso`, or set `ARCH_ISO` to another readable ISO.
* libvirt/QEMU tooling is installed and working for `qemu:///session`.
* required packages are installed: `libvirt` (provides `virsh`), `virt-install`, `virt-viewer`, and `qemu-img` (from QEMU tools)
* `$HOME/src/druidhtpc/work/packages/` exists on the host and contains exactly one `dvbstreamer-t2` package
* you have built one `dvbstreamer-t2-*.pkg.tar.zst` package in a clean Arch environment
* host `$HOME/src/druidhtpc/work/` is writable by your user

On Arch/Manjaro this is typically:

```bash
sudo pacman -S --needed libvirt virt-install virt-viewer qemu-desktop
```

For the package build workflow, see `druidhtpc-dvbstreamer-build.md`.

## 2. What the VM builder creates

`build-druidhtpc.sh` creates:

* one OS disk at 64 GB
* one recording disk at 40 GB
* a UEFI Arch VM named `druidhtpc-test-env`
* a SPICE display opened with `virt-viewer`
* a virtiofs share from host `$HOME/src/druidhtpc/work` to guest `/work`

The installer detects the VM's disks by size, independent of their names:

* 64 GiB for the OS SSD
* 40 GiB for the recording HDD

## 3. Build and boot the VM

Run on the host:

```bash
cd /home/chris/src/druidhtpc
./build-druidhtpc.sh
```

This will:

1. remove any previous test VM with the same name
2. recreate both virtual disks
3. boot the Arch ISO under libvirt
4. open the VM console with `virt-viewer`

**This deletes the existing test VM and both of its virtual disks.** Back up
anything needed from them before running it. To use a different ISO, run
`ARCH_ISO=/path/to/archlinux.iso ./build-druidhtpc.sh`.

## 4. Inside the Arch live environment

Once the VM boots into the Arch ISO:

```bash
loadkeys uk
timedatectl set-timezone Europe/London
```

Confirm the expected disks are present:

```bash
lsblk
```

You should see the two virtual disks (device names may vary):

* a 64 GiB OS disk
* a 40 GiB recording disk

## 5. Mount the shared /work directory inside the VM

This workflow uses a single shared path to avoid copy/paste transfer steps and to isolate ownership changes in a dedicated `work/` area away from tracked source files.

Inside the Arch live environment:

```bash
mkdir -p /work
mount -t virtiofs work /work
ls -l /work
```

You should then have:

* `/work/druidhtpc/druidhtpc-arch-setup.sh`
* `/work/packages/` containing exactly one `dvbstreamer-t2-*.pkg.tar.*`
* `/work/pacman-cache/` used as the persistent package cache across rebuilds

## 6. Run the installer inside the VM

From the shared project directory inside the guest:

```bash
cd /work/druidhtpc
chmod +x druidhtpc-arch-setup.sh
./druidhtpc-arch-setup.sh
```

To also restore the NAS backup's application config/data, use `RESTORE_MEDIA_BACKUP=1 ./druidhtpc-arch-setup.sh` instead. See [backup restore details](README.md#restoring-the-media-server-backup). Publish `ccatv` to `ccapkgs` before installing; the installer registers this repository and installs the package even without a restore.

The installer displays the selected disks and requires `ERASE` confirmation before partitioning. Verify both disk identities before confirming; it stops on ambiguous sizes or mounted disks.

The installer will:

1. partition the selected OS disk into ESP, Slot A, Slot B, and shared home
2. partition the selected recording disk into one recording-data partition
3. format and mount the filesystems
4. `pacstrap` the Arch base system and UI packages
5. create the `chris` user with UID 1000 and primary group `chris` with GID 1000, configure the `chris@stone` SSH key, and enable `sshd` at boot
6. install the staged `dvbstreamer-t2` package with `pacman -U`
7. configure systemd-boot entries for Slot A and Slot B
8. configure IceWM autologin, X startup, Kodi toggle script, and vidtv helpers
9. configure on-demand NFS mounting of `192.168.50.96:/volume1/druidshare` at `/mnt/nas` in both slots
10. install `ccatv` from `ccapkgs`, leaving its user services disabled pending configuration review

When `/work` is mounted, the installer bind-mounts `/work/pacman-cache` to `/mnt/var/cache/pacman/pkg` before `pacstrap`, so downloaded package archives are reused on future rebuilds.

By default the installer will use guest `/work/packages` when present (host `$HOME/src/druidhtpc/work/packages`). If that directory is missing, or contains zero or multiple matching packages, the installer will stop with an error.

## 7. Reboot and test

Once the installer completes:

```bash
reboot
```

At boot, hold the space bar if you want to force the systemd-boot menu.

## 8. Verify the A/B layout

After booting into Slot A:

```bash
findmnt /
findmnt /home
findmnt /data
```

Expected:

* `/` on the Slot A partition
* `/home` on the shared home partition
* `/data` on the recording disk

Then reboot and select Slot B from the boot menu.

Run the same checks again:

```bash
findmnt /
findmnt /home
findmnt /data
```

Expected:

* `/` now on the Slot B partition
* `/home` unchanged
* `/data` unchanged

That confirms the A/B root swap is working while shared user data and recording storage stay stable.

## 9. Notes for this test workflow

* this document is for the scripted VM path, not the older fully-manual Arch install path
* `build-druidhtpc.sh` does not install Arch by itself; it only creates and boots the VM
* `druidhtpc-arch-setup.sh` is the installer that must be run from inside the VM
* the installer detects the VM's 64 GiB OS and 40 GiB recording disks by size and requires confirmation before erasing them
* vidtv setup is provisioned automatically, but it still depends on the guest kernel actually shipping `dvb_vidtv_bridge`

## 10. Fast rerun loop

When iterating:

1. rebuild or replace the staged `dvbstreamer-t2` package if needed
2. ensure the package is in `$HOME/src/druidhtpc/work/packages`
3. rerun `./build-druidhtpc.sh` on the host
4. re-enter the live environment
5. rerun `./druidhtpc-arch-setup.sh` inside the fresh VM

That gives you a clean repeatable test loop for the eventual physical HTPC install.
